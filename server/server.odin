package main

import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/linux"

Tag :: int
Tags :: [TAG_NUM]bool
State :: struct {
	prev_layout, curr_layout: Layout,
	active_tag:               Tag,
	monitor:                  struct {
		layout:     Layout,
		active_tag: Tag,
		tags:       Tags,
	},
}

main :: proc() {
	os.exit(int(entrypoint()))
}

// TODO: mmsg watch all-monitors to avoid state desync and other edge cases

@(private = "file")
entrypoint :: proc() -> (program_err: Program_Error) {
	// Set up allocator
	arena: vmem.Arena
	if err := vmem.arena_init_static(&arena, BUF_SIZE * 8); err != nil {
		fmt.eprintfln("Failed on memory allocator init: %v", err)
		return .Mango_Wrapper_Error
	}
	alloc := vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)
	temp_begin := vmem.arena_temp_begin(&arena)

	if program_name, err := check_for_mango(alloc); err != nil {
		if err == .Program_Not_Found {
			fmt.eprintfln("Failure: %v not found", program_name)
		} else if err != nil {
			fmt.eprintfln("Failed invoking command -v: %v", err)
		}
		return err
	}

	// Set up server socket
	server_socket: linux.Fd
	{
		if server_socket, errno := linux.socket(
			.UNIX,
			.STREAM,
			{.NONBLOCK, .CLOEXEC},
			linux.Protocol(0),
		); errno != nil {
			errno_str := libc.strerror(i32(errno))
			fmt.eprintfln("Failed creating socket: %v", errno_str)
			return .Mango_Wrapper_Error
		}

		temp_dir, temp_dir_err := os.temp_directory(alloc)
		if temp_dir_err != nil {
			fmt.eprintfln("Failed getting temp directory: %v", temp_dir_err)
			return .Mango_Wrapper_Error
		}
		socket_path := fmt.aprintf(
			"%s/mango-wrapper-%d.sock",
			temp_dir,
			os.get_pid(),
			allocator = alloc,
		)
		os.remove(socket_path)

		addr := linux.Sock_Addr_Un {
			sun_family = .UNIX,
		}
		mem.copy(
			&addr.sun_path,
			raw_data(socket_path),
			min(len(socket_path), len(addr.sun_path) - 1),
		)
		if errno := linux.bind(server_socket, &addr); errno != nil {
			errno_str := libc.strerror(i32(errno))
			fmt.eprintfln("Failed binding socket: %v", errno_str)
			return .Mango_Wrapper_Error
		}

		if errno := linux.listen(server_socket, 64); errno != nil {
			errno_str := libc.strerror(i32(errno))
			fmt.eprintfln("Failed setting socket to listen: %v", errno_str)
			return .Mango_Wrapper_Error
		}

		if err := os.set_env(SOCKET_PATH_ENVVAR, socket_path); err != nil {
			fmt.eprintfln("Failed setting socket path environment variable: %v", err)
			return .Mango_Wrapper_Error
		}
		fmt.printfln("Listening on %s", SOCKET_PATH_ENVVAR)
	}
	defer os.unset_env(SOCKET_PATH_ENVVAR)
	defer linux.close(server_socket)
	vmem.arena_temp_end(temp_begin)

	// Set up connection to mango's socket
	watch_socket: linux.Fd
	{
		mango_socket_path, found := os.lookup_env(MANGO_SOCKET_ENVVAR, allocator = alloc)
		if !found {
			// See if mmsg sets the envvar when run

			_, _, _, process_err := os.process_exec({command = {"mmsg"}}, allocator = alloc)
			if process_err != nil {
				fmt.eprintfln("Failed invoking mmsg: %v", process_err)
				return .Mango_Wrapper_Error
			}
			mango_socket_path, found := os.lookup_env(MANGO_SOCKET_ENVVAR, allocator = alloc)
			if !found {
				fmt.eprintln("Failure: Mango IPC socket is not set")
				return .Mango_Error
			}
		}

		errno: linux.Errno
		if watch_socket, errno = linux.socket(
			.UNIX,
			.STREAM,
			{.NONBLOCK, .CLOEXEC},
			linux.Protocol(0),
		); errno != nil {
			errno_str := libc.strerror(i32(errno))
			fmt.eprintfln("Failed creating socket: %v", errno_str)
			return .Mango_Wrapper_Error
		}

		addr := linux.Sock_Addr_Un {
			sun_family = .UNIX,
		}
		mem.copy(
			&addr.sun_path,
			raw_data(mango_socket_path),
			min(len(mango_socket_path), len(addr.sun_path) - 1),
		)
		if errno = linux.connect(watch_socket, &addr); errno != nil {
			errno_str := libc.strerror(i32(errno))
			fmt.eprintfln("Failed connecting to mango IPC socket: %v", errno_str)
			return .Mango_Wrapper_Error
		}
	}
	defer linux.close(watch_socket)
	vmem.arena_temp_end(temp_begin)

	// Allocate buffers for watch connection and server sockets
	watch_buf, server_buf: []u8
	{
		alloc_err: mem.Allocator_Error
		watch_buf, alloc_err = make([]u8, BUF_SIZE, alloc)
		if alloc_err != nil {
			fmt.eprintfln("Failed allocating memory: %v", alloc_err)
			return .Mango_Wrapper_Error
		}

		// Watch mango changes
		mango_command := fmt.bprint(watch_buf, "watch all-monitors")
		if _, errno := linux.send(watch_socket, watch_buf[:len(mango_command)], {}); errno != nil {
			errno_str := libc.strerror(i32(errno))
			fmt.eprintfln("Failed sending watch all-monitors to mango IPC socket: %v", errno_str)
			return .Mango_Wrapper_Error
		}

		server_buf, alloc_err = make([]u8, BUF_SIZE, alloc)
		if alloc_err != nil {
			fmt.eprintfln("Failed allocating memory: %v", alloc_err)
			return .Mango_Wrapper_Error
		}
	}

	temp_begin = vmem.arena_temp_begin(&arena)
	state := State {
		curr_layout = .Tile,
		prev_layout = .Monocle,
	}
	for {
		vmem.arena_temp_end(temp_begin)

		// Watch mango changes if any
		watch_bytes_read, watch_recv_err := linux.recv(watch_socket, watch_buf, {})
		if watch_recv_err != nil && watch_recv_err != .EWOULDBLOCK {
			fmt.eprintfln("Failed reading mango IPC socket: %v", watch_recv_err)
		} else {
			// JSON parsing
			json_data, json_err := json.parse(watch_buf[:watch_bytes_read], allocator = alloc)
			if json_err != nil {
				fmt.eprintfln("Failed parsing JSON: %v", json_err)
				continue
			}
			defer json.destroy_value(json_data)

			root := json_data.(json.Object)
			monitors := root["monitors"].(json.Array)
			active_monitor: json.Object
			for i in 0 ..< len(monitors) {
				monitor := monitors[i].(json.Object) or_continue

				is_active := monitor["active"].(json.Boolean)
				if (is_active) {
					active_monitor = monitor
					break
				}
			}
			if len(active_monitor) == 0 {
				continue
			}

			layout_index := active_monitor["layout_index"].(json.Integer)
			state.monitor.layout = cast(Layout)layout_index

			active_tags := active_monitor["active_tags"].(json.Array)
			if len(active_tags) == 1 {
				state.monitor.active_tag = int(active_tags[0].(json.Integer))
			}

			tags := active_monitor["tags"].(json.Array)
			for i in 0 ..< len(state.monitor.tags) {
				tag := tags[i].(json.Object)
				has_clients := tag["client_count"].(json.Integer) > 0
				if has_clients {
					state.monitor.tags[i] = true
				}
			}
		}

		// Sync
		if state.curr_layout != state.monitor.layout {
			state.prev_layout = state.curr_layout
			state.curr_layout = state.monitor.layout
		}
		if state.active_tag != state.monitor.active_tag {
			state.active_tag = state.monitor.active_tag
		}

		// Read client commands if any
		bytes_read, recv_err := linux.recv(server_socket, server_buf, {})
		if recv_err != nil || bytes_read < size_of(Message) {
			if recv_err != .EWOULDBLOCK {
				fmt.eprintfln("Failed reading IPC socket: %v", recv_err)
			}

			continue
		}

		builder: strings.Builder
		strings.builder_init(&builder, alloc)
		fmt.sbprintf(&builder, "mmsg dispatch ")

		write_data := server_buf[bytes_read:]
		message_error := (transmute([]Message_Error)write_data)[0]
		message_error = .None

		read_data := server_buf[:bytes_read]
		message := (transmute([]Message)read_data)[0]
		switch message.command {
		case .None:
			fallthrough
		case:
			message_error = Message_Error.Message_Without_Command
			break
		case .View, .Tag:
			break
		case .Set_Layout:
			switch message.layout {
			case .Tile ..= .Vertical_Fair:
				fmt.sbprintf(
					&builder,
					"%v,%v",
					command_symbols[message.command],
					layout_symbols[message.layout],
				)

				state.prev_layout = state.monitor.layout
				state.curr_layout = message.layout
			case .None:
				fallthrough
			case:
				message_error = Message_Error.Set_Layout_Without_Layout
			}
		case .Switch_Layout:
			state.prev_layout = state.curr_layout
			state.curr_layout = cast(Layout)((int(state.curr_layout) + 1) % len(Layout))
			fmt.sbprintf(&builder, "%v", command_symbols[message.command])
		case .Toggle_Layout:
			state.curr_layout, state.prev_layout = state.prev_layout, state.curr_layout
			fmt.sbprintf(
				&builder,
				"%v,%v",
				command_symbols[message.command],
				layout_symbols[state.curr_layout],
			)
		case .View_To_Right:
			if wrap_forwards(&state.active_tag, .View, &builder) {
				break
			}

			fmt.sbprintf(&builder, "%v", command_symbols[message.command])
		case .Tag_To_Right:
			if wrap_forwards(&state.active_tag, .Tag, &builder) {
				break
			}

			fmt.sbprintf(&builder, "%v", command_symbols[message.command])
		case .View_To_Left:
			if wrap_backwards(&state.active_tag, .View, &builder) {
				break
			}

			fmt.sbprintf(&builder, "%v", command_symbols[message.command])
		case .Tag_To_Left:
			if wrap_backwards(&state.active_tag, .Tag, &builder) {
				break
			}

			fmt.sbprintf(&builder, "%v", command_symbols[message.command])
		case .View_To_Left_Have_Client:
			// If no client to the left and more than 2 occupied tags, wrap
			has_clients_to_the_left: bool
			last_occupied_tag := state.active_tag
			for i in 1 ..= len(state.monitor.tags) {
				tag := state.monitor.tags[i - 1]
				if tag {
					if i < state.active_tag {
						has_clients_to_the_left = true
					} else {
						last_occupied_tag = i
					}
				}
			}
			if has_clients_to_the_left {
				fmt.sbprintf(&builder, "%v", command_symbols[message.command])
			} else if last_occupied_tag != state.active_tag {
				fmt.sbprintf(&builder, "%v,%v", command_symbols[.View], last_occupied_tag)
			}
		case .View_To_Right_Have_Client:
			// If no client to the right and more than 2 occupied tags, wrap
			has_clients_to_the_right: bool
			first_occupied_tag := state.active_tag
			for i := len(state.monitor.tags); i >= 1; i -= 1 {
				tag := state.monitor.tags[i - 1]
				if tag {
					if i < state.active_tag {
						has_clients_to_the_right = true
					} else {
						first_occupied_tag = i
					}
				}
			}
			if has_clients_to_the_right {
				fmt.sbprintf(&builder, "%v", command_symbols[message.command])
			} else if first_occupied_tag != state.active_tag {
				fmt.sbprintf(&builder, "%v,%v", command_symbols[.View], first_occupied_tag)
			}
		}

		if message_error == .None {
			cmd := strings.to_string(builder)
			cmd_arr := strings.split(cmd, " ", alloc)
			process_state, _, _, process_err := os.process_exec({command = cmd_arr[:]}, alloc)
			if process_err != nil {
				fmt.eprintfln("Failed invoking mmsg: %v", process_err)
				message_error = .Server_Error
			}
			if process_state.exit_code != 0 {
				fmt.eprintfln("mmsg exit code: %v", process_state.exit_code)
				message_error = .Server_Error
			}
		}

		linux.send(server_socket, write_data, {})
	}

	return program_err
}

// 1-based index
wrap_forwards :: proc(active_tag: ^int, command: Command, builder: ^strings.Builder) -> bool {
	if active_tag^ >= 6 {
		active_tag^ = ((active_tag^ - 1) %% 6) + 1
		fmt.sbprintf(builder, "%v,%v", command_symbols[command], active_tag^)

		return true
	}

	return false
}

// 1-based index
wrap_backwards :: proc(active_tag: ^int, command: Command, builder: ^strings.Builder) -> bool {
	if active_tag^ <= 6 {
		active_tag^ = ((active_tag^ - 2) %% 6) + 1
		fmt.sbprintf(builder, "%v,%v", command_symbols[command], active_tag^)

		return true
	}

	return false
}

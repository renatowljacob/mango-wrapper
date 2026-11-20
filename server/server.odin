package main

import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

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

	if err := check_for_mango(alloc); err != nil {
		return err
	}

	// Set up server socket
	server_socket, server_socket_err := linux.socket(
		.UNIX,
		.STREAM,
		{.NONBLOCK, .CLOEXEC},
		linux.Protocol(0),
	)
	if server_socket_err != nil {
		errno_str := libc.strerror(i32(server_socket_err))
		fmt.eprintfln("Failed creating socket: %v", errno_str)
		return .Mango_Wrapper_Error
	}
	defer linux.close(server_socket)

	// Construct socket path
	server_socket_path: string
	{
		found: bool
		server_socket_path, found = os.lookup_env(SOCKET_PATH_ENVVAR, allocator = alloc)
		if !found {
			temp_dir: string
			temp_dir, found = os.lookup_env("XDG_RUNTIME_DIR", allocator = alloc)
			if !found {
				temp_dir = "/tmp"
			}

			server_socket_path = fmt.aprintf("%s/mango-wrapper.sock", temp_dir, allocator = alloc)
		}
	}
	os.remove(server_socket_path)

	server_socket_addr := linux.Sock_Addr_Un {
		sun_family = .UNIX,
	}
	mem.copy(
		&server_socket_addr.sun_path,
		raw_data(server_socket_path),
		min(len(server_socket_path), len(server_socket_addr.sun_path) - 1),
	)
	if errno := linux.bind(server_socket, &server_socket_addr); errno != nil {
		errno_str := libc.strerror(i32(errno))
		fmt.eprintfln("Failed binding socket: %v", errno_str)
		return .Mango_Wrapper_Error
	}

	if errno := linux.listen(server_socket, 1); errno != nil {
		errno_str := libc.strerror(i32(errno))
		fmt.eprintfln("Failed setting socket to listen: %v", errno_str)
		return .Mango_Wrapper_Error
	}
	fmt.printfln("Listening on %v", server_socket_path)

	vmem.arena_temp_end(temp_begin)

	// Get mango socket path
	mango_socket_path: string
	{
		found: bool
		mango_socket_path, found = os.lookup_env(MANGO_SOCKET_PATH_ENVVAR, allocator = alloc)
		if !found {
			// See if mmsg sets the envvar when run

			_, _, _, process_err := os.process_exec({command = {"mmsg"}}, allocator = alloc)
			if process_err != nil {
				fmt.eprintfln("Failed invoking mmsg: %v", process_err)
				return .Mango_Wrapper_Error
			}
			mango_socket_path, found := os.lookup_env(MANGO_SOCKET_PATH_ENVVAR, allocator = alloc)
			if !found {
				fmt.eprintln("Failure: Mango IPC socket is not set")
				return .Mango_Error
			}
		}
	}

	// Set up connection to mango socket
	watch_socket, watch_socket_err := linux.socket(
		.UNIX,
		.STREAM,
		{.NONBLOCK, .CLOEXEC},
		linux.Protocol(0),
	)
	if watch_socket_err != nil {
		errno_str := libc.strerror(i32(watch_socket_err))
		fmt.eprintfln("Failed creating socket: %v", errno_str)
		return .Mango_Wrapper_Error
	}
	defer linux.close(watch_socket)

	watch_socket_addr := linux.Sock_Addr_Un {
		sun_family = .UNIX,
	}
	mem.copy(
		&watch_socket_addr.sun_path,
		raw_data(mango_socket_path),
		min(len(mango_socket_path), len(watch_socket_addr.sun_path) - 1),
	)
	watch_socket_err = linux.connect(watch_socket, &watch_socket_addr)
	if watch_socket_err != nil {
		errno_str := libc.strerror(i32(watch_socket_err))
		fmt.eprintfln("Failed connecting to mango IPC socket: %v", errno_str)
		return .Mango_Wrapper_Error
	}

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
		mango_command := fmt.bprint(watch_buf, "watch all-monitors\n")
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

	state := State {
		curr_layout = .Tile,
		prev_layout = .Monocle,
	}
	for {
		temp_begin = vmem.arena_temp_begin(&arena)
		defer vmem.arena_temp_end(temp_begin)

		// Avoid spinlock
		time.sleep(time.Duration(f64(time.Millisecond) * 16.666))

		// Watch mango changes if any
		watch_bytes_read, watch_recv_err := linux.recv(watch_socket, watch_buf, {})
		if watch_recv_err != nil {
			if watch_recv_err != .EWOULDBLOCK {
				fmt.eprintfln("Failed reading mango IPC socket: %v", watch_recv_err)
			}
		} else if watch_bytes_read > 0 {
			// JSON parsing
			json_data, json_err := json.parse(watch_buf[:watch_bytes_read], allocator = alloc)
			if json_err != nil {
				fmt.eprintfln("Failed parsing JSON: %v", json_err)
				continue
			}
			defer json.destroy_value(json_data, allocator = alloc)

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

			layout_index := int(active_monitor["layout_index"].(json.Float))
			state.monitor.layout = cast(Layout)layout_index

			active_tags := active_monitor["active_tags"].(json.Array)
			if len(active_tags) == 1 {
				state.monitor.active_tag = int(active_tags[0].(json.Float))
			}

			tags := active_monitor["tags"].(json.Array)
			for i in 0 ..< len(state.monitor.tags) {
				tag := tags[i].(json.Object)
				has_clients := int(tag["client_count"].(json.Float)) > 0
				if has_clients {
					state.monitor.tags[i] = true
				}
			}
			fmt.println(state.monitor)
		}

		// Sync
		if state.curr_layout != state.monitor.layout {
			state.prev_layout = state.curr_layout
			state.curr_layout = state.monitor.layout
		}
		if state.active_tag != state.monitor.active_tag {
			state.active_tag = state.monitor.active_tag
		}

		connection_socket, connection_socket_err := linux.accept(
			server_socket,
			cast(^linux.Sock_Addr_Un)nil,
			{},
		)
		if connection_socket_err != nil {
			if connection_socket_err != .EWOULDBLOCK {
				fmt.eprintfln("Failed creating connection socket: %v", connection_socket_err)
			}

			continue
		}
		fmt.println("Established connection")

		// Read client commands if any
		now := time.now()
		diff: time.Duration
		connection_bytes_read: int
		for diff <= time.Second / 2 {
			time.sleep(SLEEP_TIME)
			diff = time.since(now)
			connection_recv_err: linux.Errno
			connection_bytes_read, connection_recv_err = linux.recv(
				connection_socket,
				server_buf,
				{},
			)
			if connection_recv_err != nil && connection_recv_err != .EWOULDBLOCK {
				err_str := libc.strerror(i32(connection_recv_err))
				fmt.eprintfln("Error receiving client data: %v", err_str)
				return .Mango_Wrapper_Error
			}
			if connection_bytes_read > 0 {
				break
			}
		}
		if connection_bytes_read <= 0 {
			fmt.eprintln("Error: didn't receive message from client")
			continue
		}

		builder: strings.Builder
		strings.builder_init(&builder, alloc)
		fmt.sbprintf(&builder, "dispatch ")

		write_data := server_buf[connection_bytes_read:]
		message_error := (^Message_Error)(raw_data(write_data))^
		message_error = .None

		read_data := server_buf[:connection_bytes_read]
		message := (^Message)(raw_data(read_data))^
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
				command_symbols[.Set_Layout],
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

		// Send command back to mango socket
		if message_error == .None {
			some_buf := make([]u8, mem.Kilobyte, alloc)
			bytes_to_send := len(fmt.bprintf(some_buf, "%s\n", strings.to_string(builder)))
			send_socket, send_socket_err := linux.socket(
				.UNIX,
				.STREAM,
				{.NONBLOCK, .CLOEXEC},
				linux.Protocol(0),
			)
			if send_socket_err != nil {
				errno_str := libc.strerror(i32(send_socket_err))
				fmt.eprintfln("Failed creating socket: %v", errno_str)
				return .Mango_Wrapper_Error
			}
			defer linux.close(send_socket)

			// NOTE: Honestly, I don't really know why, but if we don't stop
			// receiving (e.g. shutdown read), the data is not sent (I guess
			// the connection is not completed). I feel like this has something
			// to do with this:
			// https://blog.netherlabs.nl/articles/2009/01/18/the-ultimate-so_linger-page-or-why-is-my-tcp-not-reliable
			linux.shutdown(send_socket, .RD)

			send_socket_err = linux.connect(send_socket, &watch_socket_addr)
			if send_socket_err != nil {
				errno_str := libc.strerror(i32(send_socket_err))
				fmt.eprintfln("Failed connecting to mango IPC socket: %v", errno_str)
				return .Mango_Wrapper_Error
			}
			bytes_sent, send_err := linux.send(send_socket, some_buf[:], {})
			if send_err != nil {
				errno_str := libc.strerror(i32(send_err))
				fmt.eprintfln("Failed sending data to mango IPC socket: %v", errno_str)
				return .Mango_Wrapper_Error
			}

			fmt.println(bytes_sent)
			fmt.println(string(some_buf[:bytes_sent]))
			fmt.println(some_buf[:bytes_sent])
		}

		linux.send(server_socket, write_data, {})
		fmt.println(message)
		fmt.println(read_data)
	}

	return program_err
}

// 1-based index
wrap_forwards :: proc(active_tag: ^int, command: Command, builder: ^strings.Builder) -> bool {
	if active_tag^ >= 6 {
		active_tag^ = (active_tag^ + 1) %% 6
		fmt.sbprintf(builder, "%v,%v", command_symbols[command], active_tag^)

		return true
	}

	return false
}

// 1-based index
wrap_backwards :: proc(active_tag: ^int, command: Command, builder: ^strings.Builder) -> bool {
	if active_tag^ <= 1 {
		active_tag^ = ((active_tag^ - 2) %% 6) + 1
		fmt.sbprintf(builder, "%v,%v", command_symbols[command], active_tag^)

		return true
	}

	return false
}

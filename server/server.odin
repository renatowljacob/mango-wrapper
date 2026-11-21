package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

Tags :: [TAG_NUM]bool
Tag :: struct {
	prev_layout, curr_layout: Layout,
}
State :: struct {
	active_tag: int,
	tags:       [TAG_NUM]Tag,
	monitor:    struct {
		layout:     Layout,
		active_tag: int,
		tags:       Tags,
	},
}

main :: proc() {
	os.exit(int(entrypoint()))
}

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
		print_errno("Failed to create socket", server_socket_err)
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

	server_socket_addr: linux.Sock_Addr_Un
	set_unix_socket_address(&server_socket_addr, server_socket_path)
	if errno := linux.bind(server_socket, &server_socket_addr); errno != nil {
		print_errno("Failed to bind socket", errno)
		return .Mango_Wrapper_Error
	}

	if errno := linux.listen(server_socket, 1); errno != nil {
		print_errno("Failed to set socket to listen", errno)
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
				fmt.eprintfln("Failed to invoke mmsg: %v", process_err)
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
		print_errno("Failed to create socket", watch_socket_err)
		return .Mango_Wrapper_Error
	}
	defer linux.close(watch_socket)

	watch_socket_addr: linux.Sock_Addr_Un
	set_unix_socket_address(&watch_socket_addr, mango_socket_path)
	watch_socket_err = linux.connect(watch_socket, &watch_socket_addr)
	if watch_socket_err != nil {
		print_errno("Failed to connect to mango IPC socket", watch_socket_err)
		return .Mango_Wrapper_Error
	}

	// Allocate buffers for watch connection and server sockets
	watch_buf, server_buf: []u8
	{
		alloc_err: mem.Allocator_Error
		watch_buf, alloc_err = make([]u8, BUF_SIZE, alloc)
		if alloc_err != nil {
			fmt.eprintfln("Failed to allocate memory: %v", alloc_err)
			return .Mango_Wrapper_Error
		}

		// Watch mango changes
		mango_command := fmt.bprint(watch_buf, "watch all-monitors\n")
		if _, errno := linux.send(watch_socket, watch_buf[:len(mango_command)], {}); errno != nil {
			print_errno("Failed to send watch all-monitors to mango IPC socket", errno)
			return .Mango_Wrapper_Error
		}

		server_buf, alloc_err = make([]u8, BUF_SIZE, alloc)
		if alloc_err != nil {
			fmt.eprintfln("Failed to allocate memory: %v", alloc_err)
			return .Mango_Wrapper_Error
		}
	}

	state: State
	for &tag in state.tags {
		tag = {
			curr_layout = .Tile,
			prev_layout = .Monocle,
		}
	}
	for {
		temp_begin = vmem.arena_temp_begin(&arena)
		defer vmem.arena_temp_end(temp_begin)

		// Avoid spinlock
		time.sleep(SLEEP_TIME)

		// Watch mango changes if any
		watch_bytes_read, watch_recv_err := linux.recv(watch_socket, watch_buf, {})
		if watch_recv_err != nil {
			if watch_recv_err != .EWOULDBLOCK {
				fmt.eprintfln("Failed to read mango IPC socket: %v", watch_recv_err)
			}
		} else if watch_bytes_read > 0 {
			// JSON parsing
			json_data, json_err := json.parse(watch_buf[:watch_bytes_read], allocator = alloc)
			if json_err != nil {
				fmt.eprintfln("Failed to parse JSON: %v", json_err)
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
				state.monitor.tags[i] = true if has_clients else false
			}
		}

		// Sync
		if state.active_tag != state.monitor.active_tag {
			state.active_tag = state.monitor.active_tag
		}
		curr_tag := &state.tags[clamp(state.active_tag - 1, 0, TAG_NUM)]
		if curr_tag.curr_layout != state.monitor.layout {
			curr_tag.prev_layout = curr_tag.curr_layout
			curr_tag.curr_layout = state.monitor.layout
		}

		connection_socket, connection_socket_err := linux.accept(
			server_socket,
			cast(^linux.Sock_Addr_Un)nil,
			{},
		)
		if connection_socket_err != nil {
			if connection_socket_err != .EWOULDBLOCK {
				fmt.eprintfln("Failed to create connection socket: %v", connection_socket_err)
			}

			continue
		}

		// Read client commands if any
		now := time.now()
		diff: time.Duration
		connection_bytes_read := recv(connection_socket, server_buf, time.Second / 2) or_return
		if connection_bytes_read <= 0 {
			fmt.eprintln("Error: didn't receive message from client")
			continue
		}

		builder: strings.Builder
		strings.builder_init(&builder, alloc)
		fmt.sbprintf(&builder, "mmsg dispatch ")

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
		case .View, .Tag:
		case .Toggle_Layout:
			curr_tag.curr_layout, curr_tag.prev_layout = curr_tag.prev_layout, curr_tag.curr_layout
			fmt.sbprintf(&builder, "setlayout,%v", layout_symbols[curr_tag.curr_layout])
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
					}
					last_occupied_tag = i
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
					if i > state.active_tag {
						has_clients_to_the_right = true
					}
					first_occupied_tag = i
				}
			}
			if has_clients_to_the_right {
				fmt.sbprintf(&builder, "%v", command_symbols[message.command])
			} else if first_occupied_tag != state.active_tag {
				fmt.sbprintf(&builder, "%v,%v", command_symbols[.View], first_occupied_tag)
			}
		}

		// Send command back to mango
		// NOTE: Don't try sending it over mango's socket directly (it's very brittle)
		if message_error == .None {
			cmd := strings.to_string(builder)
			split_cmd := strings.split(cmd, " ", allocator = alloc)

			process_state, _, _, process_err := os.process_exec(
				{command = split_cmd[:]},
				allocator = alloc,
			)
			if process_err != nil {
				fmt.eprintfln("Failed to invoke mmsg: %v", process_err)
			}
			if process_state.exit_code != 0 {
				fmt.eprintfln("mmsg exit status code: %v", process_state.exit_code)
			}
		}

		// Send error to client (None by default)
		bytes_sent: int
		bytes_sent, connection_socket_err = linux.send(connection_socket, write_data, {})
		if connection_socket_err != nil {
			print_errno("Failed to send data to client: %v", connection_socket_err)
		}
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

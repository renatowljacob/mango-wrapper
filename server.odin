package main

import "core:encoding/json"
import "core:flags"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:net"
import "core:os"
import "core:strings"

BUF_SIZE :: mem.Megabyte

@(rodata)
command_symbols := [Command]string {
	.None          = "",
	.Set_Layout    = "setlayout",
	.Switch_Layout = "switch_layout",
	.Toggle_Layout = "", // custom
	.View_To_Left  = "viewtoleft",
	.View_To_Right = "viewtoright",
	.Tag_To_Left   = "tagtoleft",
	.Tag_To_Right  = "tagtoleft",
}

// Possible layouts
@(rodata)
layout_symbols := [Layout]string {
	.None              = "",
	.Tile              = "tile",
	.Scroller          = "scroller",
	.Monocle           = "monocle",
	.Grid              = "grid",
	.Deck              = "deck",
	.Center_tile       = "center_tile",
	.Vertical_Tile     = "vertical_tile",
	.Right_Tile        = "right_tile",
	.Vertical_Scroller = "vertical_scroller",
	.Vertical_Grid     = "vertical_grid",
	.Vertical_Deck     = "vertical_deck",
	.Dwindle           = "dwindle",
	.Fair              = "fair",
	.Vertical_Fair     = "vertical_fair",
}

Tag :: int
Tags :: [TAG_NUM]bool
Monitor_State :: struct {
	layout:     Layout,
	active_tag: Tag,
	tags:       Tags,
}

State :: struct {
	prev_layout, curr_layout: Layout,
}

main :: proc() {
	os.exit(int(entrypoint()))
}

@(private = "file")
entrypoint :: proc() -> Program_Error {
	Options :: struct {
		port: u16 `usage:"A port other than 0 to bind to"`,
	}

	// Setup allocator
	arena: vmem.Arena
	if err := vmem.arena_init_static(&arena, BUF_SIZE * 2); err != nil {
		fmt.eprintfln("Failed on memory allocator init: %v", err)
		return .Mango_Wrapper_Error
	}
	alloc := vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)

	temp_begin := vmem.arena_temp_begin(&arena)

	// Parse flags
	options: Options
	flags.parse_or_exit(&options, os.args, flags.Parsing_Style.Odin, allocator = alloc)

	if program_name, err := check_for_mango(alloc); err != nil {
		if err == .Program_Not_Found {
			fmt.eprintfln("Failure: %v not found", program_name)
		} else if err != nil {
			fmt.eprintfln("Failed invoking command -v: %v", err)
		}
		return err
	}

	vmem.arena_temp_end(temp_begin)

	// Retry with new port in case address is in use
	address, _ := net.parse_ip4_address(LOCALHOST)
	port := int(options.port)
	ensure(port != 0, "Supplied port must not be 0")

	server_socket: net.TCP_Socket
	network_err: net.Network_Error
	server_socket, network_err = net.listen_tcp({address = address, port = int(options.port)})
	if network_err == net.Bind_Error.Address_In_Use {
		fmt.eprintfln("Failed creating TCP socket: supplied port %v already in use", options.port)
		return .Mango_Wrapper_Error
	}
	if network_err != nil {
		fmt.eprintfln(
			"Failed creating TCP socket with supplied port %v: %v",
			options.port,
			network_err,
		)
		return .Mango_Wrapper_Error
	}
	defer net.close(server_socket)
	fmt.printfln("Listening on port %v", port)

	read_buf, alloc_err := make([]u8, BUF_SIZE, alloc)
	if alloc_err != nil {
		fmt.eprintfln("Failed allocating memory: %v", alloc_err)
		return .Mango_Wrapper_Error
	}
	temp_begin = vmem.arena_temp_begin(&arena)

	state := State {
		curr_layout = .Tile,
		prev_layout = .Monocle,
	}
	for {
		vmem.arena_temp_end(temp_begin)

		// TODO: If bytes read is less than size of Message struct, reread the
		// socket
		bytes_read, tcp_err := net.recv_tcp(server_socket, read_buf)
		if tcp_err != nil {
			fmt.eprintfln("Failed reading TCP socket: %v", tcp_err)
			continue
		}
		if bytes_read < size_of(Message) {
			continue
		}
		read_data := read_buf[:bytes_read]

		write_buf := make([]u8, size_of(Message_Error), alloc)
		write_data := &(transmute([]Message_Error)write_buf)[0]

		monitor_state: Monitor_State
		{
			mmsg_command := [?]string{"mmsg", "get", "all-monitors"}
			process_state, stdout, _, process_err := os.process_exec(
				{command = mmsg_command[:]},
				alloc,
			)
			if process_err != nil {
				fmt.eprintfln("Failed invoking mmsg: %v", process_err)
				continue
			}
			if process_state.exit_code != 0 {
				fmt.eprintfln("mmsg exit code: %v", process_state.exit_code)
				continue
			}

			json_data, json_err := json.parse(stdout)
			if json_err != nil {
				fmt.eprintfln("Failed parsing JSON: %v", json_err)
				continue
			}
			defer json.destroy_value(json_data)

			root := json_data.(json.Object)
			monitors := root["monitors"].(json.Array)
			active_monitor: json.Object
			for i in 0 ..< len(monitors) {
				monitor, monitor_ok := monitors[i].(json.Object)
				if !monitor_ok {
					continue
				}

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
			monitor_state.layout = Layout(layout_index)

			tags := active_monitor["tags"].(json.Array)
			for i in 0 ..< min(len(tags), len(monitor_state.tags)) {
				tag := tags[i].(json.Object)
				is_active := tag["is_active"].(json.Boolean)
				if (is_active) {
					monitor_state.active_tag = i
				}

				has_clients := tag["client_count"].(json.Integer) > 0
				if has_clients {
					monitor_state.tags[i] = true
				}
			}
		}

		builder: strings.Builder
		strings.builder_init(&builder, alloc)
		fmt.sbprintf(&builder, "mmsg dispatch ")

		message := (^Message)(raw_data(read_data[:size_of(Message)]))^
		switch message.command {
		case .Set_Layout:
			switch message.layout {
			case .Tile ..= .Vertical_Fair:
				break
			case .None:
				fallthrough
			case:
				write_data^ = Message_Error.Set_Layout_Without_Layout
				net.send(server_socket, write_buf)

				continue
			}
			fmt.sbprintf(
				&builder,
				"%v,%v",
				command_symbols[message.command],
				layout_symbols[message.layout],
			)

			state.prev_layout = monitor_state.layout
			state.curr_layout = message.layout
		case .Switch_Layout:
			state.prev_layout = state.curr_layout
			state.curr_layout = Layout((int(state.curr_layout) + 1) % len(Layout))
			fmt.sbprintf(&builder, "%v", command_symbols[message.command])
		case .Toggle_Layout:
			state.curr_layout, state.prev_layout = state.prev_layout, state.curr_layout
			fmt.sbprintf(
				&builder,
				"%v,%v",
				command_symbols[message.command],
				layout_symbols[state.curr_layout],
			)
		case .View_To_Left, .View_To_Right, .Tag_To_Left, .Tag_To_Right:
			fmt.sbprintf(&builder, "%v", command_symbols[message.command])
		case .None:
			fallthrough
		case:
			write_data^ = Message_Error.Message_Without_Command
			net.send(server_socket, write_buf)

			continue
		}

		cmd := strings.to_string(builder)
		cmd_arr := strings.split(cmd, " ", alloc)
		process_state, _, _, process_err := os.process_exec({command = cmd_arr[:]}, alloc)
		if process_err != nil {
			fmt.eprintfln("Failed invoking mmsg: %v", process_err)
			return .MMSG_Error
		}
		if process_state.exit_code != 0 {
			fmt.eprintfln("mmsg exit code: %v", process_state.exit_code)
			return .MMSG_Error
		}

		write_data^ = Message_Error.None
		net.send(server_socket, write_buf)
	}

	return .None
}

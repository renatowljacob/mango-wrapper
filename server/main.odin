package server

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:net"
import "core:os"
import "core:time"

// Can Mango be run on BSDs?
when ODIN_OS != .Linux {
	#panic("OS not supported")
}

BUF_SIZE :: mem.Megabyte * 4
DEFAULT_ALIGNMENT :: 8
TAG_NUM :: 6

Error :: enum {
	None,
	Mango_Wrapper_Error,
	Mango_Error,
	MMSG_Error,
	Program_Not_Found,
}

// Commands clients can issue to the server
Command :: enum {
	Set_Layout,
	Toggle_Layout,
	Next_Workspace,
	Prev_Workspace,
	None,
}

// How commands are written into the buffer
@(rodata)
commands := [Command]string {
	.Set_Layout     = "set_layout",
	.Toggle_Layout  = "toggle_layout",
	.Next_Workspace = "next_workspace",
	.Prev_Workspace = "prev_workspace",
	.None           = "",
}

// Possible layouts
Layout :: enum {
	Tile,
	Scroller,
	Monocle,
	Grid,
	Deck,
	Center_tile,
	Vertical_Tile,
	Right_Tile,
	Vertical_Scroller,
	Vertical_Grid,
	Vertical_Deck,
	Dwindle,
	Fair,
	Vertical_Fair,
	None,
}

// Default layout symbols
@(rodata)
layouts := [Layout]string {
	.Tile              = "T",
	.Scroller          = "S",
	.Grid              = "G",
	.Monocle           = "M",
	.Deck              = "K",
	.Center_tile       = "CT",
	.Vertical_Tile     = "RT",
	.Right_Tile        = "VS",
	.Vertical_Scroller = "VT",
	.Vertical_Grid     = "VG",
	.Vertical_Deck     = "VK",
	.Dwindle           = "DW",
	.Fair              = "F",
	.Vertical_Fair     = "VF",
	.None              = "",
}

Message :: struct {
	command: Command,
	layout:  Layout,
}

Tag :: int
Tags :: [TAG_NUM]bool

Monitor_State :: struct {
	layout:     Layout,
	active_tag: Tag,
	tags:       Tags,
}

prev_layout, curr_layout: Layout

main :: proc() {
	os.exit(int(entrypoint()))
}

entrypoint :: proc() -> Error {
	arena: vmem.Arena
	if err := vmem.arena_init_static(&arena, mem.Megabyte * 4); err != nil {
		fmt.printfln("Failed on memory allocator init: %v", err)
		return .Mango_Wrapper_Error
	}
	alloc := vmem.arena_allocator(&arena)
	defer vmem.arena_destroy(&arena)

	temp_begin := vmem.arena_temp_begin(&arena)

	tests := [][3]string{{"command", "-v", "mango"}, {"command", "-v", "mmsg"}}
	for &test in tests {
		state, _, _, err := os.process_exec({command = test[:]}, alloc)
		if state.exit_code != 0 {
			fmt.printfln("Failure: %v not found", test[1])
			return .Program_Not_Found
		}
		if err != nil {
			fmt.printfln("Failed invoking command -v: %v", err)
			return .Mango_Wrapper_Error
		}
	}
	vmem.arena_temp_end(temp_begin)

	// Retry 10 times in case address is in use
	address, _ := net.parse_ip4_address("127.0.0.1")
	port := 20000
	server_socket: net.TCP_Socket
	for attempts := 10;; attempts -= 1 {
		err: net.Network_Error
		server_socket, err = net.listen_tcp({address = address, port = port})
		if err == net.Bind_Error.Address_In_Use && attempts >= 0 {
			port += 1
			continue
		}
		if err != nil {
			fmt.printfln("Failed creating TCP socket: %v", err)
			return .Mango_Wrapper_Error
		}
	}
	defer net.close(server_socket)

	stdout_fd: ^os.File
	{
		err: os.Error
		stdout_fd, err = os.create_temp_file("", "")
		if err != nil {
			fmt.printfln("Failed creating temp file: %v", err)
			return .Mango_Wrapper_Error
		}
	}
	defer os.close(stdout_fd)

	buf, alloc_err := make([]u8, BUF_SIZE, alloc)
	if alloc_err != nil {
		fmt.printfln("Failed allocating memory: %v", alloc_err)
		return .Mango_Wrapper_Error
	}
	temp_begin = vmem.arena_temp_begin(&arena)

	for {
		vmem.arena_temp_end(temp_begin)

		bytes_read, tcp_err := net.recv_tcp(server_socket, buf)
		if tcp_err != nil {
			fmt.printfln("Failed reading TCP socket: %v", tcp_err)
			continue
		}
		if bytes_read == 0 {
			continue
		}

		data := buf[:bytes_read]
		fmt.println(data)

		message: Message
		for command, idx in commands {
			command_len := len(command)
			cmd_in_buf := string(data[:command_len])
			if command == cmd_in_buf {
				message.command = idx
			}
		}

		switch message.command {
		case .Set_Layout:
			for layout, idx in layouts {
				command_len := len(commands[message.command])
				layout_len := len(layout)
				layout_in_buf := string(data[command_len:layout_len])
				if layout == layout_in_buf {
					message.layout = idx
				}
			}

			if message.layout == .None {
				continue
			}
		case .Toggle_Layout:
			curr_layout, prev_layout = prev_layout, curr_layout
		case .Next_Workspace:

		case .Prev_Workspace:
		case .None:
			continue
		}

		stdout, err := get_monitor_state(stdout_fd, alloc)
		if err != nil {
			fmt.printfln("Failed to get monitor state: %v", err)
		}

	}

	return .None
}

get_monitor_state :: proc(
	stdout: ^os.File,
	allocator := context.allocator,
) -> (
	state: Monitor_State,
) {
	mmsg_command := [?]string{"mmsg", "get", "all-monitors"}
	process_state, stdout, _, process_err := os.process_exec(
		{command = mmsg_command[:], stdout = stdout},
		allocator,
	)
	if process_state.exit_code != 0 {
		fmt.printfln("mmsg exit code: %v", process_state.exit_code)
		return
	}
	if process_err != nil {
		fmt.printfln("Failed invoking mmsg: %v", process_err)
		return
	}

	json_data, json_err := json.parse(stdout)
	if json_err != nil {
		fmt.printfln("Failed parsing JSON: %v", json_err)
		return
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
		return
	}

	layout_index := active_monitor["layout_index"].(json.Integer)
	state.layout = Layout(layout_index)

	tags := active_monitor["tags"].(json.Array)
	for i in 0 ..< min(len(tags), len(state.tags)) {
		tag := tags[i].(json.Object)
		is_active := tag["is_active"].(json.Boolean)
		if (is_active) {
			state.active_tag = i
		}

		has_clients := tag["client_count"].(json.Integer) > 0
		if has_clients {
			state.tags[i] = true
		}
	}

	return
}

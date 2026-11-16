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

// Commands a client can issue to the server
Command :: enum {
	None,
	Set_Layout,
	Switch_Layout,
	Toggle_Layout,
	View_To_Left,
	View_To_Right,
	Tag_To_Left,
	Tag_To_Right,
}
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
Layout :: enum {
	None,
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
}
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

Message :: struct {
	command: Command,
	layout:  Layout,
}

State :: struct {
	prev_layout, curr_layout: Layout,
}

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

	// Retry some times in case address is in use
	address, _ := net.parse_ip4_address("127.0.0.1")
	port := 20000
	server_socket: net.TCP_Socket
	for attempts := 20;; attempts -= 1 {
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

	buf, alloc_err := make([]u8, BUF_SIZE, alloc)
	if alloc_err != nil {
		fmt.printfln("Failed allocating memory: %v", alloc_err)
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
		bytes_read, tcp_err := net.recv_tcp(server_socket, buf)
		if tcp_err != nil {
			fmt.printfln("Failed reading TCP socket: %v", tcp_err)
			continue
		}
		if bytes_read == 0 {
			continue
		}

		data := buf[:bytes_read]
		monitor_state := get_monitor_state(alloc)
		message := Message {
			command = (^Command)(raw_data(data[:size_of(Command)]))^,
		}
		switch message.command {
		case .Set_Layout:
			data = data[size_of(Command):]
			message.layout = (^Layout)(raw_data(data[:size_of(Layout)]))^
			switch message.layout {
			case .Tile ..= .Vertical_Fair:
				break
			case .None:
				fallthrough
			case:
				// TODO: Send error message to client
				continue
			}
		case .Switch_Layout:
		case .Toggle_Layout:
			state.curr_layout, state.prev_layout = state.prev_layout, state.curr_layout
		case .View_To_Left:
		case .View_To_Right:
		case .Tag_To_Left:
		case .Tag_To_Right:
		case .None:
			fallthrough
		case:
			// TODO: Send error message to client
			continue
		}

		// TODO: Dispatch command to mango
	}

	return .None
}

get_monitor_state :: proc(allocator := context.allocator) -> (state: Monitor_State) {
	mmsg_command := [?]string{"mmsg", "get", "all-monitors"}
	process_state, stdout, _, process_err := os.process_exec(
		{command = mmsg_command[:]},
		allocator,
	)
	if process_err != nil {
		fmt.printfln("Failed invoking mmsg: %v", process_err)
		return
	}
	if process_state.exit_code != 0 {
		fmt.printfln("mmsg exit code: %v", process_state.exit_code)
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

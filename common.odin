package main

import "core:c/libc"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sys/linux"
import "core:time"

// Can Mango be run on BSDs?
when ODIN_OS != .Linux {
	#panic("OS not supported")
}

SLEEP_TIME :: time.Millisecond
TAG_NUM :: 6
BUF_SIZE :: mem.Megabyte
MANGO_SOCKET_PATH_ENVVAR :: "MANGO_INSTANCE_SIGNATURE"
SOCKET_PATH_ENVVAR :: "MANGO_WRAPPER_SOCKET"

Program_Error :: enum {
	None,
	Invalid_Arguments,
	Mango_Wrapper_Error,
	Mango_Error,
	MMSG_Error,
	Program_Not_Found,
	Command_Not_Found,
	Layout_Not_Found,
}

Command :: enum {
	None,
	Toggle_Layout,
	View,
	View_To_Left,
	View_To_Right,
	View_To_Left_Have_Client,
	View_To_Right_Have_Client,
	Tag,
	Tag_To_Left,
	Tag_To_Right,
}

@(rodata)
command_symbols := [Command]string {
	.None                      = "",
	.Toggle_Layout             = "toggle_layout", // custom
	.View                      = "view",
	.View_To_Left              = "viewtoleft",
	.View_To_Right             = "viewtoright",
	.View_To_Left_Have_Client  = "viewtoleft_have_client",
	.View_To_Right_Have_Client = "viewtoright_have_client",
	.Tag                       = "tag",
	.Tag_To_Left               = "tagtoleft",
	.Tag_To_Right              = "tagtoright",
}

Layout :: enum {
	Tile,
	Scroller,
	Grid,
	Monocle,
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

// Possible layouts
@(rodata)
layout_symbols := [Layout]string {
	.Tile              = "tile",
	.Scroller          = "scroller",
	.Grid              = "grid",
	.Monocle           = "monocle",
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

Message_Error :: enum {
	None,
	Set_Layout_Without_Layout,
	Message_Without_Command,
	Server_Error,
}

Message :: struct {
	command: Command,
}

check_for_mango :: proc(alloc := context.allocator) -> Program_Error {
	tests := [][2]string{{"which", "mango"}, {"which", "mmsg"}}
	for &test in tests {
		state, _, _, err := os.process_exec({command = test[:]}, alloc)
		if state.exit_code != 0 {
			fmt.eprintfln("Failure: %v not found", test[1])
			return .Program_Not_Found
		}
		if err != nil {
			fmt.eprintfln("Failed invoking command -v: %v", err)
			return .Mango_Wrapper_Error
		}
	}

	return .None
}

print_errno :: proc(error_msg: string, errno: linux.Errno) {
	errno_str := libc.strerror(i32(errno))
	fmt.eprintfln("%s: %v", error_msg, errno_str)
}

recv :: proc(socket: linux.Fd, buf: []u8, timeout: time.Duration) -> (int, Program_Error) {
	now := time.now()
	diff: time.Duration
	bytes_read: int
	for diff <= timeout {
		time.sleep(SLEEP_TIME)
		diff = time.since(now)
		recv_err: linux.Errno
		bytes_read, recv_err = linux.recv(socket, buf, {})
		if recv_err != nil && recv_err != .EWOULDBLOCK {
			print_errno("Error receiving client data: %v", recv_err)
			return bytes_read, .Mango_Wrapper_Error
		}
		if bytes_read > 0 {
			break
		}
	}

	return bytes_read, .None
}

set_unix_socket_address :: proc(addr: ^linux.Sock_Addr_Un, path: string) {
	addr^ = linux.Sock_Addr_Un {
		sun_family = .UNIX,
	}
	mem.copy(&addr.sun_path, raw_data(path), min(len(path), len(addr.sun_path) - 1))
}

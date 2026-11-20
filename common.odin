package main

import "core:fmt"
import "core:mem"
import "core:os"
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
	Set_Layout,
	Switch_Layout,
	Toggle_Layout,
	View,
	View_To_Left,
	View_To_Right,
	View_To_Left_Have_Client,
	View_To_Right_Have_Client,
	Tag,
	Tag_To_Left,
	Tag_To_Right,
	None,
}

@(rodata)
command_symbols := [Command]string {
	.Set_Layout                = "setlayout",
	.Switch_Layout             = "switch_layout",
	.Toggle_Layout             = "toggle_layout", // custom
	.View                      = "view",
	.View_To_Left              = "viewtoleft",
	.View_To_Right             = "viewtoright",
	.View_To_Left_Have_Client  = "viewtoleft_have_client",
	.View_To_Right_Have_Client = "viewtoright_have_client",
	.Tag                       = "tag",
	.Tag_To_Left               = "tagtoleft",
	.Tag_To_Right              = "tagtoleft",
	.None                      = "",
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
	None,
}

// Possible layouts
@(rodata)
layout_symbols := [Layout]string {
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
	.None              = "",
}

Message_Error :: enum {
	None,
	Set_Layout_Without_Layout,
	Message_Without_Command,
	Server_Error,
}

Message :: struct {
	command: Command,
	layout:  Layout,
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

package main

import "core:mem"
import "core:os"

// Can Mango be run on BSDs?
when ODIN_OS != .Linux {
	#panic("OS not supported")
}

LOCALHOST :: "127.0.0.1"
TAG_NUM :: 6

Program_Error :: enum {
	None,
	Mango_Wrapper_Error,
	Mango_Error,
	MMSG_Error,
	Program_Not_Found,
}

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

Message_Error :: enum {
	None,
	Set_Layout_Without_Layout,
	Message_Without_Command,
}

Message :: struct {
	command: Command,
	layout:  Layout,
}

check_for_mango :: proc(alloc := context.allocator) -> (Maybe(string), Program_Error) {
	tests := [][3]string{{"command", "-v", "mango"}, {"command", "-v", "mmsg"}}
	for &test in tests {
		state, _, _, err := os.process_exec({command = test[:]}, alloc)
		if state.exit_code != 0 {
			return test[1], .Program_Not_Found
		}
		if err != nil {
			return nil, .Mango_Wrapper_Error
		}
	}

	return nil, .None
}

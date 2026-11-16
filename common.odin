package main

TAG_NUM :: 6

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

MessageError :: enum {
	None,
	Set_Layout_Without_Layout,
	Message_Without_Command,
}

Message :: struct {
	command: Command,
	layout:  Layout,
}

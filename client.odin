package main

import "core:fmt"
import vmem "core:mem/virtual"
import "core:net"
import "core:os"

// Can Mango be run on BSDs?
when ODIN_OS != .Linux {
	#panic("OS not supported")
}

main :: proc() {

}

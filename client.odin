package main

import "core:flags"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:net"
import "core:os"

main :: proc() {
	os.exit(int(entrypoint()))
}

@(private = "file")
entrypoint :: proc() -> Program_Error {
	// TODO: Dispatch function arg
	Options :: struct {
		port: u16 `usage:"A port other than 0 to connect to"`,
	}

	arena: vmem.Arena
	if err := vmem.arena_init_static(&arena, mem.Megabyte); err != nil {
		fmt.eprintfln("Failed on memory allocator init: %v", err)
		return .Mango_Wrapper_Error
	}
	alloc := vmem.arena_allocator(&arena)

	temp_begin := vmem.arena_temp_begin(&arena)

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

	address, _ := net.parse_ip4_address(LOCALHOST)
	port := int(options.port)
	ensure(port != 0, "Supplied port must not be 0")

	connection_socket: net.TCP_Socket
	network_err: net.Network_Error
	connection_socket, network_err = net.dial_tcp_from_address_and_port(address, port)
	if network_err != nil {
		fmt.eprintfln(
			"Failed connecting to TCP socket with supplied port %v: %v",
			port,
			network_err,
		)
		return .Mango_Wrapper_Error
	}
	defer net.close(connection_socket)
	fmt.printfln("Connected to %v:%v", LOCALHOST, port)

	return .None
}

package main

import "core:c/libc"
import "core:flags"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:sys/linux"

main :: proc() {
	os.exit(int(entrypoint()))
}

@(private = "file")
entrypoint :: proc() -> (program_err: Program_Error) {
	Options :: struct {
		command: string `args:pos=0,required usage:"Command to send to the server"`,
		args:    Maybe(string) `args:pos=1 usage:"Command arguments if any"`,
	}

	arena: vmem.Arena
	if err := vmem.arena_init_static(&arena, BUF_SIZE); err != nil {
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

	// Parse flags
	message: Message
	{
		for command_symbol, idx in command_symbols {
			command_idx := cast(Command)idx
			if options.command == command_symbol {
				message.command = command_idx
				break
			}
		}
		if message.command == .None {
			fmt.eprintfln("Error: Command not found")
			return .Command_Not_Found
		}

		#partial switch message.command {
		case .Set_Layout, .Switch_Layout, .Toggle_Layout:
			for layout_symbol, idx in layout_symbols {
				layout_idx := cast(Layout)idx
				if options.args == layout_symbol {
					message.layout = layout_idx
					break
				}
			}
			if message.layout == .None {
				fmt.eprintfln("Error: Layout not found")
				return .Layout_Not_Found
			}
		case:
		}
	}

	// Get server socket path
	server_socket_path, found := os.lookup_env(SOCKET_PATH_ENVVAR, allocator = alloc)
	if !found {
		fmt.eprintln("Failed to get server socket address (is it running?)")
		return .Mango_Wrapper_Error
	}

	// Connect to server socket
	client_socket: linux.Fd
	{
		errno: linux.Errno
		if client_socket, errno = linux.socket(.UNIX, .STREAM, {.CLOEXEC}, linux.Protocol(0));
		   errno != nil {
			errno_str := libc.strerror(i32(errno))
			fmt.eprintfln("Failed to create client socket: %v", errno_str)
			return .Mango_Wrapper_Error
		}

		addr := linux.Sock_Addr_Un {
			sun_family = .UNIX,
		}
		mem.copy(
			&addr.sun_path,
			raw_data(server_socket_path),
			min(len(server_socket_path), len(addr.sun_path) - 1),
		)
		if errno = linux.connect(client_socket, &addr); errno != nil {
			errno_str := libc.strerror(i32(errno))
			fmt.eprintfln("Failed to connect to server socket: %v", errno_str)
			return .Mango_Wrapper_Error
		}
	}

	vmem.arena_temp_end(temp_begin)

	// Send data to server socket
	client_buf := make([]u8, mem.Kilobyte, alloc)
	bytes_written := len(fmt.bprintf(client_buf, "%v", options.command))
	if (options.args != nil) {
		bytes_written += len(fmt.bprintf(client_buf, "%v", options.args))
	}

	write_data := client_buf[:bytes_written]
	linux.send(client_socket, write_data, {})

	read_data := client_buf[bytes_written:]
	linux.recv(client_socket, read_data, {})

	// Read it as Message
	message_error := (transmute([]Message_Error)read_data)[0]
	switch message_error {
	case .Set_Layout_Without_Layout:
		fmt.eprintfln("Error: setlayout didn't specify a layout")
		program_err = .Invalid_Arguments
	case .Message_Without_Command:
		fmt.eprintfln("Error: No command specified")
		program_err = .Invalid_Arguments
	case .Server_Error:
		fmt.eprintfln("Error: Server failure")
		program_err = .Mango_Wrapper_Error
	case .None:
	}

	return .None
}

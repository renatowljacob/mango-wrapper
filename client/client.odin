package main

import "core:c/libc"
import "core:flags"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:sys/linux"
import "core:time"

main :: proc() {
	os.exit(int(entrypoint()))
}

@(private = "file")
entrypoint :: proc() -> (program_err: Program_Error) {
	Options :: struct {
		command: string `args:"pos=0,required" usage:"Command to send to the server"`,
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

	if err := check_for_mango(alloc); err != nil {
		return err
	}

	// Parse flags
	message: Message
	for command_symbol, idx in command_symbols {
		if options.command == command_symbol {
			message.command = cast(Command)idx
			break
		}
	}

	// Get possible server socket paths
	possible_server_sockets: [dynamic; 3]string
	{
		path, found := os.lookup_env(SOCKET_PATH_ENVVAR, allocator = alloc)
		if found {
			append(&possible_server_sockets, path)
		}

		basename := "mango-wrapper.sock"
		path, found = os.lookup_env("XDG_RUNTIME_DIR", allocator = alloc)
		if found {
			concat_path := fmt.aprintf("%s/%s", path, basename, allocator = alloc)
			append(&possible_server_sockets, concat_path)
		}

		temp_dir := "/tmp"
		concat_path := fmt.aprintf("%s/%s", temp_dir, basename, allocator = alloc)
		append(&possible_server_sockets, concat_path)
	}

	// Connect to possible server socket paths
	client_socket: linux.Fd
	socket_found: bool
	{
		addr := linux.Sock_Addr_Un {
			sun_family = .UNIX,
		}
		for socket_path in possible_server_sockets {
			// NOTE: connect(2) tells that the state of the socket should be
			// considered unspecified should connect fail, so simply close and
			// create a new one every iteration
			errno: linux.Errno
			if client_socket, errno = linux.socket(
				.UNIX,
				.STREAM,
				{.NONBLOCK, .CLOEXEC},
				linux.Protocol(0),
			); errno != nil {
				errno_str := libc.strerror(i32(errno))
				fmt.eprintfln("Failed to create client socket: %v", errno_str)
				return .Mango_Wrapper_Error
			}

			mem.copy(
				&addr.sun_path,
				raw_data(socket_path),
				min(len(socket_path), len(addr.sun_path) - 1),
			)
			errno = linux.connect(client_socket, &addr)
			if errno == nil {
				socket_found = true
				break
			}
			// Path not found
			if errno == .ENOENT {
				linux.close(client_socket)
				continue
			}

			errno_str := libc.strerror(i32(errno))
			fmt.eprintfln("Failed to connect to server socket: %v", errno_str)
			return .Mango_Wrapper_Error
		}
	}
	if !socket_found {
		fmt.eprintln("Failed to get server socket address (is it running?)")
		return .Mango_Wrapper_Error
	}
	defer linux.close(client_socket)

	vmem.arena_temp_end(temp_begin)

	// Send data to server socket
	client_buf, alloc_err := make([]u8, mem.Kilobyte, alloc)
	if alloc_err != nil {
		fmt.eprintfln("Failed allocating memory: %v", alloc_err)
		return .Mango_Wrapper_Error
	}
	mem.copy(raw_data(client_buf), &message, size_of(message))

	write_data := client_buf[:size_of(message)]
	if _, errno := linux.send(client_socket, write_data, {}); errno != nil {
		err_str := libc.strerror(i32(errno))
		fmt.eprintfln("Error sending data to server: %v", err_str)
		return .Mango_Wrapper_Error
	}

	read_data := client_buf[size_of(message):]
	client_bytes_read := recv(client_socket, read_data, time.Second / 2) or_return
	if client_bytes_read <= 0 {
		fmt.eprintln("Error: didn't receive message from server")
		return .Mango_Wrapper_Error
	}

	message_error := (^Message_Error)(raw_data(read_data))^
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

#+build windows
package odnetlib

import "core:fmt"
import "core:sync"
import "core:thread"
import win "core:sys/windows"

SO_UPDATE_ACCEPT_CONTEXT :: 0x700B
NUM_PREPOST_ACCEPTS      :: 128
MAX_GQCS_ENTRIES         :: 64

Op_Type :: enum u8 {
	None,
	Accept,
	Read,
	Write,
}

Overlapped_Context :: struct {
	overlapped:  win.OVERLAPPED, // Must be first field
	op:          Op_Type,
	socket:      win.SOCKET,
	wsa_buf:     win.WSABUF,
	conn_id:     int,
	accept_buf:  [128]u8,
}

Windows_Engine :: struct {
	server:          ^Server,
	iocp:            win.HANDLE,
	listen_socket:   win.SOCKET,
	pool:            Connection_Pool,
	pool_mutex:      sync.Mutex,
	free_slots:      [dynamic]int,
	read_contexts:   []Overlapped_Context,
	write_contexts:  []Overlapped_Context,
	accept_contexts: [NUM_PREPOST_ACCEPTS]Overlapped_Context,
	workers:         [dynamic]^thread.Thread,
}

context_reset :: proc(ctx: ^Overlapped_Context, op: Op_Type, sock: win.SOCKET, conn_id: int) {
	ctx.overlapped = {}
	ctx.op = op
	ctx.socket = sock
	ctx.conn_id = conn_id
	ctx.wsa_buf = {}
}

win_init_winsock :: proc() -> bool {
	wsa_data: win.WSADATA
	return win.WSAStartup(win.WORD((2 << 8) | 2), &wsa_data) == 0
}

win_set_socket_options :: proc(s: win.SOCKET) -> bool {
	nodelay: win.c_int = 1
	if win.setsockopt(s, win.IPPROTO_TCP, win.TCP_NODELAY, cast(^win.c_char)&nodelay, size_of(nodelay)) != 0 {
		return false
	}
	reuse: win.c_int = 1
	if win.setsockopt(s, win.SOL_SOCKET, win.SO_REUSEADDR, cast(^win.c_char)&reuse, size_of(reuse)) != 0 {
		return false
	}
	return true
}

win_create_overlapped_socket :: proc() -> win.SOCKET {
	return win.WSASocketW(
		win.AF_INET,
		win.SOCK_STREAM,
		win.IPPROTO_TCP,
		nil,
		0,
		win.WSA_FLAG_OVERLAPPED,
	)
}

win_update_accept_context :: proc(client: win.SOCKET, listener: win.SOCKET) -> bool {
	listen_sock := listener
	return win.setsockopt(
		client,
		win.SOL_SOCKET,
		SO_UPDATE_ACCEPT_CONTEXT,
		cast(^win.c_char)&listen_sock,
		size_of(win.SOCKET),
	) == 0
}

win_acquire_connection :: proc(engine: ^Windows_Engine) -> ^Connection {
	sync.lock(&engine.pool_mutex)
	defer sync.unlock(&engine.pool_mutex)
	if len(engine.free_slots) == 0 do return nil
	idx := pop(&engine.free_slots)
	conn := &engine.pool.connections[idx]
	conn.state = .Accepted
	connection_reset(conn)
	return conn
}

win_release_connection :: proc(engine: ^Windows_Engine, conn: ^Connection) {
	if conn == nil do return
	if conn.socket != 0 {
		win.closesocket(win.SOCKET(conn.socket))
		conn.socket = 0
	}
	conn.state = .Free
	stats_dec_connection(&engine.server.stats)
	sync.lock(&engine.pool_mutex)
	append(&engine.free_slots, conn.id)
	sync.unlock(&engine.pool_mutex)
}

win_post_accept :: proc(engine: ^Windows_Engine, ctx: ^Overlapped_Context) -> bool {
	client_sock := win_create_overlapped_socket()
	if client_sock == win.INVALID_SOCKET do return false

	context_reset(ctx, .Accept, client_sock, -1)

	bytes_recvd: win.DWORD = 0
	addr_len := win.DWORD(size_of(win.sockaddr_in) + 16)

	success := win.AcceptEx(
		engine.listen_socket,
		client_sock,
		&ctx.accept_buf[0],
		0,
		addr_len,
		addr_len,
		&bytes_recvd,
		&ctx.overlapped,
	)

	if !success {
		err := win.WSAGetLastError()
		if err != win.c_int(win.ERROR_IO_PENDING) {
			win.closesocket(client_sock)
			return false
		}
	}
	return true
}

win_post_read :: proc(engine: ^Windows_Engine, conn: ^Connection, ctx: ^Overlapped_Context) -> bool {
	context_reset(ctx, .Read, win.SOCKET(conn.socket), conn.id)

	rem := len(conn.recv_buf) - conn.recv_len
	if rem <= 0 do return false

	ctx.wsa_buf.len = win.ULONG(rem)
	ctx.wsa_buf.buf = cast([^]win.CHAR)&conn.recv_buf[conn.recv_len]

	flags: win.DWORD = 0
	bytes_recvd: win.DWORD = 0

	res := win.WSARecv(
		ctx.socket,
		&ctx.wsa_buf,
		1,
		&bytes_recvd,
		&flags,
		cast(win.LPWSAOVERLAPPED)&ctx.overlapped,
		nil,
	)

	if res != 0 {
		err := win.WSAGetLastError()
		if err != win.c_int(win.ERROR_IO_PENDING) {
			return false
		}
	}
	conn.state = .Reading
	return true
}

win_post_write :: proc(engine: ^Windows_Engine, conn: ^Connection, ctx: ^Overlapped_Context) -> bool {
	context_reset(ctx, .Write, win.SOCKET(conn.socket), conn.id)

	to_send := conn.send_len - conn.send_pos
	if to_send <= 0 do return false

	ctx.wsa_buf.len = win.ULONG(to_send)
	ctx.wsa_buf.buf = cast([^]win.CHAR)&conn.send_buf[conn.send_pos]

	bytes_sent: win.DWORD = 0

	res := win.WSASend(
		ctx.socket,
		&ctx.wsa_buf,
		1,
		&bytes_sent,
		0,
		cast(win.LPWSAOVERLAPPED)&ctx.overlapped,
		nil,
	)

	if res != 0 {
		err := win.WSAGetLastError()
		if err != win.c_int(win.ERROR_IO_PENDING) {
			return false
		}
	}
	conn.state = .Writing
	return true
}

win_worker_loop :: proc(data: rawptr) {
	engine := cast(^Windows_Engine)data
	entries: [MAX_GQCS_ENTRIES]win.OVERLAPPED_ENTRY
	num_removed: win.c_ulong = 0

	for engine.server.running {
		ok := win.GetQueuedCompletionStatusEx(
			engine.iocp,
			&entries[0],
			win.c_ulong(len(entries)),
			&num_removed,
			win.INFINITE,
			false,
		)

		if !ok {
			if !engine.server.running do break
			continue
		}

		for i in 0..<int(num_removed) {
			entry := &entries[i]
			if entry.lpOverlapped == nil do continue

			ctx := cast(^Overlapped_Context)entry.lpOverlapped
			bytes := int(entry.dwNumberOfBytesTransferred)

			if bytes == 0 && ctx.op != .Accept {
				if ctx.conn_id >= 0 && ctx.conn_id < len(engine.pool.connections) {
					conn := &engine.pool.connections[ctx.conn_id]
					win_release_connection(engine, conn)
				}
				continue
			}

			switch ctx.op {
			case .Accept:
				client_sock := ctx.socket
				win_update_accept_context(client_sock, engine.listen_socket)
				win_set_socket_options(client_sock)

				conn := win_acquire_connection(engine)
				if conn == nil {
					win.closesocket(client_sock)
				} else {
					conn.socket = uintptr(client_sock)
					stats_inc_connection(&engine.server.stats)

					win.CreateIoCompletionPort(win.HANDLE(client_sock), engine.iocp, win.ULONG_PTR(conn.id), 0)

					if !win_post_read(engine, conn, &engine.read_contexts[conn.id]) {
						win_release_connection(engine, conn)
					}
				}

				win_post_accept(engine, ctx)

			case .Read:
				if ctx.conn_id < 0 || ctx.conn_id >= len(engine.pool.connections) do continue
				conn := &engine.pool.connections[ctx.conn_id]
				conn.recv_len += bytes
				stats_add_bytes_recv(&engine.server.stats, bytes)

				req: Request
				consumed, status := parse_request(conn.recv_buf[:conn.recv_len], &req)

				if status == .Incomplete {
					if !win_post_read(engine, conn, &engine.read_contexts[conn.id]) {
						win_release_connection(engine, conn)
					}
				} else if status == .Error {
					res: Response
					response_init(&res)
					res.status = .Bad_Request
					res.keep_alive = false
					response_set_body_string(&res, "400 Bad Request\r\n")

					written, _ := serialize_response(&res, conn.send_buf)
					conn.send_len = written
					conn.send_pos = 0
					conn.keep_alive = false
					win_post_write(engine, conn, &engine.write_contexts[conn.id])
				} else if status == .Complete {
					stats_inc_request(&engine.server.stats)

					res: Response
					router_dispatch(&engine.server.router, &req, &res)
					res.keep_alive = req.keep_alive
					conn.keep_alive = req.keep_alive

					written, ok_ser := serialize_response(&res, conn.send_buf)
					if !ok_ser {
						win_release_connection(engine, conn)
						continue
					}

					conn.send_len = written
					conn.send_pos = 0

					rem := conn.recv_len - consumed
					if rem > 0 {
						copy(conn.recv_buf[:rem], conn.recv_buf[consumed : conn.recv_len])
					}
					conn.recv_len = rem

					if !win_post_write(engine, conn, &engine.write_contexts[conn.id]) {
						win_release_connection(engine, conn)
					}
				}

			case .Write:
				if ctx.conn_id < 0 || ctx.conn_id >= len(engine.pool.connections) do continue
				conn := &engine.pool.connections[ctx.conn_id]
				conn.send_pos += bytes
				stats_add_bytes_sent(&engine.server.stats, bytes)

				if conn.send_pos < conn.send_len {
					if !win_post_write(engine, conn, &engine.write_contexts[conn.id]) {
						win_release_connection(engine, conn)
					}
				} else {
					if conn.keep_alive {
						connection_reset(conn)

						// Check if another pipelined request is sitting in the buffer
						if conn.recv_len > 0 {
							req: Request
							consumed, status := parse_request(conn.recv_buf[:conn.recv_len], &req)
							if status == .Complete {
								stats_inc_request(&engine.server.stats)
								res: Response
								router_dispatch(&engine.server.router, &req, &res)
								res.keep_alive = req.keep_alive
								conn.keep_alive = req.keep_alive

								written, ok_ser := serialize_response(&res, conn.send_buf)
								if ok_ser {
									conn.send_len = written
									conn.send_pos = 0
									rem := conn.recv_len - consumed
									if rem > 0 {
										copy(conn.recv_buf[:rem], conn.recv_buf[consumed : conn.recv_len])
									}
									conn.recv_len = rem
									win_post_write(engine, conn, &engine.write_contexts[conn.id])
									continue
								}
							}
						}

						if !win_post_read(engine, conn, &engine.read_contexts[conn.id]) {
							win_release_connection(engine, conn)
						}
					} else {
						win_release_connection(engine, conn)
					}
				}

			case .None:
			}
		}
	}
}

start_windows_server :: proc(server: ^Server) {
	if !win_init_winsock() {
		fmt.eprintln("[odnetlib:win] Failed to initialize Winsock")
		return
	}

	engine := new(Windows_Engine)
	engine.server = server
	server.platform_data = engine

	engine.iocp = win.CreateIoCompletionPort(win.INVALID_HANDLE_VALUE, nil, 0, 0)
	if engine.iocp == nil {
		fmt.eprintln("[odnetlib:win] Failed to create IOCP")
		return
	}

	// Create listen socket
	listen_sock := win_create_overlapped_socket()
	if listen_sock == win.INVALID_SOCKET {
		fmt.eprintln("[odnetlib:win] Failed to create listen socket")
		return
	}
	engine.listen_socket = listen_sock

	if !win_set_socket_options(listen_sock) {
		win.closesocket(listen_sock)
		return
	}

	addr: win.sockaddr_in
	addr.sin_family = win.ADDRESS_FAMILY(win.AF_INET)
	addr.sin_port = u16be(server.config.port)
	addr.sin_addr.s_addr = 0 // INADDR_ANY

	if win.bind(listen_sock, cast(^win.SOCKADDR_STORAGE_LH)&addr, size_of(addr)) != 0 {
		fmt.eprintln("[odnetlib:win] Failed to bind to port", server.config.port)
		win.closesocket(listen_sock)
		return
	}

	if win.listen(listen_sock, win.c_int(server.config.backlog)) != 0 {
		fmt.eprintln("[odnetlib:win] Failed to listen on socket")
		win.closesocket(listen_sock)
		return
	}

	if win.CreateIoCompletionPort(win.HANDLE(listen_sock), engine.iocp, 0, 0) == nil {
		fmt.eprintln("[odnetlib:win] Failed to bind listen socket to IOCP")
		win.closesocket(listen_sock)
		return
	}

	// Initialize Connection Pool
	engine.pool = connection_pool_create(
		server.config.max_connections,
		server.config.recv_buffer_size,
		server.config.send_buffer_size,
		4096,
	)

	engine.free_slots = make([dynamic]int, 0, server.config.max_connections)
	for i := server.config.max_connections - 1; i >= 0; i -= 1 {
		append(&engine.free_slots, i)
	}

	engine.read_contexts = make([]Overlapped_Context, server.config.max_connections)
	engine.write_contexts = make([]Overlapped_Context, server.config.max_connections)

	num_workers := server.config.num_workers
	if num_workers <= 0 {
		sys_info: win.SYSTEM_INFO
		win.GetSystemInfo(&sys_info)
		num_workers = int(sys_info.dwNumberOfProcessors)
		if num_workers < 1 do num_workers = 1
	}

	fmt.printf("[odnetlib:win] Spawning %d IOCP worker threads on port %d\n", num_workers, server.config.port)

	for i in 0..<NUM_PREPOST_ACCEPTS {
		win_post_accept(engine, &engine.accept_contexts[i])
	}
	fmt.printf("[odnetlib:win] Pre-posted %d AcceptEx sockets in kernel queue\n", NUM_PREPOST_ACCEPTS)

	server.running = true
	engine.workers = make([dynamic]^thread.Thread, 0, num_workers)
	for i in 0..<num_workers {
		t := thread.create_and_start_with_data(engine, win_worker_loop)
		append(&engine.workers, t)
	}

	fmt.printf("[odnetlib:win] Server running at http://127.0.0.1:%d/\n", server.config.port)

	for t in engine.workers {
		thread.join(t)
	}
}

#+build linux
package odnetlib

import "core:fmt"
import "core:sync"
import "core:thread"
import "core:sys/linux"

MAX_EPOLL_EVENTS :: 64
LISTENER_TOKEN   :: u64(0xFFFF_FFFF_FFFF_FFFF)

Linux_Worker :: struct {
	id:        int,
	epfd:      linux.Fd,
	listen_fd: linux.Fd,
	engine:    ^Linux_Engine,
	running:   bool,
}

Linux_Engine :: struct {
	server:        ^Server,
	pool:          Connection_Pool,
	pool_mutex:    sync.Mutex,
	free_slots:    [dynamic]int,
	workers:       [dynamic]^thread.Thread,
	worker_states: [dynamic]Linux_Worker,
}

lin_set_socket_options :: proc(fd: linux.Fd) -> bool {
	one: i32 = 1
	if linux.setsockopt_tcp(fd, linux.SOL_TCP, .NODELAY, &one) != .NONE {
		return false
	}
	if linux.setsockopt_sock(fd, linux.SOL_SOCKET, .KEEPALIVE, &one) != .NONE {
		return false
	}
	return true
}

lin_create_reuseport_listener :: proc(port: int, backlog: int) -> (linux.Fd, bool) {
	fd, err := linux.socket(.INET, .STREAM, {.NONBLOCK, .CLOEXEC}, .TCP)
	if err != .NONE do return -1, false

	one: i32 = 1
	if linux.setsockopt_sock(fd, linux.SOL_SOCKET, .REUSEPORT, &one) != .NONE {
		linux.close(fd)
		return -1, false
	}
	if linux.setsockopt_sock(fd, linux.SOL_SOCKET, .REUSEADDR, &one) != .NONE {
		linux.close(fd)
		return -1, false
	}
	if linux.setsockopt_tcp(fd, linux.SOL_TCP, .NODELAY, &one) != .NONE {
		linux.close(fd)
		return -1, false
	}

	defer_accept_secs: i32 = 1
	_ = linux.setsockopt_tcp(fd, linux.SOL_TCP, .DEFER_ACCEPT, &defer_accept_secs)

	addr: linux.Sock_Addr_In
	addr.sin_family = linux.Address_Family(linux.Protocol_Family.INET)
	addr.sin_port = u16be(port)
	addr.sin_addr = [4]u8{0, 0, 0, 0}

	if linux.bind(fd, &addr) != .NONE {
		linux.close(fd)
		return -1, false
	}

	if linux.listen(fd, i32(backlog)) != .NONE {
		linux.close(fd)
		return -1, false
	}

	return fd, true
}

lin_create_epoll_instance :: proc() -> (linux.Fd, bool) {
	epfd, err := linux.epoll_create1({.FDCLOEXEC})
	if err != .NONE do return -1, false
	return epfd, true
}

lin_acquire_connection :: proc(engine: ^Linux_Engine) -> ^Connection {
	sync.lock(&engine.pool_mutex)
	defer sync.unlock(&engine.pool_mutex)
	if len(engine.free_slots) == 0 do return nil
	idx := pop(&engine.free_slots)
	conn := &engine.pool.connections[idx]
	conn.state = .Accepted
	connection_reset(conn)
	return conn
}

lin_release_connection :: proc(engine: ^Linux_Engine, conn: ^Connection) {
	if conn == nil do return
	if conn.socket != 0 {
		linux.close(linux.Fd(conn.socket))
		conn.socket = 0
	}
	conn.state = .Free
	stats_dec_connection(&engine.server.stats)
	sync.lock(&engine.pool_mutex)
	append(&engine.free_slots, conn.id)
	sync.unlock(&engine.pool_mutex)
}

lin_worker_reactor_proc :: proc(data: rawptr) {
	worker := cast(^Linux_Worker)data
	engine := worker.engine
	events: [MAX_EPOLL_EVENTS]linux.EPoll_Event

	for worker.running {
		nfds, err := linux.epoll_wait(worker.epfd, raw_data(&events), i32(len(events)), -1)
		if err != .NONE {
			if !worker.running do break
			continue
		}

		for i in 0..<int(nfds) {
			ev := &events[i]
			token := ev.data.u64

			if token == LISTENER_TOKEN {
				// Drain accept queue
				for {
					client_addr: linux.Sock_Addr_In
					client_fd, acc_err := linux.accept(worker.listen_fd, &client_addr, {.NONBLOCK, .CLOEXEC})
					if acc_err == .EAGAIN || acc_err == .EWOULDBLOCK do break
					if acc_err != .NONE do break

					lin_set_socket_options(client_fd)

					conn := lin_acquire_connection(engine)
					if conn == nil {
						linux.close(client_fd)
						continue
					}

					conn.socket = uintptr(client_fd)
					stats_inc_connection(&engine.server.stats)

					con_ev: linux.EPoll_Event
					con_ev.events = {.IN, .ET, .RDHUP}
					con_ev.data.u64 = u64(conn.id)
					if linux.epoll_ctl(worker.epfd, .ADD, client_fd, &con_ev) != .NONE {
						lin_release_connection(engine, conn)
					}
				}
				continue
			}

			conn_idx := int(token)
			if conn_idx < 0 || conn_idx >= len(engine.pool.connections) do continue
			conn := &engine.pool.connections[conn_idx]
			client_fd := linux.Fd(conn.socket)

			if .RDHUP in ev.events || .ERR in ev.events || .HUP in ev.events {
				linux.epoll_ctl(worker.epfd, .DEL, client_fd, nil)
				lin_release_connection(engine, conn)
				continue
			}

			if .IN in ev.events {
				disconnect := false
				for {
					rem := len(conn.recv_buf) - conn.recv_len
					if rem <= 0 do break

					n, r_err := linux.read(client_fd, conn.recv_buf[conn.recv_len:])
					if r_err == .EAGAIN || r_err == .EWOULDBLOCK do break
					if r_err != .NONE || n == 0 {
						disconnect = true
						break
					}
					conn.recv_len += n
					stats_add_bytes_recv(&engine.server.stats, n)
				}

				if disconnect {
					linux.epoll_ctl(worker.epfd, .DEL, client_fd, nil)
					lin_release_connection(engine, conn)
					continue
				}

				req: Request
				consumed, status := parse_request(conn.recv_buf[:conn.recv_len], &req)

				if status == .Complete {
					stats_inc_request(&engine.server.stats)

					res: Response
					router_dispatch(&engine.server.router, &req, &res)
					res.keep_alive = req.keep_alive
					conn.keep_alive = req.keep_alive

					written, ok_ser := serialize_response(&res, conn.send_buf)
					if !ok_ser {
						linux.epoll_ctl(worker.epfd, .DEL, client_fd, nil)
						lin_release_connection(engine, conn)
						continue
					}

					conn.send_len = written
					conn.send_pos = 0

					rem := conn.recv_len - consumed
					if rem > 0 {
						copy(conn.recv_buf[:rem], conn.recv_buf[consumed : conn.recv_len])
					}
					conn.recv_len = rem

					flushed := true
					for conn.send_pos < conn.send_len {
						wn, w_err := linux.write(client_fd, conn.send_buf[conn.send_pos : conn.send_len])
						if w_err == .EAGAIN || w_err == .EWOULDBLOCK {
							flushed = false
							mod_ev: linux.EPoll_Event
							mod_ev.events = {.IN, .OUT, .ET, .RDHUP}
							mod_ev.data.u64 = u64(conn.id)
							linux.epoll_ctl(worker.epfd, .MOD, client_fd, &mod_ev)
							break
						}
						if w_err != .NONE {
							linux.epoll_ctl(worker.epfd, .DEL, client_fd, nil)
							lin_release_connection(engine, conn)
							flushed = false
							break
						}
						conn.send_pos += wn
						stats_add_bytes_sent(&engine.server.stats, wn)
					}

					if flushed {
						if conn.keep_alive {
							connection_reset(conn)
						} else {
							linux.epoll_ctl(worker.epfd, .DEL, client_fd, nil)
							lin_release_connection(engine, conn)
						}
					}
				}
			}

			if .OUT in ev.events && conn.state != .Free {
				flushed := true
				for conn.send_pos < conn.send_len {
					wn, w_err := linux.write(client_fd, conn.send_buf[conn.send_pos : conn.send_len])
					if w_err == .EAGAIN || w_err == .EWOULDBLOCK {
						flushed = false
						break
					}
					if w_err != .NONE {
						linux.epoll_ctl(worker.epfd, .DEL, client_fd, nil)
						lin_release_connection(engine, conn)
						flushed = false
						break
					}
					conn.send_pos += wn
					stats_add_bytes_sent(&engine.server.stats, wn)
				}

				if flushed {
					mod_ev: linux.EPoll_Event
					mod_ev.events = {.IN, .ET, .RDHUP}
					mod_ev.data.u64 = u64(conn.id)
					linux.epoll_ctl(worker.epfd, .MOD, client_fd, &mod_ev)
					if conn.keep_alive {
						connection_reset(conn)
					} else {
						linux.epoll_ctl(worker.epfd, .DEL, client_fd, nil)
						lin_release_connection(engine, conn)
					}
				}
			}
		}
	}
}

start_linux_server :: proc(server: ^Server) {
	engine := new(Linux_Engine)
	engine.server = server
	server.platform_data = engine

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

	num_workers := server.config.num_workers
	if num_workers <= 0 do num_workers = 4

	fmt.printf("[odnetlib:linux] Spawning %d epoll multi-reactors with SO_REUSEPORT on port %d\n", num_workers, server.config.port)

	engine.workers = make([dynamic]^thread.Thread, 0, num_workers)
	engine.worker_states = make([dynamic]Linux_Worker, 0, num_workers)

	for i in 0..<num_workers {
		epfd, ep_ok := lin_create_epoll_instance()
		if !ep_ok {
			fmt.eprintln("[odnetlib:linux] Failed to create epoll instance for worker", i)
			continue
		}

		listen_fd, l_ok := lin_create_reuseport_listener(server.config.port, server.config.backlog)
		if !l_ok {
			fmt.eprintln("[odnetlib:linux] Failed to bind SO_REUSEPORT listener for worker", i)
			linux.close(epfd)
			continue
		}

		l_ev: linux.EPoll_Event
		l_ev.events = {.IN, .ET}
		l_ev.data.u64 = LISTENER_TOKEN
		if linux.epoll_ctl(epfd, .ADD, listen_fd, &l_ev) != .NONE {
			fmt.eprintln("[odnetlib:linux] Failed to register listener on epoll for worker", i)
			linux.close(listen_fd)
			linux.close(epfd)
			continue
		}

		worker := Linux_Worker{
			id        = i,
			epfd      = epfd,
			listen_fd = listen_fd,
			engine    = engine,
			running   = true,
		}
		append(&engine.worker_states, worker)
	}

	server.running = true
	for i in 0..<len(engine.worker_states) {
		t := thread.create_and_start_with_data(&engine.worker_states[i], lin_worker_reactor_proc)
		append(&engine.workers, t)
	}

	fmt.printf("[odnetlib:linux] Server listening at http://0.0.0.0:%d/\n", server.config.port)

	for t in engine.workers {
		thread.join(t)
	}
}

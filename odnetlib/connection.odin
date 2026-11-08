package odnetlib

Connection_State :: enum u8 {
	Free,
	Accepted,
	Reading,
	Processing,
	Writing,
	Closing,
}

// Connection represents an isolated client socket slot in the pre-allocated pool.
Connection :: struct {
	id:             int,
	state:          Connection_State,
	socket:         uintptr, // Native socket handle (SOCKET on Windows, Fd on Linux)
	
	// Pre-allocated receive buffer
	recv_buf:       []u8,
	recv_len:       int,
	
	// Pre-allocated send buffer
	send_buf:       []u8,
	send_len:       int,
	send_pos:       int,
	
	// Scratch memory arena for request parsing & handling
	arena:          Bump_Arena,
	scratch_buf:    []u8,
	
	keep_alive:     bool,
	request_count:  int,
	last_active_ns: i64,
}

connection_init :: proc(conn: ^Connection, id: int, recv_mem: []u8, send_mem: []u8, scratch_mem: []u8) {
	conn.id = id
	conn.state = .Free
	conn.socket = 0
	conn.recv_buf = recv_mem
	conn.recv_len = 0
	conn.send_buf = send_mem
	conn.send_len = 0
	conn.send_pos = 0
	conn.scratch_buf = scratch_mem
	bump_arena_init(&conn.arena, scratch_mem)
	conn.keep_alive = true
	conn.request_count = 0
	conn.last_active_ns = 0
}

connection_reset :: proc(conn: ^Connection) {
	conn.recv_len = 0
	conn.send_len = 0
	conn.send_pos = 0
	bump_arena_reset(&conn.arena)
}

// Pre-allocated connection pool
Connection_Pool :: struct {
	connections: []Connection,
	raw_memory:  []u8,
	capacity:    int,
}

connection_pool_create :: proc(capacity: int, recv_size: int, send_size: int, scratch_size: int) -> Connection_Pool {
	slot_size := recv_size + send_size + scratch_size
	total_mem := capacity * slot_size
	raw_buf := make([]u8, total_mem)
	conns := make([]Connection, capacity)

	offset := 0
	for i in 0..<capacity {
		recv_mem := raw_buf[offset : offset + recv_size]
		offset += recv_size
		send_mem := raw_buf[offset : offset + send_size]
		offset += send_size
		scratch_mem := raw_buf[offset : offset + scratch_size]
		offset += scratch_size

		connection_init(&conns[i], i, recv_mem, send_mem, scratch_mem)
	}

	return Connection_Pool{
		connections = conns,
		raw_memory  = raw_buf,
		capacity    = capacity,
	}
}

connection_pool_destroy :: proc(pool: ^Connection_Pool) {
	delete(pool.raw_memory)
	delete(pool.connections)
}

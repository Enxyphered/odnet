package odnetlib

// Server runtime configuration
Config :: struct {
	port:             int,
	host:             string,
	backlog:          int,
	num_workers:      int, // 0 = auto-detect logical CPU core count
	max_connections:  int,
	recv_buffer_size: int,
	send_buffer_size: int,
	keep_alive_secs:  int,
}

DEFAULT_CONFIG :: Config{
	port             = 8080,
	host             = "0.0.0.0",
	backlog          = 4096,
	num_workers      = 0,
	max_connections  = 16384,
	recv_buffer_size = 16384, // 16KB per connection
	send_buffer_size = 16384,
	keep_alive_secs  = 15,
}

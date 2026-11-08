package odnetlib

import "core:fmt"

Server :: struct {
	config:        Config,
	router:        Router,
	stats:         Server_Stats,
	platform_data: rawptr,
	running:       bool,
}

server_init :: proc(s: ^Server, cfg: Config = DEFAULT_CONFIG) {
	s.config = cfg
	router_init(&s.router)
	s.stats = {}
	s.platform_data = nil
	s.running = false
}

server_get :: proc(s: ^Server, pattern: string, handler: Handler_Proc) -> bool {
	return router_add(&s.router, .GET, pattern, handler)
}

server_head :: proc(s: ^Server, pattern: string, handler: Handler_Proc) -> bool {
	return router_add(&s.router, .HEAD, pattern, handler)
}

server_post :: proc(s: ^Server, pattern: string, handler: Handler_Proc) -> bool {
	return router_add(&s.router, .POST, pattern, handler)
}

server_put :: proc(s: ^Server, pattern: string, handler: Handler_Proc) -> bool {
	return router_add(&s.router, .PUT, pattern, handler)
}

server_delete :: proc(s: ^Server, pattern: string, handler: Handler_Proc) -> bool {
	return router_add(&s.router, .DELETE, pattern, handler)
}

server_options :: proc(s: ^Server, pattern: string, handler: Handler_Proc) -> bool {
	return router_add(&s.router, .OPTIONS, pattern, handler)
}

server_patch :: proc(s: ^Server, pattern: string, handler: Handler_Proc) -> bool {
	return router_add(&s.router, .PATCH, pattern, handler)
}

server_not_found :: proc(s: ^Server, handler: Handler_Proc) {
	s.router.not_found = handler
}

// Starts the server using the platform-optimized kernel engine (IOCP on Windows, epoll on Linux).
server_start :: proc(s: ^Server) {
	when ODIN_OS == .Windows {
		start_windows_server(s)
	} else when ODIN_OS == .Linux {
		start_linux_server(s)
	} else {
		fmt.eprintln("[odnetlib] Unsupported operating system")
	}
}

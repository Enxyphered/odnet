package main

import "core:fmt"
import "core:os"
import "core:strconv"

import http "../odnetlib"

// -----------------------------------------------------------------------------
// Route Handlers (Managed by the Client Application)
// -----------------------------------------------------------------------------

handle_index :: proc(req: ^http.Request, res: ^http.Response) {
	http.response_set_body_string(
		res,
		"====================================================\n" +
		"  Welcome to odnetclient powered by odnetlib!       \n" +
		"====================================================\n" +
		"Endpoints available:\n" +
		"  GET  /plaintext\n" +
		"  GET  /json\n" +
		"  GET  /books/{shortId}/delete   (Dynamic route)\n" +
		"  GET  /users/{id}/profile       (Dynamic route)\n" +
		"  POST /echo\n",
		"text/plain; charset=utf-8",
	)
}

handle_plaintext :: proc(req: ^http.Request, res: ^http.Response) {
	// Standard TechEmpower Plaintext Benchmark specification
	http.response_set_body_string(res, "Hello, World!", "text/plain")
}

handle_json :: proc(req: ^http.Request, res: ^http.Response) {
	// Standard TechEmpower JSON Benchmark specification
	http.response_set_json(res, "{\"message\":\"Hello, World!\",\"framework\":\"odnetlib\"}")
}

handle_delete_book :: proc(req: ^http.Request, res: ^http.Response) {
	// Zero-allocation dynamic route parameter extraction!
	// shortId is a direct slice into req.path—no strings are allocated on the heap.
	short_id, ok := http.get_param(req, "shortId")
	if !ok {
		res.status = .Bad_Request
		http.response_set_body_string(res, "Missing book shortId\n")
		return
	}

	// Use connection scratch arena to format dynamic response without heap allocation
	resp_text := fmt.tprintf("Book with ID '%s' has been queued for deletion.\n", short_id)
	http.response_set_body_string(res, resp_text)
	res.status = .OK
}

handle_user_profile :: proc(req: ^http.Request, res: ^http.Response) {
	user_id, ok := http.get_param(req, "id")
	if !ok {
		res.status = .Bad_Request
		http.response_set_body_string(res, "Missing user id\n")
		return
	}

	json_resp := fmt.tprintf("{{\"user_id\":\"%s\",\"status\":\"active\"}}", user_id)
	http.response_set_json(res, json_resp)
}

handle_echo :: proc(req: ^http.Request, res: ^http.Response) {
	http.response_set_body(res, req.body, "application/octet-stream")
}

handle_custom_404 :: proc(req: ^http.Request, res: ^http.Response) {
	res.status = .Not_Found
	resp_msg := fmt.tprintf("404 Not Found: Path '%s' does not match any registered route.\n", req.path)
	http.response_set_body_string(res, resp_msg)
}

// -----------------------------------------------------------------------------
// CLI Argument Parsing & Entry Point
// -----------------------------------------------------------------------------

parse_config :: proc() -> http.Config {
	cfg := http.DEFAULT_CONFIG

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if (arg == "--port" || arg == "-p") && i + 1 < len(args) {
			i += 1
			if p, ok := strconv.parse_int(args[i]); ok {
				cfg.port = p
			}
		} else if (arg == "--workers" || arg == "-w") && i + 1 < len(args) {
			i += 1
			if w, ok := strconv.parse_int(args[i]); ok {
				cfg.num_workers = w
			}
		}
	}
	return cfg
}

main :: proc() {
	cfg := parse_config()

	server: http.Server
	http.server_init(&server, cfg)

	// 1. Static Routes (Handled via instant Tier 1 string comparison)
	http.server_get(&server, "/", handle_index)
	http.server_get(&server, "/plaintext", handle_plaintext)
	http.server_get(&server, "/json", handle_json)

	// 2. Dynamic Routes (Handled via zero-allocation Tier 2 segment extraction)
	http.server_get(&server, "/books/{shortId}/delete", handle_delete_book)
	http.server_get(&server, "/users/{id}/profile", handle_user_profile)
	http.server_post(&server, "/echo", handle_echo)

	// 3. Custom 404 Handler
	http.server_not_found(&server, handle_custom_404)

	fmt.println("================================================================================")
	fmt.println("             odnetclient: Custom Client Application using odnetlib              ")
	fmt.println("================================================================================")
	when ODIN_OS == .Windows {
		fmt.println("  Active Engine    : Windows IOCP (I/O Completion Ports + AcceptEx)")
	} else when ODIN_OS == .Linux {
		fmt.println("  Active Engine    : Linux epoll (Edge-Triggered EPOLLET + SO_REUSEPORT)")
	}
	fmt.printf("  Port             : %d\n", cfg.port)
	fmt.println("  Registered Routes:")
	fmt.println("    GET  /                         (Static)")
	fmt.println("    GET  /plaintext                (Static)")
	fmt.println("    GET  /json                     (Static)")
	fmt.println("    GET  /books/{shortId}/delete   (Dynamic zero-copy param)")
	fmt.println("    GET  /users/{id}/profile       (Dynamic zero-copy param)")
	fmt.println("    POST /echo                     (Static payload echo)")
	fmt.println("================================================================================\n")

	// Start server (blocking call)
	http.server_start(&server)
}

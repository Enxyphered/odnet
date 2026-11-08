package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import http "../odnetlib"
import "books"

// -----------------------------------------------------------------------------
// Route Handlers
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
		"  GET  /home\n" +
		"  GET  /books\n" +
		"  GET  /books/{shortId}/delete\n" +
		"  GET  /users/{id}/profile\n" +
		"  POST /echo\n",
		"text/plain; charset=utf-8",
	)
}

handle_plaintext :: proc(req: ^http.Request, res: ^http.Response) {
	http.response_set_body_string(res, "Hello, World!", "text/plain")
}

handle_json :: proc(req: ^http.Request, res: ^http.Response) {
	http.response_set_json(res, "{\"message\":\"Hello, World!\",\"framework\":\"odnetlib\"}")
}

handle_home :: proc(req: ^http.Request, res: ^http.Response) {
	b := strings.builder_make(context.temp_allocator)
	render_home(&b, username = "Shaamil", name = "Shaamil", badge_id = "007")
	http.response_set_html(res, strings.to_string(b))
}

handle_books :: proc(req: ^http.Request, res: ^http.Response) {
	b := strings.builder_make(context.temp_allocator)
	books.render_books(&b, books = books.SAMPLE_BOOKS, title = "Curated Computer Science Library")
	http.response_set_html(res, strings.to_string(b))
}

handle_update_greeting :: proc(req: ^http.Request, res: ^http.Response) {
	title, _ := http.get_form_value(req, "title")
	name, _ := http.get_form_value(req, "name")
	if len(title) == 0 do title = "Mr."
	if len(name) == 0 do name = "Shaamil"

	b := strings.builder_make(context.temp_allocator)
	render_greet(&b, title = title, name = name, badge_id = "007")
	http.response_set_html(res, strings.to_string(b))
}

handle_delete_book :: proc(req: ^http.Request, res: ^http.Response) {
	short_id, ok := http.get_param(req, "shortId")
	if !ok {
		res.status = .Bad_Request
		http.response_set_body_string(res, "Missing book shortId\n")
		return
	}

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

	// 1. Static Routes
	http.server_get(&server, "/", handle_index)
	http.server_get(&server, "/plaintext", handle_plaintext)
	http.server_get(&server, "/json", handle_json)
	http.server_get(&server, "/home", handle_home)
	http.server_get(&server, "/books", handle_books)
	http.server_post(&server, "/api/greeting", handle_update_greeting)
	http.server_get(&server, "/api/greeting", handle_update_greeting)

	// 2. Static File Serving
	http.server_static(&server, "/static", "odnetclient/static", http.Static_Options{
		max_age_seconds = 0,
		immutable = false,
		index_file = "index.html",
	})

	// 3. Dynamic Routes
	http.server_get(&server, "/books/{shortId}/delete", handle_delete_book)
	http.server_get(&server, "/users/{id}/profile", handle_user_profile)
	http.server_post(&server, "/echo", handle_echo)

	// 4. Custom 404 Handler
	http.server_not_found(&server, handle_custom_404)

	fmt.println("================================================================================")
	fmt.println("             odnetclient: Custom Client Application using odnetlib              ")
	fmt.println("================================================================================")
	when ODIN_OS == .Windows {
		fmt.println("  Active Engine    : Windows IOCP")
	} else when ODIN_OS == .Linux {
		fmt.println("  Active Engine    : Linux epoll")
	}
	fmt.printf("  Port             : %d\n", cfg.port)
	fmt.println("  Registered Routes:")
	fmt.println("    GET  /")
	fmt.println("    GET  /plaintext")
	fmt.println("    GET  /json")
	fmt.println("    GET  /home")
	fmt.println("    GET  /books")
	fmt.println("    GET  /static/*")
	fmt.println("    GET  /books/{shortId}/delete")
	fmt.println("    GET  /users/{id}/profile")
	fmt.println("    POST /echo")
	fmt.println("================================================================================\n")

	// Start server (blocking call)
	http.server_start(&server)
}

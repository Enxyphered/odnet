package odnetlib

import "core:testing"

dummy_handler :: proc(req: ^Request, res: ^Response) {}

@(test)
test_duplicate_static_routes :: proc(t: ^testing.T) {
	r: Router
	router_init(&r)

	router_add(&r, .GET, "/plaintext", dummy_handler)

	conflicting, has_conflict := router_check_collision(&r, .GET, "/plaintext")
	testing.expect(t, has_conflict, "Expected duplicate static route to be detected")
	testing.expect_value(t, conflicting, "/plaintext")
}

@(test)
test_duplicate_dynamic_routes :: proc(t: ^testing.T) {
	r: Router
	router_init(&r)

	router_add(&r, .GET, "/books/{shortId}/delete", dummy_handler)

	conflicting, has_conflict := router_check_collision(&r, .GET, "/books/{bookId}/delete")
	testing.expect(t, has_conflict, "Expected dynamic route collision between {shortId} and {bookId}")
	testing.expect_value(t, conflicting, "/books/{shortId}/delete")
}

@(test)
test_different_methods_do_not_collide :: proc(t: ^testing.T) {
	r: Router
	router_init(&r)

	router_add(&r, .GET, "/books/{id}", dummy_handler)

	_, has_conflict := router_check_collision(&r, .DELETE, "/books/{id}")
	testing.expect(t, !has_conflict, "Expected GET and DELETE routes on same path not to collide")
}

@(test)
test_static_override_does_not_collide :: proc(t: ^testing.T) {
	r: Router
	router_init(&r)

	router_add(&r, .GET, "/books/{shortId}/delete", dummy_handler)

	_, has_conflict := router_check_collision(&r, .GET, "/books/admin/delete")
	testing.expect(t, !has_conflict, "Expected specific static override not to collide with generic dynamic pattern")
}

handle_root :: proc(req: ^Request, res: ^Response) {
	response_set_body_string(res, "root")
}

handle_home :: proc(req: ^Request, res: ^Response) {
	response_set_body_string(res, "home")
}

handle_catchall :: proc(req: ^Request, res: ^Response) {
	response_set_body_string(res, "catchall")
}

@(test)
test_wildcard_fallback_behavior :: proc(t: ^testing.T) {
	r: Router
	router_init(&r)

	// User defines / and /home and then /*
	router_add(&r, .GET, "/", handle_root)
	router_add(&r, .GET, "/home", handle_home)
	router_add(&r, .GET, "/*", handle_catchall)

	// 1. Test / -> should hit handle_root
	{
		req := Request{method = .GET, path = "/"}
		res: Response
		router_dispatch(&r, &req, &res)
		testing.expect_value(t, string(res.body), "root")
	}

	// 2. Test /home -> should hit handle_home
	{
		req := Request{method = .GET, path = "/home"}
		res: Response
		router_dispatch(&r, &req, &res)
		testing.expect_value(t, string(res.body), "home")
	}

	// 3. Test /other (e.g. /about, /books/123) -> should hit handle_catchall
	{
		req := Request{method = .GET, path = "/about"}
		res: Response
		router_dispatch(&r, &req, &res)
		testing.expect_value(t, string(res.body), "catchall")
	}

	{
		req := Request{method = .GET, path = "/dashboard/settings"}
		res: Response
		router_dispatch(&r, &req, &res)
		testing.expect_value(t, string(res.body), "catchall")
	}
}

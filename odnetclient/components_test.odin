package main

import "core:strings"
import "core:testing"
import http "../odnetlib"

@(test)
test_render_button :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	render_button(&b, label = "Save Changes", variant = "success")
	res := strings.to_string(b)

	testing.expect(t, strings.contains(res, "btn-success"), "Button should have class btn-success")
	testing.expect(t, strings.contains(res, "Save Changes"), "Button should contain label")
}

@(test)
test_render_card_with_slot :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	render_card(&b, title = "My Dashboard", slot = proc(b: ^strings.Builder, user_data: rawptr) {
		strings.write_string(b, "<p>Injected into card slot</p>")
	})
	res := strings.to_string(b)

	testing.expect(t, strings.contains(res, "My Dashboard"), "Card should have title")
	testing.expect(t, strings.contains(res, "<p>Injected into card slot</p>"), "Card should have slot content")
}

@(test)
test_render_greet :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	render_greet(&b, title = "Dr.", name = "Watson", badge_id = "42")
	res := strings.to_string(b)

	testing.expect(t, strings.contains(res, "id=\"greeting-container\""), "Greeting should have greeting-container id for HTMX")
	testing.expect(t, strings.contains(res, "Hello, Dr. Watson!"), "Greeting should include title and name")
	testing.expect(t, strings.contains(res, "Employee ID: #42"), "Greeting should include badge ID")
}

@(test)
test_render_input_shadcn :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	render_input(&b, type = "text", placeholder = "Search...", value = "test value")
	res := strings.to_string(b)

	testing.expect(t, strings.contains(res, "border-input"), "Input should contain shadcn border-input class")
	testing.expect(t, strings.contains(res, "placeholder=\"Search...\""), "Input should have placeholder")
	testing.expect(t, strings.contains(res, "value=\"test value\""), "Input should have value")
}

@(test)
test_render_home_full_tree :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	render_home(&b, username = "Shaamil", name = "Shaamil", badge_id = "007")
	res := strings.to_string(b)

	testing.expect(t, strings.contains(res, "<!DOCTYPE html>"), "Home page should have DOCTYPE")
	testing.expect(t, strings.contains(res, "/static/css/Styles.css"), "Home page should reference Styles.css")
	testing.expect(t, strings.contains(res, "htmx.org"), "Home page should include HTMX library")
	testing.expect(t, strings.contains(res, "hx-post=\"/api/greeting\""), "Home page should include HTMX form post")
	testing.expect(t, strings.contains(res, "hx-target=\"#greeting-container\""), "Home page should target greeting-container")
	testing.expect(t, strings.contains(res, "Hello, Mr. Shaamil!"), "Home page should render child Greet")
	testing.expect(t, strings.contains(res, "Account Overview"), "Home page should render Card title")
	testing.expect(t, strings.contains(res, "Welcome to your control panel, Shaamil!"), "Card slot should contain username")
	testing.expect(t, strings.contains(res, "Update Greeting"), "Card slot should contain update button")
}

@(test)
test_htmx_update_greeting_endpoint :: proc(t: ^testing.T) {
	req := http.Request{
		method = .POST,
		path = "/api/greeting",
		body = transmute([]u8)string("title=Lady&name=Ada+Lovelace"),
	}
	res: http.Response
	handle_update_greeting(&req, &res)

	testing.expect_value(t, res.status, http.Status_Code.OK)
	testing.expect_value(t, res.content_type, "text/html; charset=utf-8")
	body_str := string(res.body)
	testing.expect(t, strings.contains(body_str, "Hello, Lady Ada Lovelace!"), "HTMX response should contain updated title and name")
	testing.expect(t, strings.contains(body_str, "id=\"greeting-container\""), "HTMX response should retain container id for outerHTML swap")
}

package main

import "core:strings"
import "core:testing"
import http "../odnetlib"
import "books"

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


@(test)
test_render_book_card_conditionals_and_switch :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	book1 := books.Book{
		title = "The Pragmatic Programmer",
		author = "Andy Hunt & Dave Thomas",
		price = 49.99,
		is_bestseller = true,
		status = "in_stock",
	}

	books.render_book_card(&b, book = book1, show_price = true)
	res1 := strings.to_string(b)

	testing.expect(t, strings.contains(res1, "The Pragmatic Programmer"), "Should contain book title")
	testing.expect(t, strings.contains(res1, "Andy Hunt & Dave Thomas"), "Should contain author")
	testing.expect(t, strings.contains(res1, "Bestseller"), "Should display Bestseller badge")
	testing.expect(t, strings.contains(res1, "In Stock"), "Should display In Stock status")
	testing.expect(t, strings.contains(res1, "$49.99"), "Should display price")

	// Test non-bestseller, out_of_stock, hide price
	strings.builder_reset(&b)
	book2 := books.Book{
		title = "Design Patterns",
		author = "Gang of Four",
		price = 54.95,
		is_bestseller = false,
		status = "out_of_stock",
	}

	books.render_book_card(&b, book = book2, show_price = false)
	res2 := strings.to_string(b)

	testing.expect(t, strings.contains(res2, "Design Patterns"), "Should contain book title")
	testing.expect(t, !strings.contains(res2, "Bestseller"), "Should NOT display Bestseller badge")
	testing.expect(t, strings.contains(res2, "Out of Stock"), "Should display Out of Stock status")
	testing.expect(t, !strings.contains(res2, "$54.95"), "Should NOT display price when show_price is false")
}

@(test)
test_render_book_catalog_loops_and_conditionals :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	// 1. Test empty catalog
	books.render_book_catalog(&b, books = nil, title = "Empty Shelf")
	empty_res := strings.to_string(b)

	testing.expect(t, strings.contains(empty_res, "Empty Shelf"), "Should contain catalog title")
	testing.expect(t, strings.contains(empty_res, "0 titles"), "Should show 0 titles")
	testing.expect(t, strings.contains(empty_res, "No books currently available"), "Should render empty state message")

	// 2. Test catalog with multiple books
	strings.builder_reset(&b)
	book_list := []books.Book{
		{title = "Odin in Action", author = "Ginger Bill", price = 39.99, is_bestseller = true, status = "in_stock"},
		{title = "Systems Programming", author = "Karl", price = 29.99, is_bestseller = false, status = "backorder"},
	}

	books.render_book_catalog(&b, books = book_list, title = "Tech Books")
	cat_res := strings.to_string(b)

	testing.expect(t, strings.contains(cat_res, "Tech Books"), "Should contain custom title")
	testing.expect(t, strings.contains(cat_res, "2 titles"), "Should show 2 titles")
	testing.expect(t, strings.contains(cat_res, "#1"), "Should render index 1")
	testing.expect(t, strings.contains(cat_res, "Odin in Action"), "Should render book 1")
	testing.expect(t, strings.contains(cat_res, "#2"), "Should render index 2")
	testing.expect(t, strings.contains(cat_res, "Systems Programming"), "Should render book 2")
	testing.expect(t, strings.contains(cat_res, "Backorder"), "Should render switch default status")
	testing.expect_value(t, strings.count(cat_res, "<span class=\"star\">★</span>"), 3)
}


@(test)
test_books_endpoint_integration :: proc(t: ^testing.T) {
	req := http.Request{
		method = .GET,
		path = "/books",
	}
	res: http.Response
	handle_books(&req, &res)

	testing.expect_value(t, res.status, http.Status_Code.OK)
	body_str := string(res.body)
	testing.expect(t, strings.contains(body_str, "Curated Computer Science Library"), "Should have catalog title")
	testing.expect(t, strings.contains(body_str, "6 titles"), "Should show 6 titles")
	testing.expect(t, strings.contains(body_str, "The Pragmatic Programmer"), "Should render Pragmatic Programmer")
	testing.expect(t, strings.contains(body_str, "Designing Data-Intensive Applications"), "Should render DDIA")
	testing.expect(t, strings.contains(body_str, "Crafting Interpreters"), "Should render Crafting Interpreters")
	testing.expect(t, strings.contains(body_str, "The Odin Programming Language Manual"), "Should render Odin manual")
	testing.expect(t, strings.contains(body_str, "Bestseller"), "Should render Bestseller badge")
	testing.expect(t, strings.contains(body_str, "In Stock"), "Should render In Stock")
	testing.expect(t, strings.contains(body_str, "Backorder"), "Should render Backorder")
	testing.expect(t, strings.contains(body_str, "Out of Stock"), "Should render Out of Stock")
}

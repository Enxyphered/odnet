package main

import "core:strings"
import "core:testing"

@(test)
test_to_snake_case :: proc(t: ^testing.T) {
	s1 := to_snake_case("Button")
	defer delete(s1)
	testing.expect_value(t, s1, "button")

	s2 := to_snake_case("UserProfile")
	defer delete(s2)
	testing.expect_value(t, s2, "user_profile")

	s3 := to_snake_case("card")
	defer delete(s3)
	testing.expect_value(t, s3, "card")
}

@(test)
test_escape_string_literal :: proc(t: ^testing.T) {
	s := escape_string_literal("Hello \"World\"\n\r\t\\")
	defer delete(s)
	testing.expect_value(t, s, "Hello \\\"World\\\"\\n\\r\\t\\\\")
}

@(test)
test_parse_and_collect :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "<div class=\"test\"><h1>{title}</h1>{slot}</div>"
	pos := 0
	nodes := parse_nodes(template, &pos)

	testing.expect(t, has_slot_node(nodes[:]), "Expected slot to be present")

	vars := make([dynamic]string)
	collect_vars(nodes[:], &vars)

	testing.expect_value(t, len(vars), 1)
	testing.expect_value(t, vars[0], "title")
}

@(test)
test_component_call_parsing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "@Greet(title: \"Mr.\", name: name) @Card(title: \"Test\") { <p>{user}</p> }"
	pos := 0
	nodes := parse_nodes(template, &pos)

	vars := make([dynamic]string)
	collect_vars(nodes[:], &vars)

	testing.expect_value(t, len(vars), 2)
	has_name := false
	has_user := false
	for v in vars {
		if v == "name" do has_name = true
		if v == "user" do has_user = true
	}
	testing.expect(t, has_name, "Expected 'name' variable")
	testing.expect(t, has_user, "Expected 'user' variable")
}

@(test)
test_escaped_braces :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// Test {{ and }} as well as \{ and \}
	template := "Inline {{escaped}} and \\{bracket\\} plus {real_var}"
	pos := 0
	nodes := parse_nodes(template, &pos)

	vars := make([dynamic]string)
	collect_vars(nodes[:], &vars)

	// Only {real_var} should be recognized as a variable!
	testing.expect_value(t, len(vars), 1)
	testing.expect_value(t, vars[0], "real_var")

	// First node should be Text containing "Inline {escaped} and {bracket} plus "
	testing.expect_value(t, nodes[0].kind, Node_Kind.Text)
	testing.expect_value(t, nodes[0].text, "Inline {escaped} and {bracket} plus ")
}

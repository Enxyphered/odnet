package main

import "core:slice"
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

@(test)
test_named_slots_parsing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "<header>{slot:header}</header><main>{slot}</main><footer>{slot:footer}</footer>"
	pos := 0
	nodes := parse_nodes(template, &pos)

	testing.expect(t, has_slot_node(nodes[:]), "Expected slot to be present")

	slot_names := make([dynamic]string)
	collect_slot_names(nodes[:], &slot_names)

	testing.expect_value(t, len(slot_names), 3)
	testing.expect(t, slice.contains(slot_names[:], "header"), "Expected 'header' slot")
	testing.expect(t, slice.contains(slot_names[:], ""), "Expected default slot")
	testing.expect(t, slice.contains(slot_names[:], "footer"), "Expected 'footer' slot")
}

@(test)
test_polymorphic_slot_fallback :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "<h3>{slot:title ?? title}</h3><span>{slot:badge || \"New\"}</span><p>{slot ?? default_body}</p>"
	pos := 0
	nodes := parse_nodes(template, &pos)

	slot_names := make([dynamic]string)
	collect_slot_names(nodes[:], &slot_names)

	testing.expect_value(t, len(slot_names), 3)
	testing.expect(t, slice.contains(slot_names[:], "title"), "Expected 'title' slot")
	testing.expect(t, slice.contains(slot_names[:], "badge"), "Expected 'badge' slot")
	testing.expect(t, slice.contains(slot_names[:], ""), "Expected default slot")

	vars := make([dynamic]string)
	collect_vars(nodes[:], &vars)

	// Should collect 'title' and 'default_body', while "New" is a string literal
	testing.expect_value(t, len(vars), 2)
	testing.expect(t, slice.contains(vars[:], "title"), "Expected 'title' fallback variable")
	testing.expect(t, slice.contains(vars[:], "default_body"), "Expected 'default_body' fallback variable")
}

@(test)
test_tag_style_named_slots_call :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "<Card title=\"Hello\"><slot:actions><button>OK</button></slot:actions><p>Body {user}</p></Card>"
	pos := 0
	nodes := parse_nodes(template, &pos)

	testing.expect_value(t, len(nodes), 1)
	testing.expect_value(t, nodes[0].kind, Node_Kind.Component_Call)
	testing.expect_value(t, nodes[0].component_name, "Card")

	vars := make([dynamic]string)
	collect_vars(nodes[:], &vars)
	testing.expect(t, slice.contains(vars[:], "user"), "Expected 'user' variable inside default slot")

	groups := group_slots(nodes[0].children[:])
	testing.expect_value(t, len(groups), 2)

	has_actions := false
	has_default := false
	for g in groups {
		if g.name == "actions" do has_actions = true
		if g.name == "" do has_default = true
	}
	testing.expect(t, has_actions, "Expected 'actions' slot group")
	testing.expect(t, has_default, "Expected default slot group")
}

@(test)
test_at_style_named_slots_call :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "@Card(title: \"Hello\") { @slot(header) { <h3>Title</h3> } <p>Body {user}</p> }"
	pos := 0
	nodes := parse_nodes(template, &pos)

	testing.expect_value(t, len(nodes), 1)
	testing.expect_value(t, nodes[0].kind, Node_Kind.Component_Call)
	testing.expect_value(t, nodes[0].component_name, "Card")

	vars := make([dynamic]string)
	collect_vars(nodes[:], &vars)
	testing.expect(t, slice.contains(vars[:], "user"), "Expected 'user' variable")

	groups := group_slots(nodes[0].children[:])
	testing.expect_value(t, len(groups), 2)

	has_header := false
	has_default := false
	for g in groups {
		if g.name == "header" do has_header = true
		if g.name == "" do has_default = true
	}
	testing.expect(t, has_header, "Expected 'header' slot group")
	testing.expect(t, has_default, "Expected default slot group")
}

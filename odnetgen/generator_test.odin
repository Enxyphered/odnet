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


@(test)
test_parse_import_directive :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "@import \"core:time\"\n@import models \"../models\"\n<import alias=\"http\" path=\"../odnetlib\" />\n<h1>Title</h1>"
	pos := 0
	imports := make([dynamic]Import_Decl)
	props := make([dynamic]Prop_Decl)
	parse_imports_and_props(template, &pos, &imports, &props, "test.odhtml")

	testing.expect_value(t, len(imports), 3)
	testing.expect_value(t, imports[0].path, "core:time")
	testing.expect_value(t, imports[1].alias, "models")
	testing.expect_value(t, imports[1].path, "../models")
	testing.expect_value(t, imports[2].alias, "http")
	testing.expect_value(t, imports[2].path, "../odnetlib")
}

@(test)
test_parse_props_directive :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "@props(book: Book, books: []Book = nil, is_admin: bool = false, count: int = 0)\n@param theme: string = \"dark\"\n<props>user: User</props>\n<div>Content</div>"
	pos := 0
	imports := make([dynamic]Import_Decl)
	props := make([dynamic]Prop_Decl)
	parse_imports_and_props(template, &pos, &imports, &props, "test.odhtml")

	testing.expect_value(t, len(props), 6)
	testing.expect_value(t, props[0].name, "book")
	testing.expect_value(t, props[0].type_name, "Book")
	testing.expect_value(t, props[0].default_value, "")

	testing.expect_value(t, props[1].name, "books")
	testing.expect_value(t, props[1].type_name, "[]Book")
	testing.expect_value(t, props[1].default_value, "nil")

	testing.expect_value(t, props[2].name, "is_admin")
	testing.expect_value(t, props[2].type_name, "bool")
	testing.expect_value(t, props[2].default_value, "false")

	testing.expect_value(t, props[3].name, "count")
	testing.expect_value(t, props[3].type_name, "int")
	testing.expect_value(t, props[3].default_value, "0")

	testing.expect_value(t, props[4].name, "theme")
	testing.expect_value(t, props[4].type_name, "string")
	testing.expect_value(t, props[4].default_value, "\"dark\"")

	testing.expect_value(t, props[5].name, "user")
	testing.expect_value(t, props[5].type_name, "User")
}

@(test)
test_parse_if_blocks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "@if (is_admin) { <span class=\"admin\">Admin</span> } @else if (role == \"mod\") { <span>Mod</span> } @else { <span>User</span> }"
	pos := 0
	nodes := parse_nodes(template, &pos)

	testing.expect_value(t, len(nodes), 1)
	testing.expect_value(t, nodes[0].kind, Node_Kind.If)
	testing.expect_value(t, len(nodes[0].if_branches), 3)

	testing.expect_value(t, nodes[0].if_branches[0].condition, "is_admin")
	testing.expect_value(t, nodes[0].if_branches[1].condition, "role == \"mod\"")
	testing.expect_value(t, nodes[0].if_branches[2].condition, "")

	vars := make([dynamic]string)
	collect_vars(nodes[:], &vars)
	testing.expect_value(t, len(vars), 2)
	testing.expect(t, slice.contains(vars[:], "is_admin"), "Expected 'is_admin' variable")
	testing.expect(t, slice.contains(vars[:], "role"), "Expected 'role' variable")
}

@(test)
test_parse_switch_case :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "@switch (status) { @case (\"active\") { <span>Active</span> } @case (\"pending\", \"review\") { <span>Wait</span> } @default { <span>Other</span> } }"
	pos := 0
	nodes := parse_nodes(template, &pos)

	testing.expect_value(t, len(nodes), 1)
	testing.expect_value(t, nodes[0].kind, Node_Kind.Switch)
	testing.expect_value(t, nodes[0].switch_expr, "status")
	testing.expect_value(t, len(nodes[0].switch_cases), 3)

	testing.expect_value(t, len(nodes[0].switch_cases[0].values), 1)
	testing.expect_value(t, nodes[0].switch_cases[0].values[0], "\"active\"")

	testing.expect_value(t, len(nodes[0].switch_cases[1].values), 2)
	testing.expect_value(t, nodes[0].switch_cases[1].values[0], "\"pending\"")
	testing.expect_value(t, nodes[0].switch_cases[1].values[1], "\"review\"")

	testing.expect_value(t, len(nodes[0].switch_cases[2].values), 0) // default

	vars := make([dynamic]string)
	collect_vars(nodes[:], &vars)
	testing.expect_value(t, len(vars), 1)
	testing.expect_value(t, vars[0], "status")
}

@(test)
test_parse_loops_and_scoping :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "@foreach item, idx in items { <li>#{idx}: {item.title}</li> } @for i in 0..<count { <span>{i}</span> }"
	pos := 0
	nodes := parse_nodes(template, &pos)

	testing.expect_value(t, len(nodes), 3) // For, Text(" "), For
	testing.expect_value(t, nodes[0].kind, Node_Kind.For)
	testing.expect_value(t, nodes[0].loop_var, "item, idx")
	testing.expect_value(t, nodes[0].loop_in, "items")

	testing.expect_value(t, nodes[2].kind, Node_Kind.For)
	testing.expect_value(t, nodes[2].loop_var, "i")
	testing.expect_value(t, nodes[2].loop_in, "0..<count")

	vars := make([dynamic]string)
	collect_vars(nodes[:], &vars)

	// 'item', 'idx', and 'i' are loop variables and MUST NOT be collected!
	// Only 'items' and 'count' should be collected.
	testing.expect_value(t, len(vars), 2)
	testing.expect(t, slice.contains(vars[:], "items"), "Expected 'items' variable")
	testing.expect(t, slice.contains(vars[:], "count"), "Expected 'count' variable")
	testing.expect(t, !slice.contains(vars[:], "item"), "Loop var 'item' must not leak")
	testing.expect(t, !slice.contains(vars[:], "idx"), "Loop var 'idx' must not leak")
	testing.expect(t, !slice.contains(vars[:], "i"), "Loop var 'i' must not leak")
}

@(test)
test_tag_style_control_flow :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	template := "<if condition=\"is_logged\"><span>Welcome</span></if><switch expr=\"mode\"><case value=\"'dark'\">Dark</case><default>Light</default></switch><foreach book in books><h4>{book.name}</h4></foreach>"
	pos := 0
	nodes := parse_nodes(template, &pos)

	testing.expect_value(t, len(nodes), 3)
	testing.expect_value(t, nodes[0].kind, Node_Kind.If)
	testing.expect_value(t, nodes[1].kind, Node_Kind.Switch)
	testing.expect_value(t, nodes[2].kind, Node_Kind.For)

	vars := make([dynamic]string)
	collect_vars(nodes[:], &vars)

	// 'book' is loop-local so it must not be in vars; 'books', 'is_logged', 'mode' must be present
	testing.expect_value(t, len(vars), 3)
	testing.expect(t, slice.contains(vars[:], "is_logged"), "Expected 'is_logged'")
	testing.expect(t, slice.contains(vars[:], "mode"), "Expected 'mode'")
	testing.expect(t, slice.contains(vars[:], "books"), "Expected 'books'")
	testing.expect(t, !slice.contains(vars[:], "book"), "Loop var 'book' must not leak")
}

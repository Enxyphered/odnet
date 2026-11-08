package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Node_Kind :: enum {
	Text,
	Var,
	Slot,
	Component_Call,
}

Prop :: struct {
	name:       string,
	value:      string,
	is_literal: bool,
}

Node :: struct {
	kind:           Node_Kind,
	text:           string,
	component_name: string,
	props:          [dynamic]Prop,
	has_slot_block: bool,
	children:       [dynamic]Node,
}

Component :: struct {
	name:      string, // lowercase snake_case
	raw_name:  string,
	filename:  string,
	nodes:     [dynamic]Node,
	has_slot:  bool,
	all_vars:  [dynamic]string,
}

is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

is_alphanumeric :: proc(c: u8) -> bool {
	return is_alpha(c) || is_digit(c)
}

skip_whitespace :: proc(src: string, pos: ^int) {
	for pos^ < len(src) {
		c := src[pos^]
		if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
			pos^ += 1
		} else {
			break
		}
	}
}

to_snake_case :: proc(s: string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< len(s) {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			if i > 0 && s[i - 1] != '_' && !(s[i - 1] >= 'A' && s[i - 1] <= 'Z') {
				strings.write_byte(&b, '_')
			}
			strings.write_byte(&b, c + 32)
		} else {
			strings.write_byte(&b, c)
		}
	}
	return strings.clone(strings.to_string(b))
}

escape_string_literal :: proc(s: string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< len(s) {
		switch s[i] {
		case '\\':
			strings.write_string(&b, "\\\\")
		case '"':
			strings.write_string(&b, "\\\"")
		case '\n':
			strings.write_string(&b, "\\n")
		case '\r':
			strings.write_string(&b, "\\r")
		case '\t':
			strings.write_string(&b, "\\t")
		case:
			strings.write_byte(&b, s[i])
		}
	}
	return strings.clone(strings.to_string(b))
}

is_valid_ident :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	if !is_alpha(s[0]) && s[0] != '_' do return false
	for i in 1 ..< len(s) {
		if !is_alphanumeric(s[i]) && s[i] != '_' && s[i] != '.' do return false
	}
	return true
}

get_root_ident :: proc(s: string) -> string {
	dot_idx := strings.index_byte(s, '.')
	if dot_idx >= 0 {
		return s[:dot_idx]
	}
	return s
}

// Recursive parser
parse_nodes :: proc(src: string, pos: ^int, stop_char: u8 = 0, stop_tag: string = "") -> [dynamic]Node {
	nodes := make([dynamic]Node)
	text_buf := strings.builder_make()
	defer strings.builder_destroy(&text_buf)

	flush_text :: proc(nodes: ^[dynamic]Node, text_buf: ^strings.Builder) {
		if strings.builder_len(text_buf^) > 0 {
			t := strings.clone(strings.to_string(text_buf^))
			append(nodes, Node{kind = .Text, text = t})
			strings.builder_reset(text_buf)
		}
	}

	for pos^ < len(src) {
		if stop_char != 0 && src[pos^] == stop_char {
			break
		}
		if len(stop_tag) > 0 && strings.has_prefix(src[pos^:], stop_tag) {
			pos^ += len(stop_tag)
			break
		}

		// 0. Check for backslash escaping: \{, \}, \@, \\
		if src[pos^] == '\\' && pos^ + 1 < len(src) {
			next_c := src[pos^ + 1]
			if next_c == '{' || next_c == '}' || next_c == '@' || next_c == '\\' {
				strings.write_byte(&text_buf, next_c)
				pos^ += 2
				continue
			}
		}

		// 1. Check for {{ (escaped brace) or {slot} or {var}
		if src[pos^] == '{' {
			if pos^ + 1 < len(src) && src[pos^ + 1] == '{' {
				// Escaped {{ -> emit literal {
				strings.write_byte(&text_buf, '{')
				pos^ += 2
				continue
			}

			if strings.has_prefix(src[pos^:], "{slot}") {
				flush_text(&nodes, &text_buf)
				append(&nodes, Node{kind = .Slot})
				pos^ += 6
				continue
			}

			// Look for matching '}'
			end := -1
			for i in pos^ + 1 ..< len(src) {
				if src[i] == '}' {
					end = i
					break
				}
				if src[i] == '\n' || src[i] == ';' do break
			}

			if end != -1 {
				ident := strings.trim_space(src[pos^ + 1 : end])
				if is_valid_ident(ident) {
					flush_text(&nodes, &text_buf)
					append(&nodes, Node{kind = .Var, text = strings.clone(ident)})
					pos^ = end + 1
					continue
				}
			}
		}

		// 1b. Check for }} (escaped closing brace)
		if src[pos^] == '}' {
			if pos^ + 1 < len(src) && src[pos^ + 1] == '}' {
				strings.write_byte(&text_buf, '}')
				pos^ += 2
				continue
			}
		}

		// 1c. Check for @@ (escaped @)
		if src[pos^] == '@' && pos^ + 1 < len(src) && src[pos^ + 1] == '@' {
			strings.write_byte(&text_buf, '@')
			pos^ += 2
			continue
		}

		// 2. Check for @Component(...)
		if src[pos^] == '@' && pos^ + 1 < len(src) && is_alpha(src[pos^ + 1]) {
			p := pos^ + 1
			for p < len(src) && (is_alphanumeric(src[p]) || src[p] == '_') {
				p += 1
			}
			comp_name := src[pos^ + 1 : p]
			p_skip := p
			skip_whitespace(src, &p_skip)
			if p_skip < len(src) && src[p_skip] == '(' {
				flush_text(&nodes, &text_buf)
				p = p_skip + 1 // skip '('

				props := make([dynamic]Prop)
				for p < len(src) && src[p] != ')' {
					skip_whitespace(src, &p)
					if p >= len(src) || src[p] == ')' do break
					if src[p] == ',' {
						p += 1
						skip_whitespace(src, &p)
						if p >= len(src) || src[p] == ')' do break
					}

					prop_start := p
					for p < len(src) && (is_alphanumeric(src[p]) || src[p] == '_') {
						p += 1
					}
					prop_name := src[prop_start:p]
					skip_whitespace(src, &p)
					if p < len(src) && (src[p] == ':' || src[p] == '=') {
						p += 1
						skip_whitespace(src, &p)
					}

					val_is_literal := false
					val_str := ""
					if p < len(src) && (src[p] == '"' || src[p] == '\'') {
						q := src[p]
						p += 1
						val_start := p
						for p < len(src) && src[p] != q {
							if src[p] == '\\' && p + 1 < len(src) do p += 1
							p += 1
						}
						val_str = src[val_start:p]
						if p < len(src) && src[p] == q do p += 1
						val_is_literal = true
					} else {
						val_start := p
						for p < len(src) && src[p] != ',' && src[p] != ')' && src[p] != ' ' && src[p] != '\t' && src[p] != '\r' && src[p] != '\n' {
							p += 1
						}
						val_str = src[val_start:p]
						val_is_literal = false
					}
					append(&props, Prop{name = strings.clone(prop_name), value = strings.clone(val_str), is_literal = val_is_literal})
				}
				if p < len(src) && src[p] == ')' do p += 1

				skip_whitespace(src, &p)
				has_slot_block := false
				children := make([dynamic]Node)
				if p < len(src) && src[p] == '{' {
					has_slot_block = true
					p += 1 // consume '{'
					children = parse_nodes(src, &p, stop_char = '}')
					if p < len(src) && src[p] == '}' do p += 1
				}

				append(&nodes, Node{
					kind = .Component_Call,
					component_name = strings.clone(comp_name),
					props = props,
					has_slot_block = has_slot_block,
					children = children,
				})
				pos^ = p
				continue
			}
		}

		// 3. Check for <Component ... /> or <Component ...> ... </Component>
		if src[pos^] == '<' && pos^ + 1 < len(src) && (src[pos^ + 1] >= 'A' && src[pos^ + 1] <= 'Z') {
			p := pos^ + 1
			for p < len(src) && (is_alphanumeric(src[p]) || src[p] == '_') {
				p += 1
			}
			comp_name := src[pos^ + 1 : p]
			flush_text(&nodes, &text_buf)

			props := make([dynamic]Prop)
			is_self_closing := false
			for p < len(src) {
				skip_whitespace(src, &p)
				if p >= len(src) do break
				if src[p] == '/' && p + 1 < len(src) && src[p + 1] == '>' {
					is_self_closing = true
					p += 2
					break
				}
				if src[p] == '>' {
					p += 1
					break
				}

				prop_start := p
				for p < len(src) && (is_alphanumeric(src[p]) || src[p] == '_' || src[p] == '-') {
					p += 1
				}
				prop_name := src[prop_start:p]
				skip_whitespace(src, &p)
				val_is_literal := false
				val_str := ""
				if p < len(src) && src[p] == '=' {
					p += 1
					skip_whitespace(src, &p)
					if p < len(src) && (src[p] == '"' || src[p] == '\'') {
						q := src[p]
						p += 1
						val_start := p
						for p < len(src) && src[p] != q {
							if src[p] == '\\' && p + 1 < len(src) do p += 1
							p += 1
						}
						val_str = src[val_start:p]
						if p < len(src) && src[p] == q do p += 1
						val_is_literal = true
					} else if p < len(src) && src[p] == '{' {
						p += 1
						val_start := p
						for p < len(src) && src[p] != '}' {
							p += 1
						}
						val_str = src[val_start:p]
						if p < len(src) && src[p] == '}' do p += 1
						val_is_literal = false
					} else {
						val_start := p
						for p < len(src) && src[p] != ' ' && src[p] != '\t' && src[p] != '>' && src[p] != '/' {
							p += 1
						}
						val_str = src[val_start:p]
						val_is_literal = false
					}
				}
				append(&props, Prop{name = strings.clone(prop_name), value = strings.clone(val_str), is_literal = val_is_literal})
			}

			children := make([dynamic]Node)
			if !is_self_closing {
				closing_tag := fmt.tprintf("</%s>", comp_name)
				children = parse_nodes(src, &p, stop_tag = closing_tag)
			}

			append(&nodes, Node{
				kind = .Component_Call,
				component_name = strings.clone(comp_name),
				props = props,
				has_slot_block = !is_self_closing,
				children = children,
			})
			pos^ = p
			continue
		}

		strings.write_byte(&text_buf, src[pos^])
		pos^ += 1
	}

	flush_text(&nodes, &text_buf)
	return nodes
}

// Check if tree contains .Slot
has_slot_node :: proc(nodes: []Node) -> bool {
	for node in nodes {
		if node.kind == .Slot do return true
		if len(node.children) > 0 {
			if has_slot_node(node.children[:]) do return true
		}
	}
	return false
}

// Collect all variable references in nodes
collect_vars :: proc(nodes: []Node, vars: ^[dynamic]string) {
	for node in nodes {
		switch node.kind {
		case .Var:
			root := get_root_ident(node.text)
			if !slice.contains(vars^[:], root) {
				append(vars, strings.clone(root))
			}
		case .Component_Call:
			for prop in node.props {
				if !prop.is_literal && len(prop.value) > 0 {
					if prop.value != "true" && prop.value != "false" && prop.value != "nil" && !is_digit(prop.value[0]) {
						root := get_root_ident(prop.value)
						if !slice.contains(vars^[:], root) {
							append(vars, strings.clone(root))
						}
					}
				}
			}
			if len(node.children) > 0 {
				collect_vars(node.children[:], vars)
			}
		case .Text, .Slot:
			// none
		}
	}
}

// Global slot counter for unique context struct names
slot_counter := 0

// Code emitter for a node list
emit_nodes :: proc(b: ^strings.Builder, nodes: []Node, inside_slot: bool, parent_vars: []string) {
	for node in nodes {
		switch node.kind {
		case .Text:
			if len(node.text) > 0 {
				escaped := escape_string_literal(node.text)
				defer delete(escaped)
				strings.write_string(b, "\tstrings.write_string(b, \"")
				strings.write_string(b, escaped)
				strings.write_string(b, "\")\n")
			}
		case .Var:
			strings.write_string(b, "\tstrings.write_string(b, ")
			if inside_slot {
				strings.write_string(b, "ctx.")
				strings.write_string(b, node.text)
			} else {
				strings.write_string(b, node.text)
			}
			strings.write_string(b, ")\n")
		case .Slot:
			strings.write_string(b, "\tif slot != nil {\n\t\tslot(b, user_data)\n\t}\n")
		case .Component_Call:
			target_proc := fmt.tprintf("render_%s", to_snake_case(node.component_name))
			if node.has_slot_block && len(node.children) > 0 {
				// Slot child content: find outer variables used inside children
				child_vars := make([dynamic]string)
				defer delete(child_vars)
				collect_vars(node.children[:], &child_vars)

				slot_counter += 1
				cur_slot_id := slot_counter

				if len(child_vars) > 0 {
					// Generate Slot_Ctx struct and instance
					fmt.sbprintf(b, "\tSlot_Ctx_%d :: struct ", cur_slot_id)
					strings.write_string(b, "{\n")
					for v in child_vars {
						fmt.sbprintf(b, "\t\t%s: string,\n", v)
					}
					strings.write_string(b, "\t}\n")

					fmt.sbprintf(b, "\t__slot_ctx_%d := Slot_Ctx_%d", cur_slot_id, cur_slot_id)
					strings.write_string(b, "{\n")
					for v in child_vars {
						if inside_slot {
							fmt.sbprintf(b, "\t\t%s = ctx.%s,\n", v, v)
						} else {
							fmt.sbprintf(b, "\t\t%s = %s,\n", v, v)
						}
					}
					strings.write_string(b, "\t}\n")

					// Call component with slot callback and user_data pointer
					fmt.sbprintf(b, "\t%s(b", target_proc)
					for prop in node.props {
						if prop.is_literal {
							esc := escape_string_literal(prop.value)
							defer delete(esc)
							fmt.sbprintf(b, ", %s = \"%s\"", prop.name, esc)
						} else {
							if inside_slot && slice.contains(parent_vars, prop.value) {
								fmt.sbprintf(b, ", %s = ctx.%s", prop.name, prop.value)
							} else {
								fmt.sbprintf(b, ", %s = %s", prop.name, prop.value)
							}
						}
					}
					strings.write_string(b, ", slot = proc(b: ^strings.Builder, user_data: rawptr) {\n")
					fmt.sbprintf(b, "\t\tctx := cast(^Slot_Ctx_%d)user_data\n", cur_slot_id)
					emit_nodes(b, node.children[:], true, child_vars[:])
					fmt.sbprintf(b, "\t}, user_data = &__slot_ctx_%d)\n", cur_slot_id)
				} else {
					// No outer variables used in children
					fmt.sbprintf(b, "\t%s(b", target_proc)
					for prop in node.props {
						if prop.is_literal {
							esc := escape_string_literal(prop.value)
							defer delete(esc)
							fmt.sbprintf(b, ", %s = \"%s\"", prop.name, esc)
						} else {
							if inside_slot && slice.contains(parent_vars, prop.value) {
								fmt.sbprintf(b, ", %s = ctx.%s", prop.name, prop.value)
							} else {
								fmt.sbprintf(b, ", %s = %s", prop.name, prop.value)
							}
						}
					}
					strings.write_string(b, ", slot = proc(b: ^strings.Builder, user_data: rawptr) {\n")
					emit_nodes(b, node.children[:], false, nil)
					strings.write_string(b, "\t})\n")
				}
			} else {
				// No slot block
				fmt.sbprintf(b, "\t%s(b", target_proc)
				for prop in node.props {
					if prop.is_literal {
						esc := escape_string_literal(prop.value)
						defer delete(esc)
						fmt.sbprintf(b, ", %s = \"%s\"", prop.name, esc)
					} else {
						if inside_slot && slice.contains(parent_vars, prop.value) {
							fmt.sbprintf(b, ", %s = ctx.%s", prop.name, prop.value)
						} else {
							fmt.sbprintf(b, ", %s = %s", prop.name, prop.value)
						}
					}
				}
				strings.write_string(b, ")\n")
			}
		}
	}
}

main :: proc() {
	in_dir := "odnetclient/templates"
	out_file := "odnetclient/templates_gen.odin"
	pkg_name := "main"

	for arg in os.args[1:] {
		if strings.has_prefix(arg, "-in:") {
			in_dir = arg[4:]
		} else if strings.has_prefix(arg, "-out:") {
			out_file = arg[5:]
		} else if strings.has_prefix(arg, "-pkg:") {
			pkg_name = arg[5:]
		}
	}

	fmt.println("====================================================")
	fmt.println("  odnetgen: HTML Component Compiler")
	fmt.println("====================================================")
	fmt.printf("Templates dir : %s\n", in_dir)
	fmt.printf("Output file   : %s\n", out_file)
	fmt.printf("Package       : %s\n", pkg_name)

	f, err := os.open(in_dir)
	if err != os.ERROR_NONE {
		fmt.eprintf("[ERROR] Cannot open templates directory: %s (err: %v)\n", in_dir, err)
		os.exit(1)
	}
	defer os.close(f)

	fis, read_err := os.read_dir(f, 0, context.allocator)
	if read_err != os.ERROR_NONE {
		fmt.eprintf("[ERROR] Failed to read templates directory: %v\n", read_err)
		os.exit(1)
	}
	defer os.file_info_slice_delete(fis, context.allocator)

	components := make([dynamic]Component)
	defer delete(components)

	for fi in fis {
		if strings.has_suffix(fi.name, ".html") {
			base := fi.name[:len(fi.name) - 5]
			full_path, _ := filepath.join({in_dir, fi.name})
			data, read_err := os.read_entire_file(full_path, context.allocator)
			if read_err != nil {
				fmt.eprintf("[ERROR] Could not read file: %s (err: %v)\n", full_path, read_err)
				continue
			}
			src := string(data)

			pos := 0
			nodes := parse_nodes(src, &pos)
			has_slot := has_slot_node(nodes[:])

			vars := make([dynamic]string)
			collect_vars(nodes[:], &vars)
			slice.sort(vars[:])

			comp := Component{
				name = to_snake_case(base),
				raw_name = base,
				filename = fi.name,
				nodes = nodes,
				has_slot = has_slot,
				all_vars = vars,
			}
			append(&components, comp)
			fmt.printf("  [PARSED] %-15s -> render_%-12s (vars: %v, slot: %t)\n", fi.name, comp.name, vars[:], has_slot)
		}
	}

	// Generate Odin source code
	out_builder := strings.builder_make()
	defer strings.builder_destroy(&out_builder)

	strings.write_string(&out_builder, "// Code generated by odnetgen. DO NOT EDIT.\n")
	fmt.sbprintf(&out_builder, "package %s\n\n", pkg_name)
	strings.write_string(&out_builder, "import \"core:strings\"\n\n")
	strings.write_string(&out_builder, "Slot_Proc :: proc(b: ^strings.Builder, user_data: rawptr = nil)\n\n")

	for comp in components {
		fmt.sbprintf(&out_builder, "// render_%s renders %s\n", comp.name, comp.filename)
		fmt.sbprintf(&out_builder, "render_%s :: proc(\n\tb: ^strings.Builder", comp.name)

		for v in comp.all_vars {
			fmt.sbprintf(&out_builder, ",\n\t%s: string = \"\"", v)
		}
		if comp.has_slot {
			strings.write_string(&out_builder, ",\n\tslot: Slot_Proc = nil,\n\tuser_data: rawptr = nil")
		}
		strings.write_string(&out_builder, ",\n) {\n")

		emit_nodes(&out_builder, comp.nodes[:], false, comp.all_vars[:])

		strings.write_string(&out_builder, "}\n\n")
	}

	gen_code := strings.to_string(out_builder)
	write_err := os.write_entire_file(out_file, transmute([]u8)gen_code)
	if write_err != nil {
		fmt.eprintf("[ERROR] Failed to write generated output to: %s (err: %v)\n", out_file, write_err)
		os.exit(1)
	}

	fmt.printf("[SUCCESS] Generated %d components into: %s\n", len(components), out_file)
}

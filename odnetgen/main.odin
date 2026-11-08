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
	Slot_Block,
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
	slot_name:      string,
	fallback_nodes: [dynamic]Node,
	component_name: string,
	props:          [dynamic]Prop,
	has_slot_block: bool,
	children:       [dynamic]Node,
}

Component :: struct {
	name:       string, // lowercase snake_case
	raw_name:   string,
	filename:   string,
	nodes:      [dynamic]Node,
	has_slot:   bool,
	slot_names: [dynamic]string,
	all_vars:   [dynamic]string,
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

is_valid_slot_name :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	if !is_alpha(s[0]) && s[0] != '_' do return false
	for i in 1 ..< len(s) {
		if !is_alphanumeric(s[i]) && s[i] != '_' do return false
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
parse_nodes :: proc(src: string, pos: ^int, stop_char: u8 = 0, stop_tag: string = "", stop_tag2: string = "") -> [dynamic]Node {
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
		if len(stop_tag2) > 0 && strings.has_prefix(src[pos^:], stop_tag2) {
			pos^ += len(stop_tag2)
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

		// 1. Check for {{ (escaped brace) or {slot...} or {var}
		if src[pos^] == '{' {
			if pos^ + 1 < len(src) && src[pos^ + 1] == '{' {
				// Escaped {{ -> emit literal {
				strings.write_byte(&text_buf, '{')
				pos^ += 2
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
				inside := strings.trim_space(src[pos^ + 1 : end])

				// Check if inside represents a slot expression
				if inside == "slot" || strings.has_prefix(inside, "slot:") || strings.has_prefix(inside, "slot ") || strings.has_prefix(inside, "slot?") || strings.has_prefix(inside, "slot|") {
					op_idx := -1
					op_len := 0
					idx_q := strings.index(inside, "??")
					idx_p := strings.index(inside, "||")
					if idx_q >= 0 {
						op_idx = idx_q
						op_len = 2
					} else if idx_p >= 0 {
						op_idx = idx_p
						op_len = 2
					}

					slot_part := ""
					fallback_part := ""
					if op_idx >= 0 {
						slot_part = strings.trim_space(inside[:op_idx])
						fallback_part = strings.trim_space(inside[op_idx + op_len:])
					} else {
						slot_part = inside
					}

					raw_slot_name := ""
					if strings.has_prefix(slot_part, "slot:") {
						raw_slot_name = strings.trim_space(slot_part[5:])
					} else if slot_part == "slot" {
						raw_slot_name = ""
					}

					if raw_slot_name == "default" do raw_slot_name = ""

					if raw_slot_name == "" || is_valid_slot_name(raw_slot_name) {
						fallback_nodes := make([dynamic]Node)
						if len(fallback_part) > 0 {
							if (fallback_part[0] == '"' || fallback_part[0] == '\'') && len(fallback_part) >= 2 && fallback_part[len(fallback_part)-1] == fallback_part[0] {
								raw_lit := fallback_part[1 : len(fallback_part)-1]
								append(&fallback_nodes, Node{kind = .Text, text = strings.clone(raw_lit)})
							} else if is_valid_ident(fallback_part) {
								append(&fallback_nodes, Node{kind = .Var, text = strings.clone(fallback_part)})
							}
						}

						flush_text(&nodes, &text_buf)
						slot_name_sn := to_snake_case(raw_slot_name) if len(raw_slot_name) > 0 else ""
						append(&nodes, Node{
							kind = .Slot,
							slot_name = slot_name_sn,
							fallback_nodes = fallback_nodes,
						})
						pos^ = end + 1
						continue
					}
				}

				// Standard variable reference: {ident}
				if is_valid_ident(inside) {
					flush_text(&nodes, &text_buf)
					append(&nodes, Node{kind = .Var, text = strings.clone(inside)})
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

		// 2. Check for @Component(...) or @slot(...)
		if src[pos^] == '@' && pos^ + 1 < len(src) && is_alpha(src[pos^ + 1]) {
			p := pos^ + 1
			for p < len(src) && (is_alphanumeric(src[p]) || src[p] == '_') {
				p += 1
			}
			comp_name := src[pos^ + 1 : p]

			if comp_name == "slot" {
				flush_text(&nodes, &text_buf)
				p_skip := p
				skip_whitespace(src, &p_skip)
				slot_name := ""
				if p_skip < len(src) && src[p_skip] == '(' {
					p = p_skip + 1
					skip_whitespace(src, &p)
					if p < len(src) && (src[p] == '"' || src[p] == '\'') {
						q := src[p]
						p += 1
						n_start := p
						for p < len(src) && src[p] != q {
							p += 1
						}
						slot_name = src[n_start:p]
						if p < len(src) && src[p] == q do p += 1
					} else {
						n_start := p
						for p < len(src) && (is_alphanumeric(src[p]) || src[p] == '_') {
							p += 1
						}
						slot_name = src[n_start:p]
					}
					skip_whitespace(src, &p)
					if p < len(src) && src[p] == ')' do p += 1
				} else {
					p = p_skip
				}

				if slot_name == "default" do slot_name = ""

				skip_whitespace(src, &p)
				children := make([dynamic]Node)
				if p < len(src) && src[p] == '{' {
					p += 1 // consume '{'
					children = parse_nodes(src, &p, stop_char = '}')
					if p < len(src) && src[p] == '}' do p += 1
				}

				slot_name_sn := to_snake_case(slot_name) if len(slot_name) > 0 else ""
				append(&nodes, Node{
					kind = .Slot_Block,
					slot_name = slot_name_sn,
					children = children,
				})
				pos^ = p
				continue
			}

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

		// 3. Check for <slot:...> or <slot name="..."> or <slot>
		if src[pos^] == '<' && strings.has_prefix(src[pos^:], "<slot:") {
			p := pos^ + 6
			name_start := p
			for p < len(src) && (is_alphanumeric(src[p]) || src[p] == '_') {
				p += 1
			}
			raw_slot_name := src[name_start:p]
			if raw_slot_name == "default" do raw_slot_name = ""

			is_self_closing := false
			for p < len(src) && src[p] != '>' {
				if src[p] == '/' && p + 1 < len(src) && src[p + 1] == '>' {
					is_self_closing = true
					p += 2
					break
				}
				p += 1
			}
			if !is_self_closing && p < len(src) && src[p] == '>' do p += 1

			flush_text(&nodes, &text_buf)

			children := make([dynamic]Node)
			if !is_self_closing {
				stop1 := fmt.tprintf("</slot:%s>", raw_slot_name if len(raw_slot_name) > 0 else "default")
				stop2 := "</slot>"
				children = parse_nodes(src, &p, stop_tag = stop1, stop_tag2 = stop2)
			}

			slot_name_sn := to_snake_case(raw_slot_name) if len(raw_slot_name) > 0 else ""
			append(&nodes, Node{
				kind = .Slot_Block,
				slot_name = slot_name_sn,
				children = children,
			})
			pos^ = p
			continue
		}

		if src[pos^] == '<' && (strings.has_prefix(src[pos^:], "<slot ") || strings.has_prefix(src[pos^:], "<slot>")) {
			p := pos^ + 5
			raw_slot_name := ""
			is_self_closing := false

			for p < len(src) && src[p] != '>' {
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

				if strings.has_prefix(src[p:], "name=") {
					p += 5
					skip_whitespace(src, &p)
					if p < len(src) && (src[p] == '"' || src[p] == '\'') {
						q := src[p]
						p += 1
						n_start := p
						for p < len(src) && src[p] != q {
							p += 1
						}
						raw_slot_name = src[n_start:p]
						if p < len(src) && src[p] == q do p += 1
					}
				} else {
					p += 1
				}
			}
			if !is_self_closing && p < len(src) && src[p] == '>' do p += 1

			flush_text(&nodes, &text_buf)

			children := make([dynamic]Node)
			if !is_self_closing {
				children = parse_nodes(src, &p, stop_tag = "</slot>")
			}

			if raw_slot_name == "default" do raw_slot_name = ""
			slot_name_sn := to_snake_case(raw_slot_name) if len(raw_slot_name) > 0 else ""
			append(&nodes, Node{
				kind = .Slot_Block,
				slot_name = slot_name_sn,
				children = children,
			})
			pos^ = p
			continue
		}

		// 4. Check for <Component ... /> or <Component ...> ... </Component>
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

// Check if tree contains .Slot or .Slot_Block defined directly in component
has_slot_node :: proc(nodes: []Node) -> bool {
	for node in nodes {
		if node.kind == .Slot || node.kind == .Slot_Block do return true
		if node.kind != .Component_Call && len(node.children) > 0 {
			if has_slot_node(node.children[:]) do return true
		}
		if len(node.fallback_nodes) > 0 {
			if has_slot_node(node.fallback_nodes[:]) do return true
		}
	}
	return false
}

// Collect all unique slot names defined in component (excluding calls to other components)
collect_slot_names :: proc(nodes: []Node, slot_names: ^[dynamic]string) {
	for node in nodes {
		switch node.kind {
		case .Slot, .Slot_Block:
			sn := node.slot_name
			if !slice.contains(slot_names^[:], sn) {
				append(slot_names, strings.clone(sn))
			}
			if len(node.children) > 0 {
				collect_slot_names(node.children[:], slot_names)
			}
			if len(node.fallback_nodes) > 0 {
				collect_slot_names(node.fallback_nodes[:], slot_names)
			}
		case .Component_Call, .Text, .Var:
			// none
		}
	}
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
		case .Slot:
			if len(node.fallback_nodes) > 0 {
				collect_vars(node.fallback_nodes[:], vars)
			}
		case .Slot_Block:
			if len(node.children) > 0 {
				collect_vars(node.children[:], vars)
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
		case .Text:
			// none
		}
	}
}

Slot_Group :: struct {
	name:   string,
	nodes:  [dynamic]Node,
	vars:   [dynamic]string,
	ctx_id: int,
}

// Group children of a Component_Call into slot payloads
group_slots :: proc(children: []Node) -> [dynamic]Slot_Group {
	groups := make([dynamic]Slot_Group)

	has_slot_blocks := false
	for child in children {
		if child.kind == .Slot_Block {
			has_slot_blocks = true
			break
		}
	}

	if !has_slot_blocks {
		if len(children) > 0 {
			default_nodes := make([dynamic]Node)
			for c in children {
				append(&default_nodes, c)
			}
			append(&groups, Slot_Group{name = "", nodes = default_nodes})
		}
		return groups
	}

	default_nodes := make([dynamic]Node)
	has_non_whitespace_default := false

	for child in children {
		if child.kind == .Slot_Block {
			found_idx := -1
			for g, i in groups {
				if g.name == child.slot_name {
					found_idx = i
					break
				}
			}
			if found_idx >= 0 {
				for c in child.children {
					append(&groups[found_idx].nodes, c)
				}
			} else {
				slot_nodes := make([dynamic]Node)
				for c in child.children {
					append(&slot_nodes, c)
				}
				append(&groups, Slot_Group{name = strings.clone(child.slot_name), nodes = slot_nodes})
			}
		} else {
			append(&default_nodes, child)
			if child.kind != .Text || len(strings.trim_space(child.text)) > 0 {
				has_non_whitespace_default = true
			}
		}
	}

	if has_non_whitespace_default {
		found_default := -1
		for g, i in groups {
			if g.name == "" {
				found_default = i
				break
			}
		}
		if found_default >= 0 {
			for c in default_nodes {
				append(&groups[found_default].nodes, c)
			}
			delete(default_nodes)
		} else {
			append(&groups, Slot_Group{name = "", nodes = default_nodes})
		}
	} else {
		delete(default_nodes)
	}

	return groups
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
			slot_var := "slot" if node.slot_name == "" else fmt.tprintf("slot_%s", node.slot_name)
			data_var := "user_data" if node.slot_name == "" else fmt.tprintf("slot_%s_data", node.slot_name)

			fmt.sbprintf(b, "\tif %s != nil ", slot_var)
			strings.write_string(b, "{\n\t\t")
			fmt.sbprintf(b, "%s(b, %s)\n", slot_var, data_var)
			if len(node.fallback_nodes) > 0 {
				strings.write_string(b, "\t} else {\n")
				emit_nodes(b, node.fallback_nodes[:], inside_slot, parent_vars)
				strings.write_string(b, "\t}\n")
			} else {
				strings.write_string(b, "\t}\n")
			}
		case .Slot_Block:
			slot_var := "slot" if node.slot_name == "" else fmt.tprintf("slot_%s", node.slot_name)
			data_var := "user_data" if node.slot_name == "" else fmt.tprintf("slot_%s_data", node.slot_name)

			fmt.sbprintf(b, "\tif %s != nil ", slot_var)
			strings.write_string(b, "{\n\t\t")
			fmt.sbprintf(b, "%s(b, %s)\n", slot_var, data_var)
			if len(node.children) > 0 {
				strings.write_string(b, "\t} else {\n")
				emit_nodes(b, node.children[:], inside_slot, parent_vars)
				strings.write_string(b, "\t}\n")
			} else {
				strings.write_string(b, "\t}\n")
			}
		case .Component_Call:
			target_proc := fmt.tprintf("render_%s", to_snake_case(node.component_name))
			groups := group_slots(node.children[:])
			defer {
				for &g in groups {
					delete(g.nodes)
					delete(g.vars)
				}
				delete(groups)
			}

			if node.has_slot_block && len(groups) > 0 {
				// 1. Prepare variables and emit context structs for each slot using outer variables
				for &g in groups {
					g.vars = make([dynamic]string)
					collect_vars(g.nodes[:], &g.vars)
					slice.sort(g.vars[:])

					if len(g.vars) > 0 {
						slot_counter += 1
						g.ctx_id = slot_counter

						fmt.sbprintf(b, "\tSlot_Ctx_%d :: struct ", g.ctx_id)
						strings.write_string(b, "{\n")
						for v in g.vars {
							fmt.sbprintf(b, "\t\t%s: string,\n", v)
						}
						strings.write_string(b, "\t}\n")

						fmt.sbprintf(b, "\t__slot_ctx_%d := Slot_Ctx_%d", g.ctx_id, g.ctx_id)
						strings.write_string(b, "{\n")
						for v in g.vars {
							if inside_slot {
								fmt.sbprintf(b, "\t\t%s = ctx.%s,\n", v, v)
							} else {
								fmt.sbprintf(b, "\t\t%s = %s,\n", v, v)
							}
						}
						strings.write_string(b, "\t}\n")
					}
				}

				// 2. Call target component procedure
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

				// 3. Emit each slot closure and data pointer
				for g in groups {
					slot_arg := "slot" if g.name == "" else fmt.tprintf("slot_%s", g.name)
					data_arg := "user_data" if g.name == "" else fmt.tprintf("slot_%s_data", g.name)

					fmt.sbprintf(b, ", %s = proc(b: ^strings.Builder, user_data: rawptr) ", slot_arg)
					strings.write_string(b, "{\n")
					if len(g.vars) > 0 {
						fmt.sbprintf(b, "\t\tctx := cast(^Slot_Ctx_%d)user_data\n", g.ctx_id)
						emit_nodes(b, g.nodes[:], true, g.vars[:])
						strings.write_string(b, "\t}, ")
						fmt.sbprintf(b, "%s = &__slot_ctx_%d", data_arg, g.ctx_id)
					} else {
						emit_nodes(b, g.nodes[:], false, nil)
						strings.write_string(b, "\t}")
					}
				}
				strings.write_string(b, ")\n")
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

			vars := make([dynamic]string)
			collect_vars(nodes[:], &vars)
			slice.sort(vars[:])

			slot_names := make([dynamic]string)
			collect_slot_names(nodes[:], &slot_names)
			slice.sort(slot_names[:])

			comp := Component{
				name = to_snake_case(base),
				raw_name = base,
				filename = fi.name,
				nodes = nodes,
				has_slot = len(slot_names) > 0,
				slot_names = slot_names,
				all_vars = vars,
			}
			append(&components, comp)
			fmt.printf("  [PARSED] %-15s -> render_%-12s (vars: %v, slots: %v)\n", fi.name, comp.name, vars[:], slot_names[:])
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

		// Named slots (excluding "")
		for s in comp.slot_names {
			if s != "" {
				fmt.sbprintf(&out_builder, ",\n\tslot_%s: Slot_Proc = nil,\n\tslot_%s_data: rawptr = nil", s, s)
			}
		}

		// Default slot if present
		if slice.contains(comp.slot_names[:], "") {
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

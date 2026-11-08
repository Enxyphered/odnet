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
	If,
	Switch,
	For,
}

Prop :: struct {
	name:       string,
	value:      string,
	is_literal: bool,
}

If_Branch :: struct {
	condition: string, // empty for final else
	body:      [dynamic]Node,
}

Switch_Case :: struct {
	values: [dynamic]string, // empty for default
	body:   [dynamic]Node,
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

	// If block
	if_branches:    [dynamic]If_Branch,

	// Switch block
	switch_expr:    string,
	switch_cases:   [dynamic]Switch_Case,

	// For / Foreach block
	loop_var:       string, // e.g. "item" or "item, idx" or "i"
	loop_in:        string, // e.g. "items" or "0..<count"
	loop_expr:      string, // full expression if 3-clause for
	loop_is_for:    bool,
}

Import_Decl :: struct {
	alias:       string,
	path:        string,
	source_file: string,
}

Prop_Decl :: struct {
	name:          string,
	type_name:     string,
	default_value: string,
}

Component :: struct {
	name:           string, // lowercase snake_case
	raw_name:       string,
	filename:       string,
	imports:        [dynamic]Import_Decl,
	declared_props: [dynamic]Prop_Decl,
	nodes:          [dynamic]Node,
	has_slot:       bool,
	slot_names:     [dynamic]string,
	all_vars:       [dynamic]string,
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

infer_import_alias :: proc(path: string) -> string {
	p := path
	colon_idx := strings.last_index_byte(p, ':')
	if colon_idx >= 0 {
		p = p[colon_idx + 1:]
	}
	for len(p) > 0 && (p[len(p) - 1] == '/' || p[len(p) - 1] == '\\') {
		p = p[:len(p) - 1]
	}
	slash_idx := strings.last_index_any(p, "/\\")
	if slash_idx >= 0 {
		p = p[slash_idx + 1:]
	}
	return p
}

split_case_values :: proc(s: string) -> [dynamic]string {
	vals := make([dynamic]string)
	p := 0
	for p < len(s) {
		skip_whitespace(s, &p)
		if p >= len(s) do break
		start := p
		in_quote := false
		quote_char: u8 = 0
		paren_depth := 0
		for p < len(s) {
			c := s[p]
			if in_quote {
				if c == '\\' && p + 1 < len(s) {
					p += 2
					continue
				}
				if c == quote_char {
					in_quote = false
				}
			} else {
				if c == '"' || c == '\'' {
					in_quote = true
					quote_char = c
				} else if c == '(' {
					paren_depth += 1
				} else if c == ')' {
					paren_depth -= 1
				} else if c == ',' && paren_depth == 0 {
					break
				}
			}
			p += 1
		}
		item := strings.trim_space(s[start:p])
		if len(item) > 0 {
			append(&vals, strings.clone(item))
		}
		if p < len(s) && s[p] == ',' {
			p += 1
		}
	}
	return vals
}

is_valid_expr :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	// Cannot contain newlines or semicolons or unescaped braces
	if strings.contains_any(s, "\n\r;{}") do return false
	// Must start with identifier character, '(', or '!'
	first := s[0]
	if !is_alpha(first) && first != '_' && first != '(' && first != '!' do return false
	return true
}

read_parenthesized_expr :: proc(src: string, p: ^int) -> string {
	if p^ >= len(src) || src[p^] != '(' do return ""
	p^ += 1 // consume '('
	start := p^
	depth := 1
	for p^ < len(src) && depth > 0 {
		c := src[p^]
		if c == '(' {
			depth += 1
			p^ += 1
		} else if c == ')' {
			depth -= 1
			if depth == 0 {
				break
			}
			p^ += 1
		} else if c == '"' || c == '\'' {
			q := c
			p^ += 1
			for p^ < len(src) && src[p^] != q {
				if src[p^] == '\\' && p^ + 1 < len(src) do p^ += 1
				p^ += 1
			}
			if p^ < len(src) && src[p^] == q do p^ += 1
		} else {
			p^ += 1
		}
	}
	expr := src[start:p^]
	if p^ < len(src) && src[p^] == ')' do p^ += 1
	return strings.trim_space(expr)
}

read_until_brace :: proc(src: string, p: ^int) -> string {
	start := p^
	for p^ < len(src) && src[p^] != '{' {
		p^ += 1
	}
	return strings.trim_space(src[start:p^])
}

// Extract identifiers that could be variables from an expression string
extract_expression_vars :: proc(expr: string, vars: ^[dynamic]string, local_scope: []string = nil, imports: []Import_Decl = nil) {
	p := 0
	for p < len(expr) {
		c := expr[p]
		if is_alpha(c) || c == '_' {
			start := p
			for p < len(expr) && (is_alphanumeric(expr[p]) || expr[p] == '_') {
				p += 1
			}
			ident := expr[start:p]

			// Check if this ident was preceded by '.' (meaning it's a field or method name, not root variable)
			pre_p := start - 1
			for pre_p >= 0 && (expr[pre_p] == ' ' || expr[pre_p] == '\t') {
				pre_p -= 1
			}
			if pre_p >= 0 && expr[pre_p] == '.' {
				continue
			}

			// Ignore keywords, literals, and builtins
			switch ident {
			case "true", "false", "nil", "len", "cap", "int", "string", "bool", "cast", "transmute", "size_of", "type_of", "offset_of":
				continue
			}

			// Ignore local scope (loop variables, etc.)
			if slice.contains(local_scope, ident) {
				continue
			}

			// Ignore imported package aliases
			is_import := false
			for imp in imports {
				alias := imp.alias if len(imp.alias) > 0 else infer_import_alias(imp.path)
				if alias == ident {
					is_import = true
					break
				}
			}
			if is_import do continue

			// Add to vars if not present
			if !slice.contains(vars^[:], ident) {
				append(vars, strings.clone(ident))
			}
		} else if c == '"' || c == '\'' {
			q := c
			p += 1
			for p < len(expr) && expr[p] != q {
				if expr[p] == '\\' && p + 1 < len(expr) do p += 1
				p += 1
			}
			if p < len(expr) && expr[p] == q do p += 1
		} else {
			p += 1
		}
	}
}

// Recursive parser for HTML template nodes
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
			bracket_depth := 1
			for i in pos^ + 1 ..< len(src) {
				c := src[i]
				if c == '{' {
					bracket_depth += 1
				} else if c == '}' {
					bracket_depth -= 1
					if bracket_depth == 0 {
						end = i
						break
					}
				} else if c == '\n' || c == ';' {
					break
				}
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
							} else if is_valid_expr(fallback_part) {
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

				// Standard variable / expression reference: {expr}
				if is_valid_expr(inside) {
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

		// 2. Check for @directives: @if, @switch, @for, @foreach, @slot, @Component
		if src[pos^] == '@' && pos^ + 1 < len(src) && is_alpha(src[pos^ + 1]) {
			p := pos^ + 1
			for p < len(src) && (is_alphanumeric(src[p]) || src[p] == '_') {
				p += 1
			}
			comp_name := src[pos^ + 1 : p]

			// --- @if (cond) { ... } @else if ... @else ... ---
			if comp_name == "if" {
				flush_text(&nodes, &text_buf)
				skip_whitespace(src, &p)
				cond := ""
				if p < len(src) && src[p] == '(' {
					cond = read_parenthesized_expr(src, &p)
				} else {
					cond = read_until_brace(src, &p)
				}

				skip_whitespace(src, &p)
				branches := make([dynamic]If_Branch)
				if p < len(src) && src[p] == '{' {
					p += 1 // consume '{'
					body := parse_nodes(src, &p, stop_char = '}')
					if p < len(src) && src[p] == '}' do p += 1
					append(&branches, If_Branch{condition = strings.clone(cond), body = body})
				}

				// Check for chained @else if, @elif, @else
				for {
					saved_p := p
					skip_whitespace(src, &p)
					if p >= len(src) {
						p = saved_p
						break
					}

					if strings.has_prefix(src[p:], "@else if") && (p + 8 >= len(src) || !is_alpha(src[p + 8])) {
						p += 8
						skip_whitespace(src, &p)
						elif_cond := ""
						if p < len(src) && src[p] == '(' {
							elif_cond = read_parenthesized_expr(src, &p)
						} else {
							elif_cond = read_until_brace(src, &p)
						}
						skip_whitespace(src, &p)
						if p < len(src) && src[p] == '{' {
							p += 1
							elif_body := parse_nodes(src, &p, stop_char = '}')
							if p < len(src) && src[p] == '}' do p += 1
							append(&branches, If_Branch{condition = strings.clone(elif_cond), body = elif_body})
						}
					} else if strings.has_prefix(src[p:], "@elif") && (p + 5 >= len(src) || !is_alpha(src[p + 5])) {
						p += 5
						skip_whitespace(src, &p)
						elif_cond := ""
						if p < len(src) && src[p] == '(' {
							elif_cond = read_parenthesized_expr(src, &p)
						} else {
							elif_cond = read_until_brace(src, &p)
						}
						skip_whitespace(src, &p)
						if p < len(src) && src[p] == '{' {
							p += 1
							elif_body := parse_nodes(src, &p, stop_char = '}')
							if p < len(src) && src[p] == '}' do p += 1
							append(&branches, If_Branch{condition = strings.clone(elif_cond), body = elif_body})
						}
					} else if strings.has_prefix(src[p:], "@else") && (p + 5 >= len(src) || !is_alpha(src[p + 5])) {
						p += 5
						skip_whitespace(src, &p)
						if p < len(src) && src[p] == '{' {
							p += 1
							else_body := parse_nodes(src, &p, stop_char = '}')
							if p < len(src) && src[p] == '}' do p += 1
							append(&branches, If_Branch{condition = "", body = else_body})
						}
						break
					} else {
						p = saved_p
						break
					}
				}

				append(&nodes, Node{kind = .If, if_branches = branches})
				pos^ = p
				continue
			}

			// --- @switch (expr) { @case ... @default ... } ---
			if comp_name == "switch" {
				flush_text(&nodes, &text_buf)
				skip_whitespace(src, &p)
				sw_expr := ""
				if p < len(src) && src[p] == '(' {
					sw_expr = read_parenthesized_expr(src, &p)
				} else {
					sw_expr = read_until_brace(src, &p)
				}

				skip_whitespace(src, &p)
				cases := make([dynamic]Switch_Case)
				if p < len(src) && src[p] == '{' {
					p += 1
					for p < len(src) && src[p] != '}' {
						skip_whitespace(src, &p)
						if p >= len(src) || src[p] == '}' do break
						old_p := p

						if strings.has_prefix(src[p:], "@case") && (p + 5 >= len(src) || !is_alpha(src[p + 5])) {
							p += 5
							skip_whitespace(src, &p)
							cv_str := ""
							if p < len(src) && src[p] == '(' {
								cv_str = read_parenthesized_expr(src, &p)
							} else {
								cv_str = read_until_brace(src, &p)
							}

							vals := split_case_values(cv_str)
							skip_whitespace(src, &p)
							c_body: [dynamic]Node
							if p < len(src) && src[p] == '{' {
								p += 1
								c_body = parse_nodes(src, &p, stop_char = '}')
								if p < len(src) && src[p] == '}' do p += 1
							}
							append(&cases, Switch_Case{values = vals, body = c_body})
						} else if strings.has_prefix(src[p:], "@default") && (p + 8 >= len(src) || !is_alpha(src[p + 8])) {
							p += 8
							skip_whitespace(src, &p)
							def_body: [dynamic]Node
							if p < len(src) && src[p] == '{' {
								p += 1
								def_body = parse_nodes(src, &p, stop_char = '}')
								if p < len(src) && src[p] == '}' do p += 1
							}
							append(&cases, Switch_Case{values = nil, body = def_body})
						} else {
							p += 1
						}

						if p == old_p do p += 1
					}
					if p < len(src) && src[p] == '}' do p += 1
				}

				append(&nodes, Node{kind = .Switch, switch_expr = strings.clone(sw_expr), switch_cases = cases})
				pos^ = p
				continue
			}

			// --- @foreach and @for ---
			if comp_name == "foreach" || comp_name == "for" {
				flush_text(&nodes, &text_buf)
				skip_whitespace(src, &p)
				header := ""
				if p < len(src) && src[p] == '(' {
					header = read_parenthesized_expr(src, &p)
				} else {
					header = read_until_brace(src, &p)
				}

				skip_whitespace(src, &p)
				loop_body: [dynamic]Node
				if p < len(src) && src[p] == '{' {
					p += 1
					loop_body = parse_nodes(src, &p, stop_char = '}')
					if p < len(src) && src[p] == '}' do p += 1
				}

				loop_var := ""
				loop_in := ""
				loop_expr := ""
				is_for := comp_name == "for"

				in_idx := strings.index(header, " in ")
				if in_idx >= 0 {
					loop_var = strings.trim_space(header[:in_idx])
					loop_in = strings.trim_space(header[in_idx + 4:])
				} else {
					loop_expr = header
				}

				append(&nodes, Node{
					kind = .For,
					loop_var = strings.clone(loop_var),
					loop_in = strings.clone(loop_in),
					loop_expr = strings.clone(loop_expr),
					loop_is_for = is_for,
					children = loop_body,
				})
				pos^ = p
				continue
			}

			// --- @slot(...) { ... } ---
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

			// --- @Component(...) { ... } ---
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
						paren_depth := 0
						for p < len(src) {
							ch := src[p]
							if ch == '(' {
								paren_depth += 1
							} else if ch == ')' {
								if paren_depth == 0 do break
								paren_depth -= 1
							} else if ch == ',' && paren_depth == 0 {
								break
							}
							p += 1
						}
						val_str = strings.trim_space(src[val_start:p])
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

		// 3b. Tag-style <if condition="..."> ... </if>
		if src[pos^] == '<' && (strings.has_prefix(src[pos^:], "<if ") || strings.has_prefix(src[pos^:], "<if>")) {
			p := pos^ + 3
			cond := ""
			for p < len(src) && src[p] != '>' {
				skip_whitespace(src, &p)
				if p >= len(src) || src[p] == '>' do break
				if strings.has_prefix(src[p:], "condition=") || strings.has_prefix(src[p:], "cond=") || strings.has_prefix(src[p:], "test=") {
					eq_idx := strings.index_byte(src[p:], '=')
					p += eq_idx + 1
					skip_whitespace(src, &p)
					if p < len(src) && (src[p] == '"' || src[p] == '\'') {
						q := src[p]
						p += 1
						c_start := p
						for p < len(src) && src[p] != q {
							p += 1
						}
						cond = src[c_start:p]
						if p < len(src) && src[p] == q do p += 1
					}
				} else {
					p += 1
				}
			}
			if p < len(src) && src[p] == '>' do p += 1

			flush_text(&nodes, &text_buf)
			body := parse_nodes(src, &p, stop_tag = "</if>")
			branches := make([dynamic]If_Branch)
			append(&branches, If_Branch{condition = strings.clone(cond), body = body})
			append(&nodes, Node{kind = .If, if_branches = branches})
			pos^ = p
			continue
		}

		// 3c. Tag-style <switch expr="..."> ... </switch>
		if src[pos^] == '<' && (strings.has_prefix(src[pos^:], "<switch ") || strings.has_prefix(src[pos^:], "<switch>")) {
			p := pos^ + 7
			sw_expr := ""
			for p < len(src) && src[p] != '>' {
				skip_whitespace(src, &p)
				if p >= len(src) || src[p] == '>' do break
				if strings.has_prefix(src[p:], "expr=") || strings.has_prefix(src[p:], "value=") {
					eq_idx := strings.index_byte(src[p:], '=')
					p += eq_idx + 1
					skip_whitespace(src, &p)
					if p < len(src) && (src[p] == '"' || src[p] == '\'') {
						q := src[p]
						p += 1
						e_start := p
						for p < len(src) && src[p] != q {
							p += 1
						}
						sw_expr = src[e_start:p]
						if p < len(src) && src[p] == q do p += 1
					}
				} else {
					p += 1
				}
			}
			if p < len(src) && src[p] == '>' do p += 1

			flush_text(&nodes, &text_buf)

			cases := make([dynamic]Switch_Case)
			for p < len(src) {
				skip_whitespace(src, &p)
				if p >= len(src) do break
				if strings.has_prefix(src[p:], "</switch>") {
					p += 9
					break
				}
				if strings.has_prefix(src[p:], "<case") {
					p += 5
					c_val := ""
					for p < len(src) && src[p] != '>' {
						skip_whitespace(src, &p)
						if strings.has_prefix(src[p:], "value=") || strings.has_prefix(src[p:], "val=") {
							eq_idx := strings.index_byte(src[p:], '=')
							p += eq_idx + 1
							skip_whitespace(src, &p)
							if p < len(src) && (src[p] == '"' || src[p] == '\'') {
								q := src[p]
								p += 1
								v_start := p
								for p < len(src) && src[p] != q {
									p += 1
								}
								c_val = src[v_start:p]
								if p < len(src) && src[p] == q do p += 1
							}
						} else {
							p += 1
						}
					}
					if p < len(src) && src[p] == '>' do p += 1
					case_body := parse_nodes(src, &p, stop_tag = "</case>")
					vals := split_case_values(c_val)
					append(&cases, Switch_Case{values = vals, body = case_body})
				} else if strings.has_prefix(src[p:], "<default>") {
					p += 9
					def_body := parse_nodes(src, &p, stop_tag = "</default>")
					append(&cases, Switch_Case{values = nil, body = def_body})
				} else {
					p += 1
				}
			}

			append(&nodes, Node{kind = .Switch, switch_expr = strings.clone(sw_expr), switch_cases = cases})
			pos^ = p
			continue
		}

		// 3d. Tag-style <foreach ...> ... </foreach> or <for ...> ... </for>
		is_foreach_tag := strings.has_prefix(src[pos^:], "<foreach ") || strings.has_prefix(src[pos^:], "<foreach>")
		is_for_tag := strings.has_prefix(src[pos^:], "<for ") || strings.has_prefix(src[pos^:], "<for>")
		if src[pos^] == '<' && (is_foreach_tag || is_for_tag) {
			is_foreach := is_foreach_tag
			tag_name := "foreach" if is_foreach else "for"
			p := pos^ + 1 + len(tag_name)
			skip_whitespace(src, &p)
			start_h := p
			for p < len(src) && src[p] != '>' {
				p += 1
			}
			raw_header := strings.trim_space(src[start_h:p])
			if p < len(src) && src[p] == '>' do p += 1

			flush_text(&nodes, &text_buf)
			stop_t := fmt.tprintf("</%s>", tag_name)
			loop_body := parse_nodes(src, &p, stop_tag = stop_t)

			loop_var := ""
			loop_in := ""
			loop_expr := ""

			in_idx := strings.index(raw_header, " in ")
			if in_idx >= 0 {
				loop_var = strings.trim_space(raw_header[:in_idx])
				loop_in = strings.trim_space(raw_header[in_idx + 4:])
			} else {
				loop_expr = raw_header
			}

			append(&nodes, Node{
				kind = .For,
				loop_var = strings.clone(loop_var),
				loop_in = strings.clone(loop_in),
				loop_expr = strings.clone(loop_expr),
				loop_is_for = !is_foreach,
				children = loop_body,
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
		if node.kind == .If {
			for b in node.if_branches {
				if has_slot_node(b.body[:]) do return true
			}
		}
		if node.kind == .Switch {
			for c in node.switch_cases {
				if has_slot_node(c.body[:]) do return true
			}
		}
		if node.kind == .For {
			if has_slot_node(node.children[:]) do return true
		}
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
		case .If:
			for b in node.if_branches {
				collect_slot_names(b.body[:], slot_names)
			}
		case .Switch:
			for c in node.switch_cases {
				collect_slot_names(c.body[:], slot_names)
			}
		case .For:
			collect_slot_names(node.children[:], slot_names)
		case .Component_Call, .Text, .Var:
			// none
		}
	}
}

// Collect all variable references in nodes, respecting loop local scopes and imports
collect_vars :: proc(nodes: []Node, vars: ^[dynamic]string, local_scope: []string = nil, imports: []Import_Decl = nil) {
	for node in nodes {
		switch node.kind {
		case .Var:
			extract_expression_vars(node.text, vars, local_scope, imports)
		case .Slot:
			if len(node.fallback_nodes) > 0 {
				collect_vars(node.fallback_nodes[:], vars, local_scope, imports)
			}
		case .Slot_Block:
			if len(node.children) > 0 {
				collect_vars(node.children[:], vars, local_scope, imports)
			}
		case .Component_Call:
			for prop in node.props {
				if !prop.is_literal && len(prop.value) > 0 {
					extract_expression_vars(prop.value, vars, local_scope, imports)
				}
			}
			if len(node.children) > 0 {
				collect_vars(node.children[:], vars, local_scope, imports)
			}
		case .If:
			for b in node.if_branches {
				if len(b.condition) > 0 {
					extract_expression_vars(b.condition, vars, local_scope, imports)
				}
				collect_vars(b.body[:], vars, local_scope, imports)
			}
		case .Switch:
			extract_expression_vars(node.switch_expr, vars, local_scope, imports)
			for c in node.switch_cases {
				for v in c.values {
					extract_expression_vars(v, vars, local_scope, imports)
				}
				collect_vars(c.body[:], vars, local_scope, imports)
			}
		case .For:
			if len(node.loop_in) > 0 {
				extract_expression_vars(node.loop_in, vars, local_scope, imports)
			}
			if len(node.loop_expr) > 0 {
				extract_expression_vars(node.loop_expr, vars, local_scope, imports)
			}

			// Add loop variables to local scope for the loop body
			new_local := make([dynamic]string)
			defer delete(new_local)
			for item in local_scope {
				append(&new_local, item)
			}
			if len(node.loop_var) > 0 {
				parts := strings.split(node.loop_var, ",")
				defer delete(parts)
				for p in parts {
					trimmed := strings.trim_space(p)
					if len(trimmed) > 0 && !slice.contains(new_local[:], trimmed) {
						append(&new_local, strings.clone(trimmed))
					}
				}
			}
			collect_vars(node.children[:], vars, new_local[:], imports)
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
emit_nodes :: proc(
	b: ^strings.Builder,
	nodes: []Node,
	inside_slot: bool,
	parent_vars: []string,
	local_vars: []string = nil,
	declared_props: []Prop_Decl = nil,
) {
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
			root := get_root_ident(node.text)
			is_local := slice.contains(local_vars, root)
			is_parent := slice.contains(parent_vars, root)

			strings.write_string(b, "\trender_write(b, ")
			if !is_local && inside_slot && is_parent {
				strings.write_string(b, "ctx.")
				strings.write_string(b, node.text)
			} else {
				strings.write_string(b, node.text)
			}
			strings.write_string(b, ")\n")
		case .If:
			for branch, i in node.if_branches {
				if i == 0 {
					fmt.sbprintf(b, "\tif %s ", branch.condition)
					strings.write_string(b, "{\n")
				} else if len(branch.condition) > 0 {
					fmt.sbprintf(b, "\t} else if %s ", branch.condition)
					strings.write_string(b, "{\n")
				} else {
					strings.write_string(b, "\t} else {\n")
				}
				emit_nodes(b, branch.body[:], inside_slot, parent_vars, local_vars, declared_props)
			}
			strings.write_string(b, "\t}\n")
		case .Switch:
			fmt.sbprintf(b, "\tswitch %s ", node.switch_expr)
			strings.write_string(b, "{\n")
			for c in node.switch_cases {
				if len(c.values) > 0 {
					joined := strings.join(c.values[:], ", ")
					defer delete(joined)
					fmt.sbprintf(b, "\tcase %s:\n", joined)
				} else {
					strings.write_string(b, "\tcase:\n")
				}
				emit_nodes(b, c.body[:], inside_slot, parent_vars, local_vars, declared_props)
			}
			strings.write_string(b, "\t}\n")
		case .For:
			if node.loop_is_for && len(node.loop_expr) > 0 {
				fmt.sbprintf(b, "\tfor %s ", node.loop_expr)
				strings.write_string(b, "{\n")
			} else {
				fmt.sbprintf(b, "\tfor %s in %s ", node.loop_var, node.loop_in)
				strings.write_string(b, "{\n")
			}

			// Add loop variables to local_vars for body
			new_locals := make([dynamic]string)
			defer delete(new_locals)
			for lv in local_vars {
				append(&new_locals, lv)
			}
			if len(node.loop_var) > 0 {
				parts := strings.split(node.loop_var, ",")
				defer delete(parts)
				for p in parts {
					trimmed := strings.trim_space(p)
					if len(trimmed) > 0 && !slice.contains(new_locals[:], trimmed) {
						append(&new_locals, strings.clone(trimmed))
					}
				}
			}

			emit_nodes(b, node.children[:], inside_slot, parent_vars, new_locals[:], declared_props)
			strings.write_string(b, "\t}\n")
		case .Slot:
			slot_var := "slot" if node.slot_name == "" else fmt.tprintf("slot_%s", node.slot_name)
			data_var := "user_data" if node.slot_name == "" else fmt.tprintf("slot_%s_data", node.slot_name)

			fmt.sbprintf(b, "\tif %s != nil ", slot_var)
			strings.write_string(b, "{\n\t\t")
			fmt.sbprintf(b, "%s(b, %s)\n", slot_var, data_var)
			if len(node.fallback_nodes) > 0 {
				strings.write_string(b, "\t} else {\n")
				emit_nodes(b, node.fallback_nodes[:], inside_slot, parent_vars, local_vars, declared_props)
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
				emit_nodes(b, node.children[:], inside_slot, parent_vars, local_vars, declared_props)
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
							// Determine type from declared_props if available
							type_str := "string"
							for dp in declared_props {
								if dp.name == v {
									type_str = dp.type_name
									break
								}
							}
							fmt.sbprintf(b, "\t\t%s: %s,\n", v, type_str)
						}
						strings.write_string(b, "\t}\n")

						fmt.sbprintf(b, "\t__slot_ctx_%d := Slot_Ctx_%d", g.ctx_id, g.ctx_id)
						strings.write_string(b, "{\n")
						for v in g.vars {
							if inside_slot && !slice.contains(local_vars, v) {
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
						if inside_slot && slice.contains(parent_vars, prop.value) && !slice.contains(local_vars, prop.value) {
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
						emit_nodes(b, g.nodes[:], true, g.vars[:], nil, declared_props)
						strings.write_string(b, "\t}, ")
						fmt.sbprintf(b, "%s = &__slot_ctx_%d", data_arg, g.ctx_id)
					} else {
						emit_nodes(b, g.nodes[:], false, nil, nil, declared_props)
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
						if inside_slot && slice.contains(parent_vars, prop.value) && !slice.contains(local_vars, prop.value) {
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

// Parse @import or <import ... /> declarations from template header
parse_imports_and_props :: proc(src: string, pos: ^int, imports: ^[dynamic]Import_Decl, props: ^[dynamic]Prop_Decl, source_file: string) {
	for pos^ < len(src) {
		skip_whitespace(src, pos)
		if pos^ >= len(src) do break

		// Check @import
		if strings.has_prefix(src[pos^:], "@import") && (pos^ + 7 >= len(src) || !is_alpha(src[pos^ + 7])) {
			pos^ += 7
			skip_whitespace(src, pos)

			if pos^ < len(src) && src[pos^] == '(' {
				// Multi-import block: @import ( ... )
				pos^ += 1
				for pos^ < len(src) && src[pos^] != ')' {
					skip_whitespace(src, pos)
					if pos^ >= len(src) || src[pos^] == ')' do break
					parse_single_import(src, pos, imports, source_file)
					skip_whitespace(src, pos)
					if pos^ < len(src) && src[pos^] == ',' do pos^ += 1
				}
				if pos^ < len(src) && src[pos^] == ')' do pos^ += 1
			} else {
				parse_single_import(src, pos, imports, source_file)
			}
			continue
		}

		// Check <import path="..." /> or <import alias="..." path="..." />
		if strings.has_prefix(src[pos^:], "<import") && (pos^ + 7 >= len(src) || !is_alpha(src[pos^ + 7])) {
			pos^ += 7
			imp_alias := ""
			imp_path := ""
			for pos^ < len(src) && src[pos^] != '>' {
				skip_whitespace(src, pos)
				if pos^ >= len(src) || src[pos^] == '>' do break
				if strings.has_prefix(src[pos^:], "alias=") {
					pos^ += 6
					skip_whitespace(src, pos)
					if pos^ < len(src) && (src[pos^] == '"' || src[pos^] == '\'') {
						q := src[pos^]
						pos^ += 1
						start_a := pos^
						for pos^ < len(src) && src[pos^] != q do pos^ += 1
						imp_alias = src[start_a:pos^]
						if pos^ < len(src) && src[pos^] == q do pos^ += 1
					}
				} else if strings.has_prefix(src[pos^:], "path=") {
					pos^ += 5
					skip_whitespace(src, pos)
					if pos^ < len(src) && (src[pos^] == '"' || src[pos^] == '\'') {
						q := src[pos^]
						pos^ += 1
						start_p := pos^
						for pos^ < len(src) && src[pos^] != q do pos^ += 1
						imp_path = src[start_p:pos^]
						if pos^ < len(src) && src[pos^] == q do pos^ += 1
					}
				} else {
					pos^ += 1
				}
			}
			if pos^ < len(src) && src[pos^] == '>' do pos^ += 1
			if len(imp_path) > 0 {
				append(imports, Import_Decl{alias = strings.clone(imp_alias), path = strings.clone(imp_path), source_file = source_file})
			}
			continue
		}

		// Check @props(...)
		if strings.has_prefix(src[pos^:], "@props") && (pos^ + 6 >= len(src) || !is_alpha(src[pos^ + 6])) {
			pos^ += 6
			skip_whitespace(src, pos)
			if pos^ < len(src) && src[pos^] == '(' {
				pos^ += 1
				for pos^ < len(src) && src[pos^] != ')' {
					skip_whitespace(src, pos)
					if pos^ >= len(src) || src[pos^] == ')' do break
					old_pos := pos^
					parse_single_prop(src, pos, props)
					if pos^ == old_pos do pos^ += 1
					skip_whitespace(src, pos)
					if pos^ < len(src) && src[pos^] == ',' do pos^ += 1
				}
				if pos^ < len(src) && src[pos^] == ')' do pos^ += 1
			}
			continue
		}

		// Check @param name: type = default
		if strings.has_prefix(src[pos^:], "@param") && (pos^ + 6 >= len(src) || !is_alpha(src[pos^ + 6])) {
			pos^ += 6
			skip_whitespace(src, pos)
			parse_single_prop(src, pos, props)
			continue
		}

		// Check <props> ... </props>
		if strings.has_prefix(src[pos^:], "<props>") {
			pos^ += 7
			for pos^ < len(src) {
				skip_whitespace(src, pos)
				if pos^ >= len(src) || strings.has_prefix(src[pos^:], "</props>") do break
				old_pos := pos^
				parse_single_prop(src, pos, props)
				if pos^ == old_pos do pos^ += 1
				skip_whitespace(src, pos)
				if pos^ < len(src) && src[pos^] == ',' do pos^ += 1
			}
			if strings.has_prefix(src[pos^:], "</props>") do pos^ += 8
			continue
		}

		// If neither import nor props, break to start template parsing
		break
	}
}

parse_single_import :: proc(src: string, pos: ^int, imports: ^[dynamic]Import_Decl, source_file: string) {
	skip_whitespace(src, pos)
	if pos^ >= len(src) do return

	first_token := ""
	if src[pos^] == '"' || src[pos^] == '\'' {
		// Bare path: "core:time"
		q := src[pos^]
		pos^ += 1
		start_p := pos^
		for pos^ < len(src) && src[pos^] != q do pos^ += 1
		path := src[start_p:pos^]
		if pos^ < len(src) && src[pos^] == q do pos^ += 1
		append(imports, Import_Decl{alias = "", path = strings.clone(path), source_file = source_file})
	} else if is_alpha(src[pos^]) || src[pos^] == '_' {
		// Alias followed by path: models "../models"
		start_a := pos^
		for pos^ < len(src) && (is_alphanumeric(src[pos^]) || src[pos^] == '_') do pos^ += 1
		alias := src[start_a:pos^]
		skip_whitespace(src, pos)
		if pos^ < len(src) && (src[pos^] == '"' || src[pos^] == '\'') {
			q := src[pos^]
			pos^ += 1
			start_p := pos^
			for pos^ < len(src) && src[pos^] != q do pos^ += 1
			path := src[start_p:pos^]
			if pos^ < len(src) && src[pos^] == q do pos^ += 1
			append(imports, Import_Decl{alias = strings.clone(alias), path = strings.clone(path), source_file = source_file})
		}
	}
}

parse_single_prop :: proc(src: string, pos: ^int, props: ^[dynamic]Prop_Decl) {
	skip_whitespace(src, pos)
	if pos^ >= len(src) do return

	// Read prop name
	if !is_alpha(src[pos^]) && src[pos^] != '_' do return
	start_name := pos^
	for pos^ < len(src) && (is_alphanumeric(src[pos^]) || src[pos^] == '_') do pos^ += 1
	p_name := src[start_name:pos^]

	skip_whitespace(src, pos)
	if pos^ >= len(src) || src[pos^] != ':' do return
	pos^ += 1 // consume ':'
	skip_whitespace(src, pos)

	// Read type_name until '=' or ',' or ')' or '\n'
	start_type := pos^
	bracket_depth := 0
	paren_depth := 0
	for pos^ < len(src) {
		c := src[pos^]
		if c == '[' do bracket_depth += 1
		else if c == ']' do bracket_depth -= 1
		else if c == '(' do paren_depth += 1
		else if c == ')' {
			if paren_depth > 0 {
				paren_depth -= 1
			} else {
				break
			}
		} else if (c == '=' || c == ',' || c == '<' || c == '\n' || c == '\r') && bracket_depth == 0 && paren_depth == 0 {
			break
		}
		pos^ += 1
	}
	p_type := strings.trim_space(src[start_type:pos^])

	// Read default_value if '=' present
	skip_whitespace(src, pos)
	p_default := ""
	if pos^ < len(src) && src[pos^] == '=' {
		pos^ += 1 // consume '='
		skip_whitespace(src, pos)
		start_def := pos^
		bracket_depth = 0
		paren_depth = 0
		in_quote := false
		quote_char: u8 = 0
		for pos^ < len(src) {
			c := src[pos^]
			if in_quote {
				if c == '\\' && pos^ + 1 < len(src) {
					pos^ += 2
					continue
				}
				if c == quote_char do in_quote = false
			} else {
				if c == '"' || c == '\'' {
					in_quote = true
					quote_char = c
				} else if c == '[' do bracket_depth += 1
				else if c == ']' do bracket_depth -= 1
				else if c == '(' do paren_depth += 1
				else if c == ')' {
					if paren_depth > 0 {
						paren_depth -= 1
					} else {
						break
					}
				} else if (c == ',' || c == '<' || c == '\n' || c == '\r') && bracket_depth == 0 && paren_depth == 0 {
					break
				}
			}
			pos^ += 1
		}
		p_default = strings.trim_space(src[start_def:pos^])
	}

	if len(p_name) > 0 && len(p_type) > 0 {
		append(props, Prop_Decl{
			name = strings.clone(p_name),
			type_name = strings.clone(p_type),
			default_value = strings.clone(p_default),
		})
	}
}

Target :: struct {
	parent_dir:   string,
	template_dir: string,
	out_file:     string,
	pkg_name:     string,
}

has_template_files :: proc(dir: string) -> bool {
	f, err := os.open(dir)
	if err != nil do return false
	defer os.close(f)

	fis, read_err := os.read_dir(f, 0, context.temp_allocator)
	if read_err != nil do return false

	for fi in fis {
		if fi.type != .Directory && (strings.has_suffix(fi.name, ".odhtml") || strings.has_suffix(fi.name, ".html")) {
			return true
		}
	}
	return false
}

detect_package_name :: proc(dir: string) -> string {
	f, err := os.open(dir)
	if err != nil {
		base := filepath.base(dir)
		return "main" if base == "." || base == "odnetclient" else strings.clone(base)
	}
	defer os.close(f)

	fis, read_err := os.read_dir(f, 0, context.temp_allocator)
	if read_err == nil {
		for fi in fis {
			if fi.type != .Directory && strings.has_suffix(fi.name, ".odin") {
				if fi.name == "template_gen.odin" || fi.name == "templates_gen.odin" do continue
				file_path, _ := filepath.join({dir, fi.name}, context.temp_allocator)
				data, read_err := os.read_entire_file(file_path, context.temp_allocator)
				if read_err == nil {
					lines := strings.split_lines(string(data), context.temp_allocator)
					for line in lines {
						trimmed := strings.trim_space(line)
						if strings.has_prefix(trimmed, "package ") {
							pkg := strings.trim_space(trimmed[8:])
							if idx := strings.index(pkg, "//"); idx >= 0 {
								pkg = strings.trim_space(pkg[:idx])
							}
							if len(pkg) > 0 {
								return strings.clone(pkg)
							}
						}
					}
				}
			}
		}
	}

	base := filepath.base(dir)
	if base == "." || base == "odnetclient" do return "main"
	return strings.clone(base)
}

find_template_targets :: proc(current_dir: string, targets: ^[dynamic]Target) {
	f, err := os.open(current_dir)
	if err != nil do return
	defer os.close(f)

	fis, read_err := os.read_dir(f, 0, context.temp_allocator)
	if read_err != nil do return

	// Check candidate subdirectories: "templates" first, then "template"
	candidates := [2]string{"templates", "template"}
	for cand in candidates {
		t_path, _ := filepath.join({current_dir, cand}, context.temp_allocator)
		if os.is_dir(t_path) && has_template_files(t_path) {
			pkg := detect_package_name(current_dir)
			out_file, _ := filepath.join({current_dir, "template_gen.odin"}, context.temp_allocator)
			append(targets, Target{
				parent_dir   = strings.clone(current_dir),
				template_dir = strings.clone(t_path),
				out_file     = strings.clone(out_file),
				pkg_name     = pkg,
			})
			break
		}
	}

	// Recurse into subdirectories
	for fi in fis {
		if fi.type == .Directory {
			name := fi.name
			if name == ".git" || name == ".gemini" || name == "output" || name == "bin" ||
			   name == "node_modules" || name == "template" || name == "templates" {
				continue
			}
			sub_path, _ := filepath.join({current_dir, name}, context.temp_allocator)
			find_template_targets(sub_path, targets)
		}
	}
}

compile_templates :: proc(in_dir: string, out_file: string, pkg_name: string) -> bool {
	f, err := os.open(in_dir)
	if err != os.ERROR_NONE {
		fmt.eprintf("[ERROR] Cannot open templates directory: %s (err: %v)\n", in_dir, err)
		return false
	}
	defer os.close(f)

	fis, read_err := os.read_dir(f, 0, context.allocator)
	if read_err != os.ERROR_NONE {
		fmt.eprintf("[ERROR] Failed to read templates directory: %v\n", read_err)
		return false
	}
	defer os.file_info_slice_delete(fis, context.allocator)

	components := make([dynamic]Component)
	defer delete(components)

	for fi in fis {
		is_odhtml := strings.has_suffix(fi.name, ".odhtml")
		is_html := strings.has_suffix(fi.name, ".html")
		if is_odhtml || is_html {
			ext_len := len(".odhtml") if is_odhtml else len(".html")
			base := fi.name[:len(fi.name) - ext_len]
			full_path, _ := filepath.join({in_dir, fi.name})
			data, file_read_err := os.read_entire_file(full_path, context.allocator)
			if file_read_err != nil {
				fmt.eprintf("[ERROR] Could not read file: %s (err: %v)\n", full_path, file_read_err)
				continue
			}
			src := string(data)

			pos := 0
			imports := make([dynamic]Import_Decl)
			declared_props := make([dynamic]Prop_Decl)
			parse_imports_and_props(src, &pos, &imports, &declared_props, fi.name)

			nodes := parse_nodes(src, &pos)

			vars := make([dynamic]string)
			collect_vars(nodes[:], &vars, nil, imports[:])
			slice.sort(vars[:])

			slot_names := make([dynamic]string)
			collect_slot_names(nodes[:], &slot_names)
			slice.sort(slot_names[:])

			comp := Component{
				name = to_snake_case(base),
				raw_name = base,
				filename = fi.name,
				imports = imports,
				declared_props = declared_props,
				nodes = nodes,
				has_slot = len(slot_names) > 0,
				slot_names = slot_names,
				all_vars = vars,
			}
			append(&components, comp)
			fmt.printf("  [PARSED] %-15s -> render_%-12s (props: %d, vars: %v, slots: %v)\n", fi.name, comp.name, len(declared_props), vars[:], slot_names[:])
		}
	}

	// Collect and deduplicate imports across all components
	global_imports := make([dynamic]Import_Decl)
	defer delete(global_imports)
	for comp in components {
		for imp in comp.imports {
			found := false
			for g in global_imports {
				if g.alias == imp.alias && g.path == imp.path {
					found = true
					break
				}
				if g.alias == imp.alias && g.path != imp.path {
					fmt.eprintf("[ERROR] Import alias collision for '%s': '%s' in %s vs '%s' in %s\n", g.alias, g.path, imp.source_file, g.path, g.source_file)
					return false
				}
			}
			if !found {
				append(&global_imports, imp)
			}
		}
	}

	// Generate Odin source code
	out_builder := strings.builder_make()
	defer strings.builder_destroy(&out_builder)

	strings.write_string(&out_builder, "// Code generated by odnetgen. DO NOT EDIT.\n")
	fmt.sbprintf(&out_builder, "package %s\n\n", pkg_name)
	strings.write_string(&out_builder, "import \"core:fmt\"\n")
	strings.write_string(&out_builder, "import \"core:strings\"\n")
	for imp in global_imports {
		if imp.alias == "" {
			fmt.sbprintf(&out_builder, "import \"%s\"\n", imp.path)
		} else {
			fmt.sbprintf(&out_builder, "import %s \"%s\"\n", imp.alias, imp.path)
		}
	}
	strings.write_string(&out_builder, "\n")

	strings.write_string(&out_builder, "Slot_Proc :: proc(b: ^strings.Builder, user_data: rawptr = nil)\n\n")

	// Emit render_write procedure group
	strings.write_string(&out_builder, `render_write_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_string(b, s)
}

render_write_int :: proc(b: ^strings.Builder, v: int) {
	strings.write_int(b, v)
}

render_write_i64 :: proc(b: ^strings.Builder, v: i64) {
	strings.write_i64(b, v)
}

render_write_f64 :: proc(b: ^strings.Builder, v: f64) {
	fmt.sbprintf(b, "%.2f", v)
}

render_write_f32 :: proc(b: ^strings.Builder, v: f32) {
	fmt.sbprintf(b, "%.2f", v)
}

render_write_bool :: proc(b: ^strings.Builder, v: bool) {
	strings.write_string(b, "true" if v else "false")
}

render_write_rune :: proc(b: ^strings.Builder, v: rune) {
	strings.write_rune(b, v)
}

render_write_any :: proc(b: ^strings.Builder, v: any) {
	fmt.sbprint(b, v)
}

render_write :: proc{
	render_write_string,
	render_write_int,
	render_write_i64,
	render_write_f64,
	render_write_f32,
	render_write_bool,
	render_write_rune,
	render_write_any,
}

`)

	for comp in components {
		fmt.sbprintf(&out_builder, "// render_%s renders %s\n", comp.name, comp.filename)
		fmt.sbprintf(&out_builder, "render_%s :: proc(\n\tb: ^strings.Builder", comp.name)

		// 1. Build list of all component parameters:
		// Any declared props, plus any undeclared vars in comp.all_vars
		Param :: struct {
			name:          string,
			type_name:     string,
			default_value: string,
		}
		params := make([dynamic]Param)
		defer delete(params)

		for dp in comp.declared_props {
			append(&params, Param{name = dp.name, type_name = dp.type_name, default_value = dp.default_value})
		}
		for v in comp.all_vars {
			already := false
			for p in params {
				if p.name == v {
					already = true
					break
				}
			}
			if !already {
				append(&params, Param{name = v, type_name = "string", default_value = "\"\""})
			}
		}

		// Partition: required parameters first (no default), then optional (with default)
		for p in params {
			if len(p.default_value) == 0 {
				fmt.sbprintf(&out_builder, ",\n\t%s: %s", p.name, p.type_name)
			}
		}
		for p in params {
			if len(p.default_value) > 0 {
				fmt.sbprintf(&out_builder, ",\n\t%s: %s = %s", p.name, p.type_name, p.default_value)
			}
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

		// List of parent variables passed down to slots
		parent_vars := make([dynamic]string)
		defer delete(parent_vars)
		for p in params {
			append(&parent_vars, p.name)
		}

		emit_nodes(&out_builder, comp.nodes[:], false, parent_vars[:], nil, comp.declared_props[:])

		strings.write_string(&out_builder, "}\n\n")
	}

	gen_code := strings.to_string(out_builder)
	write_err := os.write_entire_file(out_file, transmute([]u8)gen_code)
	if write_err != nil {
		fmt.eprintf("[ERROR] Failed to write generated output to: %s (err: %v)\n", out_file, write_err)
		return false
	}

	// Remove old templates_gen.odin if present to prevent duplicate symbols
	parent_of_out := filepath.dir(out_file)
	old_out, _ := filepath.join({parent_of_out, "templates_gen.odin"}, context.temp_allocator)
	if old_out != out_file && os.exists(old_out) {
		os.remove(old_out)
	}

	fmt.printf("[SUCCESS] Generated %d components into: %s\n", len(components), out_file)
	return true
}

main :: proc() {
	in_dir := ""
	out_file := ""
	pkg_name := ""

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
	fmt.println("  odnetgen: odhtml Component Compiler")
	fmt.println("====================================================")

	if in_dir != "" {
		if out_file == "" do out_file = "odnetclient/template_gen.odin"
		if pkg_name == "" do pkg_name = "main"
		fmt.printf("Templates dir : %s\n", in_dir)
		fmt.printf("Output file   : %s\n", out_file)
		fmt.printf("Package       : %s\n", pkg_name)
		if !compile_templates(in_dir, out_file, pkg_name) {
			os.exit(1)
		}
		return
	}

	// Auto-discovery mode: scan for folders containing a 'template' or 'templates' subfolder with .odhtml or .html files
	targets := make([dynamic]Target)
	defer delete(targets)
	find_template_targets(".", &targets)

	if len(targets) == 0 {
		fmt.println("[WARNING] No folders found containing a 'template' or 'templates' subfolder with .odhtml or .html files.")
		return
	}

	fmt.printf("Discovered %d template target(s):\n", len(targets))
	for t in targets {
		fmt.printf("  - %s -> %s (package %s)\n", t.template_dir, t.out_file, t.pkg_name)
	}
	fmt.println("----------------------------------------------------")

	success_count := 0
	for t in targets {
		fmt.printf("\n[COMPILING] %s -> %s (package %s)\n", t.template_dir, t.out_file, t.pkg_name)
		if compile_templates(t.template_dir, t.out_file, t.pkg_name) {
			success_count += 1
		} else {
			fmt.eprintf("[ERROR] Compilation failed for: %s\n", t.template_dir)
			os.exit(1)
		}
	}

	fmt.println("\n====================================================")
	fmt.printf("[FINISHED] Successfully compiled %d/%d target(s)\n", success_count, len(targets))
	fmt.println("====================================================")
}

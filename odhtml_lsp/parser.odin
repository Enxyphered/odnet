package odhtml_lsp

import "core:fmt"
import "core:slice"
import "core:strings"

Source_Tracker :: struct {
	src:          string,
	line_offsets: [dynamic]int,
}

source_tracker_init :: proc(st: ^Source_Tracker, src: string) {
	st.src = src
	st.line_offsets = make([dynamic]int)
	append(&st.line_offsets, 0)
	for i in 0 ..< len(src) {
		if src[i] == '\n' {
			append(&st.line_offsets, i + 1)
		}
	}
}

source_tracker_destroy :: proc(st: ^Source_Tracker) {
	delete(st.line_offsets)
}

position_at :: proc(st: ^Source_Tracker, offset: int) -> Position {
	off := clamp(offset, 0, len(st.src))
	low := 0
	high := len(st.line_offsets) - 1
	for low <= high {
		mid := (low + high) / 2
		if st.line_offsets[mid] > off {
			high = mid - 1
		} else {
			low = mid + 1
		}
	}
	line := high
	col := off - st.line_offsets[line]
	return Position{line = line, character = col}
}

range_at :: proc(st: ^Source_Tracker, start, end: int) -> Range {
	return Range{
		start = position_at(st, start),
		end   = position_at(st, end),
	}
}

to_pascal_case :: proc(snake: string) -> string {
	b := strings.builder_make()
	parts := strings.split(snake, "_")
	defer delete(parts)
	for p in parts {
		if len(p) == 0 do continue
		first := strings.to_upper(p[:1])
		defer delete(first)
		strings.write_string(&b, first)
		if len(p) > 1 {
			strings.write_string(&b, p[1:])
		}
	}
	return strings.to_string(b)
}

to_snake_case :: proc(name: string) -> string {
	b := strings.builder_make()
	for i in 0 ..< len(name) {
		c := name[i]
		if c >= 'A' && c <= 'Z' {
			if i > 0 && name[i - 1] != '_' {
				strings.write_byte(&b, '_')
			}
			strings.write_byte(&b, c + 32)
		} else {
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

Parser :: struct {
	src:             string,
	pos:             int,
	tracker:         Source_Tracker,
	props:           [dynamic]Prop_Decl,
	imports:         [dynamic]Import_Decl,
	diagnostics:     [dynamic]Diagnostic,
	component_calls: [dynamic]Ast_Node,
	interpolations:  [dynamic]Ast_Node,
}

parser_init :: proc(p: ^Parser, src: string) {
	p.src = src
	p.pos = 0
	source_tracker_init(&p.tracker, src)
	p.props = make([dynamic]Prop_Decl)
	p.imports = make([dynamic]Import_Decl)
	p.diagnostics = make([dynamic]Diagnostic)
	p.component_calls = make([dynamic]Ast_Node)
	p.interpolations = make([dynamic]Ast_Node)
}

parser_destroy :: proc(p: ^Parser) {
	source_tracker_destroy(&p.tracker)
}

skip_ws :: proc(p: ^Parser) {
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
			p.pos += 1
		} else {
			break
		}
	}
}

parse_template :: proc(src: string) -> Parse_Result {
	p: Parser
	parser_init(&p, src)
	defer parser_destroy(&p)

	parse_header(&p)
	nodes := parse_nodes(&p)

	return Parse_Result{
		props           = p.props,
		imports         = p.imports,
		nodes           = nodes,
		diagnostics     = p.diagnostics,
		component_calls = p.component_calls,
		interpolations  = p.interpolations,
	}
}

parse_result_destroy :: proc(res: ^Parse_Result) {
	delete(res.props)
	delete(res.imports)
	for n in res.nodes {
		destroy_node(n)
	}
	delete(res.nodes)
	delete(res.diagnostics)
	delete(res.component_calls)
	delete(res.interpolations)
}

destroy_node :: proc(n: Ast_Node) {
	delete(n.props)
	for child in n.children {
		destroy_node(child)
	}
	delete(n.children)
}

parse_header :: proc(p: ^Parser) {
	skip_ws(p)
	for p.pos < len(p.src) {
		// Comments
		if strings.has_prefix(p.src[p.pos:], "<!--") {
			idx := strings.index(p.src[p.pos:], "-->")
			if idx >= 0 {
				p.pos += idx + 3
				skip_ws(p)
				continue
			}
		}

		if strings.has_prefix(p.src[p.pos:], "@import") {
			parse_import(p)
			skip_ws(p)
			continue
		}

		if strings.has_prefix(p.src[p.pos:], "@props") {
			parse_props(p)
			skip_ws(p)
			continue
		}

		break
	}
}

parse_import :: proc(p: ^Parser) {
	start := p.pos
	p.pos += 7 // "@import"
	skip_ws(p)

	alias := ""
	if p.pos < len(p.src) && p.src[p.pos] != '"' {
		a_start := p.pos
		for p.pos < len(p.src) && (is_alpha(p.src[p.pos]) || is_digit(p.src[p.pos]) || p.src[p.pos] == '_') {
			p.pos += 1
		}
		alias = p.src[a_start:p.pos]
		skip_ws(p)
	}

	if p.pos < len(p.src) && p.src[p.pos] == '"' {
		p.pos += 1
		path_start := p.pos
		for p.pos < len(p.src) && p.src[p.pos] != '"' {
			if p.src[p.pos] == '\\' && p.pos + 1 < len(p.src) do p.pos += 1
			p.pos += 1
		}
		path_val := p.src[path_start:p.pos]
		if p.pos < len(p.src) && p.src[p.pos] == '"' {
			p.pos += 1
		} else {
			append(&p.diagnostics, Diagnostic{
				range    = range_at(&p.tracker, path_start - 1, p.pos),
				severity = .Error,
				message  = "Unterminated string in @import declaration",
				source   = "odhtml",
			})
		}
		append(&p.imports, Import_Decl{
			alias = alias,
			path  = path_val,
			range = range_at(&p.tracker, start, p.pos),
		})
	} else {
		append(&p.diagnostics, Diagnostic{
			range    = range_at(&p.tracker, start, p.pos),
			severity = .Error,
			message  = "Expected quoted path in @import declaration",
			source   = "odhtml",
		})
	}
}

parse_props :: proc(p: ^Parser) {
	start := p.pos
	p.pos += 6 // "@props"
	skip_ws(p)

	if p.pos >= len(p.src) || p.src[p.pos] != '(' {
		append(&p.diagnostics, Diagnostic{
			range    = range_at(&p.tracker, start, p.pos),
			severity = .Error,
			message  = "Expected '(' after @props",
			source   = "odhtml",
		})
		return
	}
	p.pos += 1 // '('
	skip_ws(p)

	seen_props := make([dynamic]string)
	defer delete(seen_props)

	for p.pos < len(p.src) && p.src[p.pos] != ')' {
		skip_ws(p)
		if p.pos >= len(p.src) || p.src[p.pos] == ')' do break

		// Skip comments inside props
		if strings.has_prefix(p.src[p.pos:], "<!--") {
			idx := strings.index(p.src[p.pos:], "-->")
			p.pos = p.pos + idx + 3 if idx >= 0 else len(p.src)
			continue
		}

		prop_start := p.pos
		name_start := p.pos
		for p.pos < len(p.src) && (is_alpha(p.src[p.pos]) || is_digit(p.src[p.pos]) || p.src[p.pos] == '_') {
			p.pos += 1
		}
		prop_name := p.src[name_start:p.pos]
		name_range := range_at(&p.tracker, name_start, p.pos)

		if len(prop_name) == 0 {
			append(&p.diagnostics, Diagnostic{
				range    = range_at(&p.tracker, prop_start, min(prop_start + 1, len(p.src))),
				severity = .Error,
				message  = "Expected prop name in @props declaration",
				source   = "odhtml",
			})
			for p.pos < len(p.src) && p.src[p.pos] != ',' && p.src[p.pos] != ')' {
				p.pos += 1
			}
			if p.pos < len(p.src) && p.src[p.pos] == ',' do p.pos += 1
			continue
		}

		if slice.contains(seen_props[:], prop_name) {
			append(&p.diagnostics, Diagnostic{
				range    = name_range,
				severity = .Warning,
				message  = fmt.tprintf("Duplicate prop '%s' declared in @props", prop_name),
				source   = "odhtml",
			})
		}
		append(&seen_props, prop_name)

		skip_ws(p)
		type_name := "string"
		default_val := ""
		has_default := false

		if p.pos < len(p.src) && p.src[p.pos] == ':' {
			p.pos += 1 // ':'
			skip_ws(p)
			t_start := p.pos
			for p.pos < len(p.src) && p.src[p.pos] != '=' && p.src[p.pos] != ',' && p.src[p.pos] != ')' {
				p.pos += 1
			}
			type_name = strings.trim_space(p.src[t_start:p.pos])
		} else {
			append(&p.diagnostics, Diagnostic{
				range    = name_range,
				severity = .Warning,
				message  = fmt.tprintf("Expected ':' and type after prop name '%s'", prop_name),
				source   = "odhtml",
			})
		}

		skip_ws(p)
		if p.pos < len(p.src) && p.src[p.pos] == '=' {
			p.pos += 1 // '='
			skip_ws(p)
			has_default = true
			d_start := p.pos
			for p.pos < len(p.src) && p.src[p.pos] != ',' && p.src[p.pos] != ')' {
				if p.src[p.pos] == '"' || p.src[p.pos] == '\'' {
					q := p.src[p.pos]
					p.pos += 1
					for p.pos < len(p.src) && p.src[p.pos] != q {
						if p.src[p.pos] == '\\' && p.pos + 1 < len(p.src) do p.pos += 1
						p.pos += 1
					}
					if p.pos < len(p.src) do p.pos += 1
				} else {
					p.pos += 1
				}
			}
			default_val = strings.trim_space(p.src[d_start:p.pos])
		}

		decl := Prop_Decl{
			name          = prop_name,
			type_name     = type_name if len(type_name) > 0 else "string",
			default_value = default_val,
			is_required   = !has_default,
			range         = range_at(&p.tracker, prop_start, p.pos),
			name_range    = name_range,
		}
		append(&p.props, decl)

		skip_ws(p)
		if p.pos < len(p.src) && p.src[p.pos] == ',' {
			p.pos += 1
		}
	}

	if p.pos < len(p.src) && p.src[p.pos] == ')' {
		p.pos += 1
	} else {
		append(&p.diagnostics, Diagnostic{
			range    = range_at(&p.tracker, start, p.pos),
			severity = .Error,
			message  = "Unclosed @props declaration, missing ')'",
			source   = "odhtml",
		})
	}
}

parse_nodes :: proc(p: ^Parser, stop_char: u8 = 0, stop_tag: string = "") -> [dynamic]Ast_Node {
	nodes := make([dynamic]Ast_Node)

	for p.pos < len(p.src) {
		if stop_char != 0 && p.src[p.pos] == stop_char do break
		if len(stop_tag) > 0 && strings.has_prefix(p.src[p.pos:], stop_tag) do break

		// Escapes
		if strings.has_prefix(p.src[p.pos:], "{{") || strings.has_prefix(p.src[p.pos:], "}}") || strings.has_prefix(p.src[p.pos:], "@@") {
			append(&nodes, Ast_Node{
				kind     = .Text,
				raw_text = p.src[p.pos:p.pos + 2],
				range    = range_at(&p.tracker, p.pos, p.pos + 2),
			})
			p.pos += 2
			continue
		}

		// Slot tags
		if strings.has_prefix(p.src[p.pos:], "<slot") {
			slot_node, ok := parse_slot_tag(p)
			if ok do append(&nodes, slot_node)
			continue
		}

		// Custom component tag <ComponentName ...>
		if p.src[p.pos] == '<' && p.pos + 1 < len(p.src) && p.src[p.pos + 1] >= 'A' && p.src[p.pos + 1] <= 'Z' {
			comp_node, ok := parse_component_tag(p)
			if ok {
				append(&nodes, comp_node)
				append(&p.component_calls, comp_node)
			}
			continue
		}

		// Directives starting with @
		if p.src[p.pos] == '@' {
			dir_node, ok := parse_at_directive(p)
			if ok {
				append(&nodes, dir_node)
				if dir_node.kind == .Component_Call {
					append(&p.component_calls, dir_node)
				}
				continue
			}
		}

		// Interpolation {expr} or {slot...}
		if p.src[p.pos] == '{' {
			interp_node, ok := parse_interpolation(p)
			if ok {
				append(&nodes, interp_node)
				append(&p.interpolations, interp_node)
				continue
			}
		}

		// HTML tag
		if p.src[p.pos] == '<' {
			tag_node, ok := parse_html_tag(p)
			if ok {
				append(&nodes, tag_node)
				continue
			}
		}

		// Plain text block
		t_start := p.pos
		for p.pos < len(p.src) &&
		    p.src[p.pos] != '<' &&
		    p.src[p.pos] != '{' &&
		    p.src[p.pos] != '@' &&
		    (stop_char == 0 || p.src[p.pos] != stop_char) &&
		    (len(stop_tag) == 0 || !strings.has_prefix(p.src[p.pos:], stop_tag)) {
			p.pos += 1
		}
		if p.pos > t_start {
			append(&nodes, Ast_Node{
				kind     = .Text,
				raw_text = p.src[t_start:p.pos],
				range    = range_at(&p.tracker, t_start, p.pos),
			})
		}
	}

	return nodes
}

parse_slot_tag :: proc(p: ^Parser) -> (Ast_Node, bool) {
	start := p.pos
	p.pos += 5 // "<slot"
	slot_name := ""
	if p.pos < len(p.src) && p.src[p.pos] == ':' {
		p.pos += 1
		n_start := p.pos
		for p.pos < len(p.src) && (is_alpha(p.src[p.pos]) || is_digit(p.src[p.pos]) || p.src[p.pos] == '_') {
			p.pos += 1
		}
		slot_name = p.src[n_start:p.pos]
	}
	if p.pos < len(p.src) && p.src[p.pos] == '>' {
		p.pos += 1
	}

	close_tag := fmt.tprintf("</slot:%s>", slot_name) if len(slot_name) > 0 else "</slot>"
	children := parse_nodes(p, 0, close_tag)

	if strings.has_prefix(p.src[p.pos:], close_tag) {
		p.pos += len(close_tag)
	} else {
		append(&p.diagnostics, Diagnostic{
			range    = range_at(&p.tracker, start, p.pos),
			severity = .Error,
			message  = fmt.tprintf("Unclosed slot tag, expected '%s'", close_tag),
			source   = "odhtml",
		})
	}

	return Ast_Node{
		kind     = .Slot_Block,
		name     = slot_name,
		children = children,
		range    = range_at(&p.tracker, start, p.pos),
	}, true
}

parse_component_tag :: proc(p: ^Parser) -> (Ast_Node, bool) {
	start := p.pos
	p.pos += 1 // '<'
	name_start := p.pos
	for p.pos < len(p.src) && (is_alpha(p.src[p.pos]) || is_digit(p.src[p.pos]) || p.src[p.pos] == '_') {
		p.pos += 1
	}
	comp_name := p.src[name_start:p.pos]
	name_range := range_at(&p.tracker, name_start, p.pos)
	props := make([dynamic]Prop_Arg)

	for p.pos < len(p.src) && p.src[p.pos] != '>' && !strings.has_prefix(p.src[p.pos:], "/>") {
		skip_ws(p)
		if p.src[p.pos] == '>' || strings.has_prefix(p.src[p.pos:], "/>") do break

		p_start := p.pos
		for p.pos < len(p.src) && (is_alpha(p.src[p.pos]) || is_digit(p.src[p.pos]) || p.src[p.pos] == '_') {
			p.pos += 1
		}
		p_name := p.src[p_start:p.pos]
		name_range := range_at(&p.tracker, p_start, p.pos)

		skip_ws(p)
		p_val := ""
		if p.pos < len(p.src) && p.src[p.pos] == '=' {
			p.pos += 1
			skip_ws(p)
			if p.pos < len(p.src) && (p.src[p.pos] == '"' || p.src[p.pos] == '\'') {
				q := p.src[p.pos]
				p.pos += 1
				val_start := p.pos
				for p.pos < len(p.src) && p.src[p.pos] != q {
					if p.src[p.pos] == '\\' && p.pos + 1 < len(p.src) do p.pos += 1
					p.pos += 1
				}
				p_val = p.src[val_start:p.pos]
				if p.pos < len(p.src) do p.pos += 1
			}
		}

		if len(p_name) > 0 {
			append(&props, Prop_Arg{
				name       = p_name,
				value      = p_val,
				range      = range_at(&p.tracker, p_start, p.pos),
				name_range = name_range,
			})
		}
	}

	is_self_closing := strings.has_prefix(p.src[p.pos:], "/>")
	if is_self_closing {
		p.pos += 2
		return Ast_Node{
			kind       = .Component_Call,
			name       = comp_name,
			name_range = name_range,
			props      = props,
			range      = range_at(&p.tracker, start, p.pos),
		}, true
	} else if p.pos < len(p.src) && p.src[p.pos] == '>' {
		p.pos += 1
		close_tag := fmt.tprintf("</%s>", comp_name)
		children := parse_nodes(p, 0, close_tag)
		if strings.has_prefix(p.src[p.pos:], close_tag) {
			p.pos += len(close_tag)
		} else {
			append(&p.diagnostics, Diagnostic{
				range    = range_at(&p.tracker, start, p.pos),
				severity = .Error,
				message  = fmt.tprintf("Unclosed component tag, expected '%s'", close_tag),
				source   = "odhtml",
			})
		}
		return Ast_Node{
			kind       = .Component_Call,
			name       = comp_name,
			name_range = name_range,
			props      = props,
			children   = children,
			range      = range_at(&p.tracker, start, p.pos),
		}, true
	}

	return Ast_Node{}, false
}

parse_at_directive :: proc(p: ^Parser) -> (Ast_Node, bool) {
	start := p.pos
	p.pos += 1 // '@'

	// Component call @ComponentName(...)
	if p.pos < len(p.src) && p.src[p.pos] >= 'A' && p.src[p.pos] <= 'Z' {
		name_start := p.pos
		for p.pos < len(p.src) && (is_alpha(p.src[p.pos]) || is_digit(p.src[p.pos]) || p.src[p.pos] == '_') {
			p.pos += 1
		}
		comp_name := p.src[name_start:p.pos]
		name_range := range_at(&p.tracker, name_start, p.pos)
		skip_ws(p)

		props := make([dynamic]Prop_Arg)
		if p.pos < len(p.src) && p.src[p.pos] == '(' {
			p.pos += 1 // '('
			for p.pos < len(p.src) && p.src[p.pos] != ')' {
				skip_ws(p)
				if p.src[p.pos] == ')' do break

				p_start := p.pos
				for p.pos < len(p.src) && (is_alpha(p.src[p.pos]) || is_digit(p.src[p.pos]) || p.src[p.pos] == '_') {
					p.pos += 1
				}
				p_name := p.src[p_start:p.pos]
				name_range := range_at(&p.tracker, p_start, p.pos)
				skip_ws(p)

				p_val := ""
				if p.pos < len(p.src) && p.src[p.pos] == ':' {
					p.pos += 1
					skip_ws(p)
					val_start := p.pos
					for p.pos < len(p.src) && p.src[p.pos] != ',' && p.src[p.pos] != ')' {
						if p.src[p.pos] == '"' || p.src[p.pos] == '\'' {
							q := p.src[p.pos]
							p.pos += 1
							for p.pos < len(p.src) && p.src[p.pos] != q {
								if p.src[p.pos] == '\\' && p.pos + 1 < len(p.src) do p.pos += 1
								p.pos += 1
							}
							if p.pos < len(p.src) do p.pos += 1
						} else {
							p.pos += 1
						}
					}
					p_val = strings.trim_space(p.src[val_start:p.pos])
				}

				if len(p_name) > 0 {
					append(&props, Prop_Arg{
						name       = p_name,
						value      = p_val,
						range      = range_at(&p.tracker, p_start, p.pos),
						name_range = name_range,
					})
				}

				skip_ws(p)
				if p.pos < len(p.src) && p.src[p.pos] == ',' do p.pos += 1
			}

			if p.pos < len(p.src) && p.src[p.pos] == ')' {
				p.pos += 1
			} else {
				append(&p.diagnostics, Diagnostic{
					range    = range_at(&p.tracker, start, p.pos),
					severity = .Error,
					message  = fmt.tprintf("Unclosed component call arguments for '@%s', missing ')'", comp_name),
					source   = "odhtml",
				})
			}
		}

		return Ast_Node{
			kind       = .Component_Call,
			name       = comp_name,
			name_range = name_range,
			props      = props,
			range      = range_at(&p.tracker, start, p.pos),
		}, true
	}

	kw_start := p.pos
	for p.pos < len(p.src) && (is_alpha(p.src[p.pos]) || is_digit(p.src[p.pos]) || p.src[p.pos] == '_') {
		p.pos += 1
	}
	kw := p.src[kw_start:p.pos]

	if kw == "if" || kw == "switch" || kw == "case" {
		skip_ws(p)
		expr := ""
		if p.pos < len(p.src) && p.src[p.pos] == '(' {
			p.pos += 1
			e_start := p.pos
			depth := 1
			for p.pos < len(p.src) && depth > 0 {
				if p.src[p.pos] == '(' do depth += 1
				else if p.src[p.pos] == ')' do depth -= 1
				if depth > 0 do p.pos += 1
			}
			expr = strings.trim_space(p.src[e_start:p.pos])
			if p.pos < len(p.src) && p.src[p.pos] == ')' do p.pos += 1
		}
		skip_ws(p)
		children := parse_braced_block(p)
		k: Node_Kind = .If if kw == "if" else (.Switch if kw == "switch" else .Case)
		return Ast_Node{
			kind     = k,
			expr     = expr,
			children = children,
			range    = range_at(&p.tracker, start, p.pos),
		}, true
	} else if kw == "else" {
		skip_ws(p)
		if strings.has_prefix(p.src[p.pos:], "if") {
			p.pos += 2
			skip_ws(p)
			expr := ""
			if p.pos < len(p.src) && p.src[p.pos] == '(' {
				p.pos += 1
				e_start := p.pos
				depth := 1
				for p.pos < len(p.src) && depth > 0 {
					if p.src[p.pos] == '(' do depth += 1
					else if p.src[p.pos] == ')' do depth -= 1
					if depth > 0 do p.pos += 1
				}
				expr = strings.trim_space(p.src[e_start:p.pos])
				if p.pos < len(p.src) && p.src[p.pos] == ')' do p.pos += 1
			}
			skip_ws(p)
			children := parse_braced_block(p)
			return Ast_Node{
				kind     = .If,
				expr     = expr,
				children = children,
				range    = range_at(&p.tracker, start, p.pos),
			}, true
		} else {
			children := parse_braced_block(p)
			return Ast_Node{
				kind     = .If,
				children = children,
				range    = range_at(&p.tracker, start, p.pos),
			}, true
		}
	} else if kw == "foreach" || kw == "for" {
		skip_ws(p)
		h_start := p.pos
		for p.pos < len(p.src) && p.src[p.pos] != '{' {
			p.pos += 1
		}
		hdr := strings.trim_space(p.src[h_start:p.pos])
		loop_var := hdr
		loop_in := ""
		if in_idx := strings.index(hdr, " in "); in_idx >= 0 {
			loop_var = strings.trim_space(hdr[:in_idx])
			loop_in = strings.trim_space(hdr[in_idx + 4:])
		}
		children := parse_braced_block(p)
		return Ast_Node{
			kind     = .Foreach if kw == "foreach" else .For,
			loop_var = loop_var,
			loop_in  = loop_in,
			children = children,
			range    = range_at(&p.tracker, start, p.pos),
		}, true
	} else if kw == "default" {
		skip_ws(p)
		children := parse_braced_block(p)
		return Ast_Node{
			kind     = .Case,
			children = children,
			range    = range_at(&p.tracker, start, p.pos),
		}, true
	}

	return Ast_Node{}, false
}

parse_braced_block :: proc(p: ^Parser) -> [dynamic]Ast_Node {
	skip_ws(p)
	if p.pos < len(p.src) && p.src[p.pos] == '{' {
		b_start := p.pos
		p.pos += 1 // '{'
		children := parse_nodes(p, '}')
		if p.pos < len(p.src) && p.src[p.pos] == '}' {
			p.pos += 1
		} else {
			append(&p.diagnostics, Diagnostic{
				range    = range_at(&p.tracker, b_start, p.pos),
				severity = .Error,
				message  = "Unclosed block, expected '}'",
				source   = "odhtml",
			})
		}
		return children
	}
	return make([dynamic]Ast_Node)
}

parse_interpolation :: proc(p: ^Parser) -> (Ast_Node, bool) {
	start := p.pos
	p.pos += 1 // '{'
	e_start := p.pos

	depth := 1
	for p.pos < len(p.src) && depth > 0 {
		c := p.src[p.pos]
		if c == '{' do depth += 1
		else if c == '}' do depth -= 1
		if depth > 0 do p.pos += 1
	}

	expr := strings.trim_space(p.src[e_start:p.pos])
	if p.pos < len(p.src) && p.src[p.pos] == '}' {
		p.pos += 1
	} else {
		append(&p.diagnostics, Diagnostic{
			range    = range_at(&p.tracker, start, p.pos),
			severity = .Error,
			message  = "Unclosed interpolation, expected '}'",
			source   = "odhtml",
		})
	}

	if strings.has_prefix(expr, "slot") {
		return Ast_Node{
			kind  = .Slot,
			name  = expr,
			range = range_at(&p.tracker, start, p.pos),
		}, true
	}

	return Ast_Node{
		kind  = .Interpolation,
		expr  = expr,
		range = range_at(&p.tracker, start, p.pos),
	}, true
}

parse_html_tag :: proc(p: ^Parser) -> (Ast_Node, bool) {
	start := p.pos
	p.pos += 1 // '<'

	if strings.has_prefix(p.src[p.pos:], "!--") {
		p.pos += 3
		idx := strings.index(p.src[p.pos:], "-->")
		p.pos = p.pos + idx + 3 if idx >= 0 else len(p.src)
		return Ast_Node{
			kind     = .Text,
			raw_text = p.src[start:p.pos],
			range    = range_at(&p.tracker, start, p.pos),
		}, true
	}

	if p.pos < len(p.src) && p.src[p.pos] == '/' do p.pos += 1

	n_start := p.pos
	for p.pos < len(p.src) && (is_alpha(p.src[p.pos]) || is_digit(p.src[p.pos]) || p.src[p.pos] == '-' || p.src[p.pos] == '_') {
		p.pos += 1
	}
	tag_name := p.src[n_start:p.pos]

	for p.pos < len(p.src) && p.src[p.pos] != '>' {
		if p.src[p.pos] == '"' || p.src[p.pos] == '\'' {
			q := p.src[p.pos]
			p.pos += 1
			for p.pos < len(p.src) && p.src[p.pos] != q {
				if p.src[p.pos] == '\\' && p.pos + 1 < len(p.src) do p.pos += 1
				p.pos += 1
			}
			if p.pos < len(p.src) do p.pos += 1
		} else {
			p.pos += 1
		}
	}

	if p.pos < len(p.src) && p.src[p.pos] == '>' do p.pos += 1

	return Ast_Node{
		kind  = .Tag,
		name  = tag_name,
		range = range_at(&p.tracker, start, p.pos),
	}, true
}

is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

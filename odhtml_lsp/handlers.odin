package odhtml_lsp

import "core:fmt"
import "core:slice"
import "core:strings"

json_escape :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case:      strings.write_byte(b, c)
		}
	}
}

is_inside_range :: proc(pos: Position, r: Range) -> bool {
	if pos.line < r.start.line || pos.line > r.end.line do return false
	if pos.line == r.start.line && pos.character < r.start.character do return false
	if pos.line == r.end.line && pos.character > r.end.character do return false
	return true
}

build_diagnostics_json :: proc(uri: string, diagnostics: []Diagnostic, comp_calls: []Ast_Node, idx: ^Indexer) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"uri\":\"")
	json_escape(&b, uri)
	strings.write_string(&b, "\",\"diagnostics\":[")

	first := true
	emit_diag :: proc(b: ^strings.Builder, first: ^bool, r: Range, sev: Diagnostic_Severity, msg: string) {
		if !first^ do strings.write_byte(b, ',')
		first^ = false
		strings.write_string(b, "{\"range\":{\"start\":{\"line\":")
		fmt.sbprint(b, r.start.line)
		strings.write_string(b, ",\"character\":")
		fmt.sbprint(b, r.start.character)
		strings.write_string(b, "},\"end\":{\"line\":")
		fmt.sbprint(b, r.end.line)
		strings.write_string(b, ",\"character\":")
		fmt.sbprint(b, r.end.character)
		strings.write_string(b, "}},\"severity\":")
		fmt.sbprint(b, int(sev))
		strings.write_string(b, ",\"source\":\"odhtml\",\"message\":\"")
		json_escape(b, msg)
		strings.write_string(b, "\"}")
	}

	for d in diagnostics {
		emit_diag(&b, &first, d.range, d.severity, d.message)
	}

	for call in comp_calls {
		if len(call.name) == 0 do continue
		comp, ok := indexer_get_component(idx, call.name)
		if !ok {
			msg := fmt.tprintf("Component '@%s' could not be resolved. No matching .odhtml template found.", call.name)
			emit_diag(&b, &first, call.range, .Warning, msg)
			continue
		}

		// Check unknown props
		for p in call.props {
			found := false
			for dp in comp.props {
				if dp.name == p.name {
					found = true
					break
				}
			}
			if !found {
				msg := fmt.tprintf("Unknown prop '%s' passed to component '@%s'.", p.name, comp.pascal_name)
				emit_diag(&b, &first, p.name_range, .Warning, msg)
			}
		}

		// Check required props
		for dp in comp.props {
			if dp.is_required {
				passed := false
				for p in call.props {
					if p.name == dp.name {
						passed = true
						break
					}
				}
				if !passed {
					msg := fmt.tprintf("Component '@%s' is missing required prop '%s: %s'.", comp.pascal_name, dp.name, dp.type_name)
					emit_diag(&b, &first, call.range, .Warning, msg)
				}
			}
		}
	}

	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

handle_hover :: proc(src: string, pos: Position, idx: ^Indexer) -> string {
	res := parse_template(src)
	defer parse_result_destroy(&res)

	// 1. Props in header
	for pr in res.props {
		if is_inside_range(pos, pr.range) {
			b := strings.builder_make()
			def_str := fmt.tprintf(" = %s", pr.default_value) if len(pr.default_value) > 0 else " (required)"
			md := fmt.tprintf("```odin\n(prop) %s: %s%s\n```\nDeclared in `@props` of this template.", pr.name, pr.type_name, def_str)
			strings.write_string(&b, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"")
			json_escape(&b, md)
			strings.write_string(&b, "\"}}")
			return strings.to_string(b)
		}
	}

	// 2. Component calls
	for call in res.component_calls {
		if len(call.name) == 0 do continue

		// Check prop args
		for p in call.props {
			if is_inside_range(pos, p.name_range) {
				comp, ok := indexer_get_component(idx, call.name)
				type_str := ""
				def_str := ""
				if ok {
					for dp in comp.props {
						if dp.name == p.name {
							type_str = fmt.tprintf(": %s", dp.type_name)
							if len(dp.default_value) > 0 do def_str = fmt.tprintf(" = %s", dp.default_value)
							break
						}
					}
				}
				md := fmt.tprintf("```odin\n(prop) %s%s%s\n```\nArgument for `@%s`", p.name, type_str, def_str, call.name)
				b := strings.builder_make()
				strings.write_string(&b, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"")
				json_escape(&b, md)
				strings.write_string(&b, "\"}}")
				return strings.to_string(b)
			}
		}

		if is_inside_range(pos, call.range) {
			comp, ok := indexer_get_component(idx, call.name)
			if ok {
				b_md := strings.builder_make()
				fmt.sbprintf(&b_md, "### Component `@%s`\\n\\n", comp.pascal_name)
				fmt.sbprintf(&b_md, "*File:* `%s`\\n\\n", comp.file_path)

				if len(comp.props) > 0 {
					strings.write_string(&b_md, "**Declared Props:**\\n\\n")
					strings.write_string(&b_md, "| Prop | Type | Default | Required |\\n")
					strings.write_string(&b_md, "| :--- | :--- | :--- | :--- |\\n")
					for dp in comp.props {
						def_val := fmt.tprintf("`%s`", dp.default_value) if len(dp.default_value) > 0 else "*-*"
						req_val := "**Yes**" if dp.is_required else "No"
						fmt.sbprintf(&b_md, "| `%s` | `%s` | %s | %s |\\n", dp.name, dp.type_name, def_val, req_val)
					}
				} else {
					strings.write_string(&b_md, "*No props declared.*\\n")
				}

				if len(comp.slot_names) > 0 {
					strings.write_string(&b_md, "\\n**Slots:** `")
					for sn, i in comp.slot_names {
						if i > 0 do strings.write_string(&b_md, "`, `")
						strings.write_string(&b_md, sn)
					}
					strings.write_string(&b_md, "`\\n")
				}

				md := strings.to_string(b_md)
				b := strings.builder_make()
				strings.write_string(&b, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"")
				strings.write_string(&b, md)
				strings.write_string(&b, "\"}}")
				return strings.to_string(b)
			}
		}
	}

	return "null"
}

handle_completion :: proc(src: string, pos: Position, idx: ^Indexer) -> string {
	lines := strings.split_lines(src)
	defer delete(lines)

	line_text := lines[pos.line] if pos.line < len(lines) else ""
	prefix := line_text[:min(pos.character, len(line_text))]

	b := strings.builder_make()
	strings.write_string(&b, "[")

	first := true
	emit_comp :: proc(b: ^strings.Builder, first: ^bool, label: string, kind: int, detail: string, insert_text: string, is_snippet: bool = false) {
		if !first^ do strings.write_byte(b, ',')
		first^ = false
		strings.write_string(b, "{\"label\":\"")
		json_escape(b, label)
		strings.write_string(b, "\",\"kind\":")
		fmt.sbprint(b, kind)
		strings.write_string(b, ",\"detail\":\"")
		json_escape(b, detail)
		strings.write_string(b, "\",\"insertText\":\"")
		json_escape(b, insert_text)
		if is_snippet {
			strings.write_string(b, "\",\"insertTextFormat\":2}")
		} else {
			strings.write_string(b, "\"}")
		}
	}

	// Inside component call arguments: @ComponentName(
	if at_idx := strings.last_index(prefix, "@"); at_idx >= 0 {
		paren_idx := strings.last_index(prefix, "(")
		if paren_idx > at_idx {
			comp_name := strings.trim_space(prefix[at_idx + 1:paren_idx])
			if comp, ok := indexer_get_component(idx, comp_name); ok {
				for pr in comp.props {
					arg_snippet := fmt.tprintf("%s: ${1:%s}", pr.name, pr.name)
					emit_comp(&b, &first, fmt.tprintf("%s:", pr.name), 10, pr.type_name, arg_snippet, true)
				}
				strings.write_string(&b, "]")
				return strings.to_string(b)
			}
		}
	}

	// Inside interpolation: {
	if brace_idx := strings.last_index(prefix, "{"); brace_idx >= 0 && strings.last_index(prefix, "}") < brace_idx {
		res := parse_template(src)
		for pr in res.props {
			emit_comp(&b, &first, pr.name, 6, fmt.tprintf("(prop) %s", pr.type_name), pr.name)
		}
		emit_comp(&b, &first, "slot", 15, "Default slot", "slot")
		emit_comp(&b, &first, "slot:name", 15, "Named slot", "slot:${1:name}", true)
		emit_comp(&b, &first, "len", 3, "Length builtin", "len(${1:items})", true)
		strings.write_string(&b, "]")
		return strings.to_string(b)
	}

	// Directives and components trigger with @
	if strings.has_suffix(prefix, "@") || strings.last_index(prefix, "@") >= 0 {
		emit_comp(&b, &first, "@props", 14, "Define template props", "props(${1:title: string = \"\"})", true)
		emit_comp(&b, &first, "@import", 14, "Import package", "import \"${1:core:fmt}\"", true)
		emit_comp(&b, &first, "@if", 14, "If condition", "if (${1:condition}) {\n\t$0\n}", true)
		emit_comp(&b, &first, "@else", 14, "Else block", "else {\n\t$0\n}", true)
		emit_comp(&b, &first, "@else if", 14, "Else if block", "else if (${1:condition}) {\n\t$0\n}", true)
		emit_comp(&b, &first, "@foreach", 14, "Collection loop", "foreach ${1:item}, ${2:idx} in ${3:items} {\n\t$0\n}", true)
		emit_comp(&b, &first, "@for", 14, "Range loop", "for ${1:i} in 0..<${2:count} {\n\t$0\n}", true)
		emit_comp(&b, &first, "@switch", 14, "Switch block", "switch (${1:value}) {\n\t@case (${2:val}) {\n\t\t$0\n\t}\n\t@default {}\n}", true)

		for _, comp in idx.components_by_pascal {
			req_props := make([dynamic]string)
			for pr in comp.props {
				if pr.is_required {
					append(&req_props, pr.name)
				}
			}
			snippet_args := ""
			if len(req_props) > 0 {
				sb := strings.builder_make()
				for rp, i in req_props {
					if i > 0 do strings.write_string(&sb, ", ")
					fmt.sbprintf(&sb, "%s: ${%d:%s}", rp, i + 1, rp)
				}
				snippet_args = strings.to_string(sb)
			}
			call_snip := fmt.tprintf("%s(%s)", comp.pascal_name, snippet_args)
			emit_comp(&b, &first, fmt.tprintf("@%s", comp.pascal_name), 7, fmt.tprintf("Component (%s)", comp.pascal_name), call_snip, true)
		}
	}

	// Tags trigger with <
	if strings.has_suffix(prefix, "<") {
		emit_comp(&b, &first, "slot", 15, "Slot tag", "slot>$1</slot>", true)
		emit_comp(&b, &first, "slot:named", 15, "Named slot tag", "slot:${1:name}>$2</slot:${1:name}>", true)

		for _, comp in idx.components_by_pascal {
			tag_snip := fmt.tprintf("%s $1>$2</%s>", comp.pascal_name, comp.pascal_name)
			emit_comp(&b, &first, comp.pascal_name, 7, fmt.tprintf("Component tag <%s>", comp.pascal_name), tag_snip, true)
		}
	}

	strings.write_string(&b, "]")
	return strings.to_string(b)
}

build_location_json :: proc(uri: string, s_line, s_col, e_line, e_col: int) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"uri\":\"")
	strings.write_string(&b, uri)
	strings.write_string(&b, "\",\"range\":{\"start\":{\"line\":")
	fmt.sbprint(&b, s_line)
	strings.write_string(&b, ",\"character\":")
	fmt.sbprint(&b, s_col)
	strings.write_string(&b, "},\"end\":{\"line\":")
	fmt.sbprint(&b, e_line)
	strings.write_string(&b, ",\"character\":")
	fmt.sbprint(&b, e_col)
	strings.write_string(&b, "}}}")
	return strings.to_string(b)
}

handle_definition :: proc(src: string, pos: Position, idx: ^Indexer, current_uri: string) -> string {
	res := parse_template(src)
	defer parse_result_destroy(&res)

	// 1. Check component calls
	for call in res.component_calls {
		// Check if pos is on a prop name argument e.g. @BookCard(show_price: ...)
		for p in call.props {
			if is_inside_range(pos, p.name_range) {
				if comp, ok := indexer_get_component(idx, call.name); ok {
					for dp in comp.props {
						if dp.name == p.name {
							return build_location_json(comp.uri, dp.name_range.start.line, dp.name_range.start.character, dp.name_range.end.line, dp.name_range.end.character)
						}
					}
					// If prop not found in component props, jump to component file start
					return build_location_json(comp.uri, 0, 0, 0, 0)
				}
			}
		}

		// Check if pos is on the component name e.g. @BookCard or <BookCard
		if is_inside_range(pos, call.name_range) {
			if comp, ok := indexer_get_component(idx, call.name); ok {
				return build_location_json(comp.uri, 0, 0, 0, 0)
			}
		}
	}

	// 2. Check word under cursor
	lines := strings.split_lines(src)
	defer delete(lines)
	if pos.line < len(lines) {
		line := lines[pos.line]
		col := min(pos.character, len(line))
		w_start := col
		for w_start > 0 && (is_alpha(line[w_start - 1]) || is_digit(line[w_start - 1]) || line[w_start - 1] == '_') {
			w_start -= 1
		}
		w_end := col
		for w_end < len(line) && (is_alpha(line[w_end]) || is_digit(line[w_end]) || line[w_end] == '_') {
			w_end += 1
		}
		if w_end > w_start {
			word := line[w_start:w_end]

			// Check if word matches a declared prop in current template
			for pr in res.props {
				if pr.name == word {
					return build_location_json(current_uri, pr.name_range.start.line, pr.name_range.start.character, pr.name_range.end.line, pr.name_range.end.character)
				}
			}

			// Check if word matches a component name in workspace
			if comp, ok := indexer_get_component(idx, word); ok {
				return build_location_json(comp.uri, 0, 0, 0, 0)
			}

			// Check if word matches an Odin symbol in the package's .odin files (e.g. Book :: struct or fields)
			template_path := uri_to_path(current_uri)
			if odin_file, o_line, o_col, ok := find_odin_symbol_location(template_path, word); ok {
				defer delete(odin_file)
				return build_location_json(path_to_uri(odin_file), o_line, o_col, o_line, o_col + len(word))
			}
		}
	}

	return "null"
}

handle_document_symbol :: proc(src: string) -> string {
	res := parse_template(src)
	defer parse_result_destroy(&res)

	b := strings.builder_make()
	strings.write_string(&b, "[")
	first := true

	if len(res.props) > 0 {
		first = false
		p0 := res.props[0].range
		p_last := res.props[len(res.props) - 1].range
		strings.write_string(&b, "{\"name\":\"@props\",\"detail\":\"")
		fmt.sbprint(&b, len(res.props))
		strings.write_string(&b, " prop(s)\",\"kind\":3,\"range\":{\"start\":{\"line\":")
		fmt.sbprint(&b, p0.start.line)
		strings.write_string(&b, ",\"character\":")
		fmt.sbprint(&b, p0.start.character)
		strings.write_string(&b, "},\"end\":{\"line\":")
		fmt.sbprint(&b, p_last.end.line)
		strings.write_string(&b, ",\"character\":")
		fmt.sbprint(&b, p_last.end.character)
		strings.write_string(&b, "}},\"selectionRange\":{\"start\":{\"line\":")
		fmt.sbprint(&b, p0.start.line)
		strings.write_string(&b, ",\"character\":")
		fmt.sbprint(&b, p0.start.character)
		strings.write_string(&b, "},\"end\":{\"line\":")
		fmt.sbprint(&b, p_last.end.line)
		strings.write_string(&b, ",\"character\":")
		fmt.sbprint(&b, p_last.end.character)
		strings.write_string(&b, "}},\"children\":[")

		for pr, idx in res.props {
			if idx > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, "{\"name\":\"")
			json_escape(&b, pr.name)
			strings.write_string(&b, "\",\"detail\":\"")
			json_escape(&b, pr.type_name)
			strings.write_string(&b, "\",\"kind\":7,\"range\":{\"start\":{\"line\":")
			fmt.sbprint(&b, pr.range.start.line)
			strings.write_string(&b, ",\"character\":")
			fmt.sbprint(&b, pr.range.start.character)
			strings.write_string(&b, "},\"end\":{\"line\":")
			fmt.sbprint(&b, pr.range.end.line)
			strings.write_string(&b, ",\"character\":")
			fmt.sbprint(&b, pr.range.end.character)
			strings.write_string(&b, "}},\"selectionRange\":{\"start\":{\"line\":")
			fmt.sbprint(&b, pr.name_range.start.line)
			strings.write_string(&b, ",\"character\":")
			fmt.sbprint(&b, pr.name_range.start.character)
			strings.write_string(&b, "},\"end\":{\"line\":")
			fmt.sbprint(&b, pr.name_range.end.line)
			strings.write_string(&b, ",\"character\":")
			fmt.sbprint(&b, pr.name_range.end.character)
			strings.write_string(&b, "}}}")
		}
		strings.write_string(&b, "]}")
	}

	for call in res.component_calls {
		if !first do strings.write_byte(&b, ',')
		first = false
		strings.write_string(&b, "{\"name\":\"@")
		json_escape(&b, call.name)
		strings.write_string(&b, "\",\"detail\":\"Component Call\",\"kind\":5,\"range\":{\"start\":{\"line\":")
		fmt.sbprint(&b, call.range.start.line)
		strings.write_string(&b, ",\"character\":")
		fmt.sbprint(&b, call.range.start.character)
		strings.write_string(&b, "},\"end\":{\"line\":")
		fmt.sbprint(&b, call.range.end.line)
		strings.write_string(&b, ",\"character\":")
		fmt.sbprint(&b, call.range.end.character)
		strings.write_string(&b, "}},\"selectionRange\":{\"start\":{\"line\":")
		fmt.sbprint(&b, call.range.start.line)
		strings.write_string(&b, ",\"character\":")
		fmt.sbprint(&b, call.range.start.character)
		strings.write_string(&b, "},\"end\":{\"line\":")
		fmt.sbprint(&b, call.range.end.line)
		strings.write_string(&b, ",\"character\":")
		fmt.sbprint(&b, call.range.end.character)
		strings.write_string(&b, "}}}")
	}

	strings.write_string(&b, "]")
	return strings.to_string(b)
}

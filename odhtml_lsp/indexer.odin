package odhtml_lsp

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Indexer :: struct {
	components_by_pascal: map[string]Component_Info,
	components_by_snake:  map[string]Component_Info,
	file_to_component:    map[string]string,
}

indexer_init :: proc(idx: ^Indexer) {
	idx.components_by_pascal = make(map[string]Component_Info)
	idx.components_by_snake = make(map[string]Component_Info)
	idx.file_to_component = make(map[string]string)
}

indexer_destroy :: proc(idx: ^Indexer) {
	for _, comp in idx.components_by_pascal {
		delete(comp.name)
		delete(comp.pascal_name)
		delete(comp.file_path)
		delete(comp.uri)
		delete(comp.props)
		delete(comp.imports)
		for sn in comp.slot_names do delete(sn)
		delete(comp.slot_names)
	}
	delete(idx.components_by_pascal)
	delete(idx.components_by_snake)
	delete(idx.file_to_component)
}

path_to_uri :: proc(p: string) -> string {
	abs_p, err := filepath.abs(p, context.temp_allocator)
	actual := abs_p if err == os.ERROR_NONE else p

	b := strings.builder_make()
	if strings.has_prefix(actual, "/") {
		strings.write_string(&b, "file://")
	} else {
		strings.write_string(&b, "file:///")
	}
	for i in 0 ..< len(actual) {
		c := actual[i]
		if c == '\\' {
			strings.write_byte(&b, '/')
		} else {
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

uri_to_path :: proc(uri: string) -> string {
	s := uri
	if strings.has_prefix(s, "file:///") {
		s = s[8:]
	} else if strings.has_prefix(s, "file://") {
		s = s[7:]
	}
	// Convert %20 to spaces and %3A to colon
	res, _ := strings.replace_all(s, "%20", " ")
	res, _ = strings.replace_all(res, "%3A", ":")
	res, _ = strings.replace_all(res, "%3a", ":")
	// On Windows, if starts with C:/ keep it
	when ODIN_OS == .Windows {
		// Replace / with \
		win_res, _ := strings.replace_all(res, "/", "\\")
		if len(win_res) >= 3 && (win_res[0] == '\\' || win_res[0] == '/') && win_res[2] == ':' {
			win_res = win_res[1:]
		}
		return win_res
	} else {
		return res
	}
}

indexer_scan_directory :: proc(idx: ^Indexer, dir: string) {
	f, err := os.open(dir)
	if err != os.ERROR_NONE do return
	defer os.close(f)

	fis, read_err := os.read_dir(f, 0, context.temp_allocator)
	if read_err != os.ERROR_NONE do return

	for fi in fis {
		if fi.type == .Directory {
			if fi.name == ".git" || fi.name == "node_modules" || fi.name == "output" || fi.name == "bin" || fi.name == ".gemini" {
				continue
			}
			sub_path, _ := filepath.join({dir, fi.name}, context.temp_allocator)
			indexer_scan_directory(idx, sub_path)
		} else if strings.has_suffix(fi.name, ".odhtml") {
			full_path, _ := filepath.join({dir, fi.name}, context.temp_allocator)
			indexer_index_file(idx, full_path)
		}
	}
}

indexer_index_file :: proc(idx: ^Indexer, file_path: string, content: string = "") -> bool {
	src := content
	read_from_disk := false
	if len(src) == 0 {
		data, read_err := os.read_entire_file(file_path, context.allocator)
		if read_err != nil do return false
		src = string(data)
		read_from_disk = true
	}
	defer if read_from_disk do delete(src)

	res := parse_template(src)

	base_name := filepath.base(file_path)
	if strings.has_suffix(base_name, ".odhtml") {
		base_name = base_name[:len(base_name) - 7]
	}
	snake := to_snake_case(base_name)
	pascal := to_pascal_case(snake)

	slot_names := make([dynamic]string)
	collect_slots :: proc(nodes: []Ast_Node, slot_names: ^[dynamic]string) {
		for n in nodes {
			if n.kind == .Slot_Block || n.kind == .Slot {
				if len(n.name) > 0 && !slice.contains(slot_names^[:], n.name) {
					append(slot_names, strings.clone(n.name))
				}
			}
			if len(n.children) > 0 {
				collect_slots(n.children[:], slot_names)
			}
		}
	}
	collect_slots(res.nodes[:], &slot_names)

	abs_path, abs_err := filepath.abs(file_path, context.allocator)
	actual_path := abs_path if abs_err == os.ERROR_NONE else strings.clone(file_path)

	comp := Component_Info{
		name        = strings.clone(snake),
		pascal_name = strings.clone(pascal),
		file_path   = actual_path,
		uri         = path_to_uri(actual_path),
		props       = res.props,
		imports     = res.imports,
		slot_names  = slot_names,
	}

	idx.components_by_pascal[pascal] = comp
	idx.components_by_snake[snake] = comp
	idx.file_to_component[file_path] = pascal

	return true
}

indexer_get_component :: proc(idx: ^Indexer, name: string) -> (Component_Info, bool) {
	if comp, ok := idx.components_by_pascal[name]; ok {
		return comp, true
	}
	if comp, ok := idx.components_by_snake[name]; ok {
		return comp, true
	}
	snake := to_snake_case(name)
	if comp, ok := idx.components_by_snake[snake]; ok {
		return comp, true
	}
	pascal := to_pascal_case(name)
	if comp, ok := idx.components_by_pascal[pascal]; ok {
		return comp, true
	}
	return Component_Info{}, false
}

scan_odin_dir_for_symbol :: proc(search_dir: string, symbol: string) -> (string, int, int, bool) {
	if len(search_dir) == 0 do return "", 0, 0, false

	f, err := os.open(search_dir)
	if err != os.ERROR_NONE do return "", 0, 0, false
	defer os.close(f)

	fis, read_err := os.read_dir(f, 0, context.temp_allocator)
	if read_err != os.ERROR_NONE do return "", 0, 0, false

	pattern_decl := fmt.tprintf("%s ::", symbol)
	pattern_field := fmt.tprintf("%s:", symbol)

	field_file := ""
	field_line := 0
	field_col := 0
	found_field := false

	for fi in fis {
		if fi.type != .Directory && strings.has_suffix(fi.name, ".odin") {
			full_odin, _ := filepath.join({search_dir, fi.name}, context.temp_allocator)
			data, r_err := os.read_entire_file(full_odin, context.temp_allocator)
			if r_err != nil do continue
			src := string(data)
			lines := strings.split_lines(src, context.temp_allocator)

			for l, line_idx in lines {
				trimmed := strings.trim_space(l)

				// 1. Direct symbol declaration e.g. "Book :: struct"
				if strings.has_prefix(trimmed, pattern_decl) {
					col := strings.index(l, symbol)
					return strings.clone(full_odin), line_idx, col, true
				}

				// 2. Struct field declaration e.g. "title: string"
				if strings.has_prefix(trimmed, pattern_field) && !found_field {
					col := strings.index(l, symbol)
					field_file = strings.clone(full_odin)
					field_line = line_idx
					field_col = col
					found_field = true
				}
			}
		}
	}

	if found_field {
		return field_file, field_line, field_col, true
	}

	return "", 0, 0, false
}

find_odin_symbol_location :: proc(template_path: string, symbol: string) -> (string, int, int, bool) {
	if len(template_path) == 0 || len(symbol) == 0 do return "", 0, 0, false

	dir := filepath.dir(template_path)
	parent := filepath.dir(dir)

	parent_clean, _ := filepath.clean(parent, context.temp_allocator)
	dir_clean, _ := filepath.clean(dir, context.temp_allocator)

	// Check parent directory first (e.g. odnetclient/books when template is in odnetclient/books/templates)
	if file, line, col, ok := scan_odin_dir_for_symbol(parent_clean, symbol); ok {
		return file, line, col, true
	}

	// Check same directory (if odin files are side-by-side with template)
	if file, line, col, ok := scan_odin_dir_for_symbol(dir_clean, symbol); ok {
		return file, line, col, true
	}

	// Check grandparent directory
	grandparent := filepath.dir(parent_clean)
	grandparent_clean, _ := filepath.clean(grandparent, context.temp_allocator)
	if file, line, col, ok := scan_odin_dir_for_symbol(grandparent_clean, symbol); ok {
		return file, line, col, true
	}

	return "", 0, 0, false
}

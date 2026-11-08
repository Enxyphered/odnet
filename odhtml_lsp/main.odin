package odhtml_lsp

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

send_message :: proc(payload: string) {
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(payload))
	os.write_string(os.stdout, header)
	os.write_string(os.stdout, payload)
}

send_response :: proc(id: json.Value, result_json: string) {
	b := strings.builder_make()
	strings.write_string(&b, "{\"jsonrpc\":\"2.0\",\"id\":")

	switch v in id {
	case json.Integer:
		fmt.sbprintf(&b, "%d", v)
	case json.Float:
		fmt.sbprintf(&b, "%f", v)
	case json.String:
		strings.write_byte(&b, '"')
		json_escape(&b, v)
		strings.write_byte(&b, '"')
	case json.Boolean:
		strings.write_string(&b, "true" if v else "false")
	case json.Null, json.Array, json.Object:
		strings.write_string(&b, "null")
	}

	strings.write_string(&b, ",\"result\":")
	strings.write_string(&b, result_json)
	strings.write_string(&b, "}")

	send_message(strings.to_string(b))
}

send_notification :: proc(method: string, params_json: string) {
	b := strings.builder_make()
	strings.write_string(&b, "{\"jsonrpc\":\"2.0\",\"method\":\"")
	strings.write_string(&b, method)
	strings.write_string(&b, "\",\"params\":")
	strings.write_string(&b, params_json)
	strings.write_string(&b, "}")
	send_message(strings.to_string(b))
}

read_message :: proc(buf: ^[dynamic]u8) -> (string, bool) {
	read_chunk := make([]u8, 4096, context.temp_allocator)

	for {
		// Look for \r\n\r\n in buf
		str := string(buf^[:])
		sep := "\r\n\r\n"
		idx := strings.index(str, sep)
		if idx >= 0 {
			header := str[:idx]
			cl_prefix := "Content-Length: "
			cl_idx := strings.index(header, cl_prefix)
			if cl_idx < 0 do return "", false

			cl_str := strings.trim_space(header[cl_idx + len(cl_prefix):])
			if end_line := strings.index_any(cl_str, "\r\n"); end_line >= 0 {
				cl_str = strings.trim_space(cl_str[:end_line])
			}

			content_len, ok := strconv.parse_int(cl_str)
			if !ok do return "", false

			body_start := idx + 4
			total_needed := body_start + content_len

			for len(buf^) < total_needed {
				n, err := os.read(os.stdin, read_chunk)
				if err != os.ERROR_NONE || n <= 0 {
					return "", false
				}
				for i in 0 ..< n {
					append(buf, read_chunk[i])
				}
			}

			body := string(buf^[body_start:total_needed])
			res := strings.clone(body)

			// Remove consumed message from buffer
			remaining := len(buf^) - total_needed
			if remaining > 0 {
				for i in 0 ..< remaining {
					buf^[i] = buf^[total_needed + i]
				}
				resize(buf, remaining)
			} else {
				clear(buf)
			}

			return res, true
		}

		n, err := os.read(os.stdin, read_chunk)
		if err != os.ERROR_NONE || n <= 0 {
			return "", false
		}
		for i in 0 ..< n {
			append(buf, read_chunk[i])
		}
	}
}

main :: proc() {
	buf := make([dynamic]u8)
	defer delete(buf)

	idx: Indexer
	indexer_init(&idx)

	open_docs := make(map[string]string)
	defer delete(open_docs)

	for {
		msg, ok := read_message(&buf)
		if !ok do break
		defer delete(msg)

		val, parse_err := json.parse_string(msg, json.DEFAULT_SPECIFICATION, true)
		if parse_err != .None do continue
		defer json.destroy_value(val)

		obj, is_obj := val.(json.Object)
		if !is_obj do continue

		method_val, has_method := obj["method"]
		method, is_method_str := method_val.(json.String)
		req_id, has_id := obj["id"]
		params_obj, _ := obj["params"].(json.Object)

		if has_method && is_method_str {
			switch method {
			case "initialize":
				// Discover workspace root
				root_path := "."
				if ws_folders, ok := params_obj["workspaceFolders"].(json.Array); ok && len(ws_folders) > 0 {
					if first_folder, f_ok := ws_folders[0].(json.Object); f_ok {
						if ws_uri, u_ok := first_folder["uri"].(json.String); u_ok {
							root_path = uri_to_path(ws_uri)
						}
					}
				} else if root_uri, ok := params_obj["rootUri"].(json.String); ok && len(root_uri) > 0 {
					root_path = uri_to_path(root_uri)
				}
				indexer_scan_directory(&idx, root_path)

				res := `{
					"capabilities": {
						"textDocumentSync": 1,
						"hoverProvider": true,
						"completionProvider": {
							"triggerCharacters": ["@", "<", "{", ":"]
						},
						"definitionProvider": true,
						"documentSymbolProvider": true
					}
				}`
				send_response(req_id, res)

			case "initialized":
				// Client initialized notification

			case "textDocument/didOpen":
				if doc_obj, ok := params_obj["textDocument"].(json.Object); ok {
					uri, _ := doc_obj["uri"].(json.String)
					text, _ := doc_obj["text"].(json.String)
					open_docs[uri] = strings.clone(text)

					file_path := uri_to_path(uri)
					indexer_index_file(&idx, file_path, text)

					p_res := parse_template(text)
					diag_json := build_diagnostics_json(uri, p_res.diagnostics[:], p_res.component_calls[:], &idx)
					send_notification("textDocument/publishDiagnostics", diag_json)
					delete(diag_json)
				}

			case "textDocument/didChange":
				if doc_obj, ok := params_obj["textDocument"].(json.Object); ok {
					uri, _ := doc_obj["uri"].(json.String)
					if content_changes, ok := params_obj["contentChanges"].(json.Array); ok && len(content_changes) > 0 {
						if first_change, ok := content_changes[0].(json.Object); ok {
							text, _ := first_change["text"].(json.String)
							if old, exists := open_docs[uri]; exists {
								delete(old)
							}
							open_docs[uri] = strings.clone(text)

							file_path := uri_to_path(uri)
							indexer_index_file(&idx, file_path, text)

							p_res := parse_template(text)
							diag_json := build_diagnostics_json(uri, p_res.diagnostics[:], p_res.component_calls[:], &idx)
							send_notification("textDocument/publishDiagnostics", diag_json)
							delete(diag_json)
						}
					}
				}

			case "textDocument/didClose":
				if doc_obj, ok := params_obj["textDocument"].(json.Object); ok {
					uri, _ := doc_obj["uri"].(json.String)
					if old, exists := open_docs[uri]; exists {
						delete(old)
						delete_key(&open_docs, uri)
					}
					b_cd := strings.builder_make()
					strings.write_string(&b_cd, "{\"uri\":\"")
					strings.write_string(&b_cd, uri)
					strings.write_string(&b_cd, "\",\"diagnostics\":[]}")
					clear_diag := strings.to_string(b_cd)
					send_notification("textDocument/publishDiagnostics", clear_diag)
				}

			case "textDocument/hover":
				if doc_obj, ok := params_obj["textDocument"].(json.Object); ok {
					uri, _ := doc_obj["uri"].(json.String)
					pos_obj, _ := params_obj["position"].(json.Object)
					line, _ := pos_obj["line"].(json.Integer)
					char, _ := pos_obj["character"].(json.Integer)

					pos := Position{line = int(line), character = int(char)}
					src := open_docs[uri]
					if len(src) == 0 {
						if data, err := os.read_entire_file(uri_to_path(uri), context.temp_allocator); err == nil {
							src = string(data)
						}
					}
					hover_res := handle_hover(src, pos, &idx)
					send_response(req_id, hover_res)
					if hover_res != "null" do delete(hover_res)
				}

			case "textDocument/completion":
				if doc_obj, ok := params_obj["textDocument"].(json.Object); ok {
					uri, _ := doc_obj["uri"].(json.String)
					pos_obj, _ := params_obj["position"].(json.Object)
					line, _ := pos_obj["line"].(json.Integer)
					char, _ := pos_obj["character"].(json.Integer)

					pos := Position{line = int(line), character = int(char)}
					src := open_docs[uri]
					if len(src) == 0 {
						if data, err := os.read_entire_file(uri_to_path(uri), context.temp_allocator); err == nil {
							src = string(data)
						}
					}
					comp_res := handle_completion(src, pos, &idx)
					send_response(req_id, comp_res)
					delete(comp_res)
				}

			case "textDocument/definition":
				if doc_obj, ok := params_obj["textDocument"].(json.Object); ok {
					uri, _ := doc_obj["uri"].(json.String)
					pos_obj, _ := params_obj["position"].(json.Object)
					line, _ := pos_obj["line"].(json.Integer)
					char, _ := pos_obj["character"].(json.Integer)

					pos := Position{line = int(line), character = int(char)}
					src := open_docs[uri]
					if len(src) == 0 {
						if data, err := os.read_entire_file(uri_to_path(uri), context.temp_allocator); err == nil {
							src = string(data)
						}
					}
					def_res := handle_definition(src, pos, &idx, uri)
					send_response(req_id, def_res)
					if def_res != "null" do delete(def_res)
				}

			case "textDocument/documentSymbol":
				if doc_obj, ok := params_obj["textDocument"].(json.Object); ok {
					uri, _ := doc_obj["uri"].(json.String)
					src := open_docs[uri]
					if len(src) == 0 {
						if data, err := os.read_entire_file(uri_to_path(uri), context.temp_allocator); err == nil {
							src = string(data)
						}
					}
					sym_res := handle_document_symbol(src)
					send_response(req_id, sym_res)
					delete(sym_res)
				}

			case "shutdown":
				send_response(req_id, "null")

			case "exit":
				os.exit(0)
			}
		}
	}
}

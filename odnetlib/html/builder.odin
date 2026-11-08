package odnet_html

import "core:strings"
import http "../"

// Slot callback definition for child component nesting
Slot_Proc :: proc(b: ^strings.Builder, user_data: rawptr = nil)

// Escapes special HTML characters (&, <, >, ", ') into builder
escape_html :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '"':
			strings.write_string(b, "&quot;")
		case '\'':
			strings.write_string(b, "&#39;")
		case:
			strings.write_byte(b, s[i])
		}
	}
}

// Return an escaped HTML string allocated with allocator
escape_string :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	escape_html(&b, s)
	return strings.to_string(b)
}

// Write raw string to builder
write_raw :: proc(b: ^strings.Builder, s: string) {
	strings.write_string(b, s)
}

// Write escaped string to builder
write_escaped :: proc(b: ^strings.Builder, s: string) {
	escape_html(b, s)
}

// Helper to set HTML response with Content-Type text/html; charset=utf-8
response_set_html :: proc(res: ^http.Response, html_str: string) {
	http.response_set_html(res, html_str)
}

package odnetlib

import "core:strings"

Parse_Status :: enum u8 {
	Complete,
	Incomplete,
	Error,
}

// Fast ASCII lowercase comparison without allocation
ascii_equal_case_insensitive :: proc(a: string, b: string) -> bool {
	if len(a) != len(b) do return false
	for i in 0..<len(a) {
		ca := a[i]
		cb := b[i]
		if ca >= 'A' && ca <= 'Z' do ca += 32
		if cb >= 'A' && cb <= 'Z' do cb += 32
		if ca != cb do return false
	}
	return true
}

// Fast ASCII string to integer parser
fast_parse_int :: proc(s: string) -> (int, bool) {
	val := 0
	if len(s) == 0 do return 0, false
	for i in 0..<len(s) {
		c := s[i]
		if c < '0' || c > '9' do return 0, false
		val = val * 10 + int(c - '0')
	}
	return val, true
}

// Zero-copy HTTP/1.1 Request Parser.
// Slices strings directly out of the given socket buffer. Zero allocations.
parse_request :: proc(buf: []u8, req: ^Request) -> (bytes_consumed: int, status: Parse_Status) {
	n := len(buf)
	if n < 4 do return 0, .Incomplete

	// 1. Locate the end of HTTP headers: "\r\n\r\n" or "\n\n"
	header_end := -1
	header_end_len := 0

	for i := 0; i < n - 1; i += 1 {
		if buf[i] == '\r' && i + 3 < n && buf[i+1] == '\n' && buf[i+2] == '\r' && buf[i+3] == '\n' {
			header_end = i
			header_end_len = 4
			break
		}
		if buf[i] == '\n' && buf[i+1] == '\n' {
			header_end = i
			header_end_len = 2
			break
		}
	}

	if header_end == -1 {
		if n > 8192 do return 0, .Error
		return 0, .Incomplete
	}

	// 2. Parse Request-Line: METHOD SP URI SP HTTP/VERSION CRLF
	cursor := 0

	// Skip leading empty lines if any (RFC 9112 section 2.2)
	for cursor < header_end && (buf[cursor] == '\r' || buf[cursor] == '\n') {
		cursor += 1
	}

	// Parse Method
	method_start := cursor
	for cursor < header_end && buf[cursor] != ' ' {
		cursor += 1
	}
	if cursor >= header_end do return 0, .Error
	raw_method := string(buf[method_start:cursor])
	req.raw_method = raw_method
	req.method = method_from_string(raw_method)
	cursor += 1 // Skip space

	// Parse URI
	uri_start := cursor
	for cursor < header_end && buf[cursor] != ' ' {
		cursor += 1
	}
	if cursor >= header_end do return 0, .Error
	raw_uri := string(buf[uri_start:cursor])
	req.uri = raw_uri
	cursor += 1 // Skip space

	// Split URI into path and query
	query_idx := strings.index_byte(raw_uri, '?')
	if query_idx >= 0 {
		req.path = raw_uri[:query_idx]
		req.query = raw_uri[query_idx+1:]
	} else {
		req.path = raw_uri
		req.query = ""
	}

	// Parse HTTP Version
	version_start := cursor
	for cursor < header_end && buf[cursor] != '\r' && buf[cursor] != '\n' {
		cursor += 1
	}
	version_str := string(buf[version_start:cursor])
	if strings.has_prefix(version_str, "HTTP/1.1") {
		req.version_minor = 1
		req.keep_alive = true // Default keep-alive in HTTP/1.1
	} else if strings.has_prefix(version_str, "HTTP/1.0") {
		req.version_minor = 0
		req.keep_alive = false
	} else {
		req.version_minor = 1
		req.keep_alive = true
	}

	// Skip past CRLF after Request-Line
	if cursor < header_end && buf[cursor] == '\r' do cursor += 1
	if cursor < header_end && buf[cursor] == '\n' do cursor += 1

	// 3. Parse Headers
	req.num_headers = 0
	req.num_params = 0
	req.content_length = 0

	for cursor < header_end {
		h_name_start := cursor
		for cursor < header_end && buf[cursor] != ':' && buf[cursor] != '\r' && buf[cursor] != '\n' {
			cursor += 1
		}
		if cursor >= header_end || buf[cursor] != ':' do break
		h_name := string(buf[h_name_start:cursor])
		cursor += 1 // Skip ':'

		// Skip optional linear whitespace
		for cursor < header_end && (buf[cursor] == ' ' || buf[cursor] == '\t') {
			cursor += 1
		}

		h_val_start := cursor
		for cursor < header_end && buf[cursor] != '\r' && buf[cursor] != '\n' {
			cursor += 1
		}
		h_val := string(buf[h_val_start:cursor])

		// Skip trailing CRLF
		if cursor < header_end && buf[cursor] == '\r' do cursor += 1
		if cursor < header_end && buf[cursor] == '\n' do cursor += 1

		if req.num_headers < MAX_HEADERS {
			req.headers[req.num_headers] = Header{name = h_name, value = h_val}
			req.num_headers += 1
		}

		if ascii_equal_case_insensitive(h_name, "Content-Length") {
			if cl, ok := fast_parse_int(h_val); ok {
				req.content_length = cl
			}
		} else if ascii_equal_case_insensitive(h_name, "Connection") {
			if ascii_equal_case_insensitive(h_val, "close") {
				req.keep_alive = false
			} else if ascii_equal_case_insensitive(h_val, "keep-alive") {
				req.keep_alive = true
			}
		}
	}

	// 4. Body framing check
	body_start := header_end + header_end_len
	total_expected := body_start + req.content_length

	if n < total_expected {
		return 0, .Incomplete
	}

	req.body = buf[body_start : body_start + req.content_length]
	return total_expected, .Complete
}

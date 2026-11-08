package odnetlib

// Fast integer to ASCII decimal writer
fast_write_int :: proc(buf: []u8, offset: int, val: int) -> int {
	if val == 0 {
		buf[offset] = '0'
		return offset + 1
	}

	temp: [32]u8
	digits := 0
	v := val
	for v > 0 {
		temp[digits] = u8('0' + (v % 10))
		v /= 10
		digits += 1
	}

	cur := offset
	for i := digits - 1; i >= 0; i -= 1 {
		buf[cur] = temp[i]
		cur += 1
	}
	return cur
}

// Fast string copy into byte buffer
fast_write_str :: #force_inline proc(buf: []u8, offset: int, s: string) -> int {
	n := len(s)
	copy(buf[offset : offset + n], transmute([]u8)s)
	return offset + n
}

// Serializes an HTTP/1.1 response into the destination buffer.
serialize_response :: proc(res: ^Response, out_buf: []u8) -> (bytes_written: int, ok: bool) {
	if len(out_buf) < 512 do return 0, false

	cur := 0

	// 1. Status-Line: HTTP/1.1 200 OK\r\n
	cur = fast_write_str(out_buf, cur, "HTTP/1.1 ")
	cur = fast_write_int(out_buf, cur, int(res.status))
	cur = fast_write_str(out_buf, cur, " ")
	cur = fast_write_str(out_buf, cur, status_reason(res.status))
	cur = fast_write_str(out_buf, cur, "\r\n")

	// 2. Server header
	cur = fast_write_str(out_buf, cur, "Server: odnet/1.0\r\n")

	// 3. Date header (cached)
	date_str := update_date_cache()
	cur = fast_write_str(out_buf, cur, "Date: ")
	cur = fast_write_str(out_buf, cur, date_str)
	cur = fast_write_str(out_buf, cur, "\r\n")

	// 4. Content-Type
	if len(res.content_type) > 0 {
		cur = fast_write_str(out_buf, cur, "Content-Type: ")
		cur = fast_write_str(out_buf, cur, res.content_type)
		cur = fast_write_str(out_buf, cur, "\r\n")
	}

	// 5. Content-Length
	body_len := len(res.body)
	cur = fast_write_str(out_buf, cur, "Content-Length: ")
	cur = fast_write_int(out_buf, cur, body_len)
	cur = fast_write_str(out_buf, cur, "\r\n")

	// 6. Connection header
	if res.keep_alive {
		cur = fast_write_str(out_buf, cur, "Connection: keep-alive\r\n")
	} else {
		cur = fast_write_str(out_buf, cur, "Connection: close\r\n")
	}

	// 7. Custom headers
	for i in 0..<res.num_headers {
		h := res.headers[i]
		cur = fast_write_str(out_buf, cur, h.name)
		cur = fast_write_str(out_buf, cur, ": ")
		cur = fast_write_str(out_buf, cur, h.value)
		cur = fast_write_str(out_buf, cur, "\r\n")
	}

	// 8. End of headers
	cur = fast_write_str(out_buf, cur, "\r\n")

	// 9. Append body
	if body_len > 0 {
		if cur + body_len > len(out_buf) {
			return 0, false
		}
		copy(out_buf[cur : cur + body_len], res.body)
		cur += body_len
	}

	return cur, true
}

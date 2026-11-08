package odnetlib

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_mime_lookup :: proc(t: ^testing.T) {
	testing.expect_value(t, mime_lookup("styles.css"), "text/css; charset=utf-8")
	testing.expect_value(t, mime_lookup("index.html"), "text/html; charset=utf-8")
	testing.expect_value(t, mime_lookup("app.js"), "application/javascript; charset=utf-8")
	testing.expect_value(t, mime_lookup("logo.svg"), "image/svg+xml")
	testing.expect_value(t, mime_lookup("image.png"), "image/png")
	testing.expect_value(t, mime_lookup("font.woff2"), "font/woff2")
	testing.expect_value(t, mime_lookup("data.json"), "application/json")
	testing.expect_value(t, mime_lookup("unknown.xyz123"), "application/octet-stream")
}

@(test)
test_clean_relative_path_security :: proc(t: ^testing.T) {
	clean, ok := clean_relative_path("css/Styles.css")
	testing.expect(t, ok, "Expected clean path to be valid")
	testing.expect_value(t, clean, "css/Styles.css")

	_, ok_traversal := clean_relative_path("../../windows/system32/cmd.exe")
	testing.expect(t, !ok_traversal, "Expected directory traversal with .. to be rejected")

	_, ok_drive := clean_relative_path("C:/secret.txt")
	testing.expect(t, !ok_drive, "Expected drive letter to be rejected")
}

@(test)
test_serve_file_caching_and_304 :: proc(t: ^testing.T) {
	defer reset_static_cache()
	test_file := "test_static_file.txt"
	_ = os.write_entire_file(test_file, transmute([]u8)string("initial content"))
	defer os.remove(test_file)

	// 1. Initial request -> 200 OK with ETag, Last-Modified, Cache-Control
	req := Request{method = .GET, path = "/test_static_file.txt"}
	res: Response
	ok := serve_file(&req, &res, test_file)
	testing.expect(t, ok, "serve_file should succeed")
	testing.expect_value(t, res.status, Status_Code.OK)
	testing.expect_value(t, string(res.body), "initial content")

	etag, has_etag := "", false
	last_mod, has_last_mod := "", false
	cache_ctrl, has_cache_ctrl := "", false

	for i in 0 ..< res.num_headers {
		h := res.headers[i]
		if h.name == "ETag" { etag = h.value; has_etag = true }
		if h.name == "Last-Modified" { last_mod = h.value; has_last_mod = true }
		if h.name == "Cache-Control" { cache_ctrl = h.value; has_cache_ctrl = true }
	}

	testing.expect(t, has_etag, "Expected ETag header")
	testing.expect(t, has_last_mod, "Expected Last-Modified header")
	testing.expect(t, has_cache_ctrl, "Expected Cache-Control header")

	// 2. Conditional request with matching If-None-Match -> 304 Not Modified
	req_cached := Request{method = .GET, path = "/test_static_file.txt"}
	req_cached.headers[0] = Header{name = "If-None-Match", value = etag}
	req_cached.num_headers = 1
	res_cached: Response

	ok_cached := serve_file(&req_cached, &res_cached, test_file)
	testing.expect(t, ok_cached, "serve_file should succeed for 304")
	testing.expect_value(t, res_cached.status, Status_Code.Not_Modified)
	testing.expect(t, res_cached.body == nil, "304 body should be empty")

	// 3. Conditional request with matching If-Modified-Since -> 304 Not Modified
	req_ims := Request{method = .GET, path = "/test_static_file.txt"}
	req_ims.headers[0] = Header{name = "If-Modified-Since", value = last_mod}
	req_ims.num_headers = 1
	res_ims: Response

	ok_ims := serve_file(&req_ims, &res_ims, test_file)
	testing.expect(t, ok_ims, "serve_file should succeed for 304 on IMS")
	testing.expect_value(t, res_ims.status, Status_Code.Not_Modified)

	// 4. File updated on disk -> server detects change and serves new 200 OK
	_ = os.write_entire_file(test_file, transmute([]u8)string("updated content v2"))

	req_after_update := Request{method = .GET, path = "/test_static_file.txt"}
	req_after_update.headers[0] = Header{name = "If-None-Match", value = etag} // sends OLD etag
	req_after_update.num_headers = 1
	res_after_update: Response

	ok_after := serve_file(&req_after_update, &res_after_update, test_file)
	testing.expect(t, ok_after, "serve_file should succeed after update")
	testing.expect_value(t, res_after_update.status, Status_Code.OK)
	testing.expect_value(t, string(res_after_update.body), "updated content v2")
}

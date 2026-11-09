package odnetlib

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

Static_Options :: struct {
	max_age_seconds: int,
	immutable:       bool,
	index_file:      string,
}

DEFAULT_STATIC_OPTIONS :: Static_Options{
	max_age_seconds = 3600,
	immutable       = false,
	index_file      = "index.html",
}

MAX_STATIC_MOUNTS :: 8
MAX_CACHED_FILES  :: 128

Static_Mount :: struct {
	route_prefix: string,
	fs_dir:       string,
	options:      Static_Options,
}

Cached_File :: struct {
	path:          string,
	content:       []u8,
	content_type:  string,
	etag:          string,
	last_mod_str:  string,
	mod_time:      time.Time,
	size:          i64,
	cache_version: u64,
	valid:         bool,
}

Static_Cache :: struct {
	files:         [MAX_CACHED_FILES]Cached_File,
	num_files:     int,
	version:       u64,
	mutex:         sync.Mutex,
}

global_static_cache: Static_Cache

// Clean and validate relative file path to prevent directory traversal attacks
clean_relative_path :: proc(rel: string) -> (string, bool) {
	s := rel
	for len(s) > 0 && (s[0] == '/' || s[0] == '\\') {
		s = s[1:]
	}

	// Reject directory traversal
	if strings.contains(s, "..") {
		return "", false
	}
	// Reject Windows volume letters or root slashes
	if strings.contains(s, ":") {
		return "", false
	}
	// Reject null bytes
	if strings.contains_rune(s, 0) {
		return "", false
	}

	return s, true
}

// Serve a static file from disk or in-memory cache with full HTTP/1.1 cache headers
serve_file :: proc(req: ^Request, res: ^Response, file_path: string, options := DEFAULT_STATIC_OPTIONS) -> bool {
	target_path := file_path
	if os.is_dir(file_path) {
		if len(options.index_file) == 0 do return false
		index_path, _ := filepath.join({file_path, options.index_file}, context.temp_allocator)
		if !os.exists(index_path) || os.is_dir(index_path) do return false
		target_path = index_path
	}

	fi, stat_err := os.stat(target_path, context.temp_allocator)
	if stat_err != nil {
		return false
	}

	sync.lock(&global_static_cache.mutex)
	defer sync.unlock(&global_static_cache.mutex)

	// Look up in cache
	cached_idx := -1
	for i in 0 ..< global_static_cache.num_files {
		if global_static_cache.files[i].path == target_path {
			cached_idx = i
			break
		}
	}

	is_dirty := false
	if cached_idx >= 0 {
		entry := &global_static_cache.files[cached_idx]
		if !entry.valid || entry.size != fi.size || time.diff(entry.mod_time, fi.modification_time) != 0 || entry.cache_version < global_static_cache.version {
			is_dirty = true
		}
	} else {
		is_dirty = true
	}

	if is_dirty {
		data, read_err := os.read_entire_file(target_path, context.allocator)
		if read_err != nil {
			return false
		}

		content_type := mime_lookup(target_path)
		etag := fmt.aprintf("\"%x-%x\"", fi.size, time.to_unix_nanoseconds(fi.modification_time))

		date_buf: [32]u8
		last_mod := format_http_date_time(fi.modification_time, date_buf[:])
		last_mod_str := strings.clone(last_mod)

		if cached_idx < 0 {
			if global_static_cache.num_files < MAX_CACHED_FILES {
				cached_idx = global_static_cache.num_files
				global_static_cache.num_files += 1
			} else {
				cached_idx = 0 // LRU / wrap around
			}
		}

		entry := &global_static_cache.files[cached_idx]
		if entry.content != nil do delete(entry.content)
		if len(entry.path) > 0 do delete(entry.path)
		if len(entry.etag) > 0 do delete(entry.etag)
		if len(entry.last_mod_str) > 0 do delete(entry.last_mod_str)

		entry.path = strings.clone(target_path)
		entry.content = data
		entry.content_type = content_type
		entry.etag = etag
		entry.last_mod_str = last_mod_str
		entry.mod_time = fi.modification_time
		entry.size = fi.size
		entry.cache_version = global_static_cache.version
		entry.valid = true
	}

	entry := &global_static_cache.files[cached_idx]

	// HTTP/1.1 Cache Headers
	response_add_header(res, "ETag", entry.etag)
	response_add_header(res, "Last-Modified", entry.last_mod_str)

	cache_val: string
	if options.immutable {
		cache_val = fmt.tprintf("public, max-age=%d, immutable", options.max_age_seconds)
	} else {
		cache_val = fmt.tprintf("public, max-age=%d", options.max_age_seconds)
	}
	response_add_header(res, "Cache-Control", cache_val)

	// HTTP/1.1 Conditional Cache validation (304 Not Modified)
	if inm, ok := get_header(req, "If-None-Match"); ok {
		if inm == entry.etag || inm == "*" {
			res.status = .Not_Modified
			res.content_type = entry.content_type
			res.body = nil
			return true
		}
	}

	if ims, ok := get_header(req, "If-Modified-Since"); ok {
		if ims == entry.last_mod_str {
			res.status = .Not_Modified
			res.content_type = entry.content_type
			res.body = nil
			return true
		}
	}

	if req.method == .HEAD {
		res.status = .OK
		res.content_type = entry.content_type
		res.body = nil
		return true
	}

	res.status = .OK
	response_set_body(res, entry.content, entry.content_type)
	return true
}

// Register a static mount on Router
router_add_static_mount :: proc(r: ^Router, route_prefix: string, fs_dir: string, options := DEFAULT_STATIC_OPTIONS) -> bool {
	if r.num_static_mounts >= MAX_STATIC_MOUNTS {
		fmt.eprintln("[odnetlib] ERROR: Maximum static mount limit reached:", MAX_STATIC_MOUNTS)
		return false
	}

	clean_prefix := route_prefix
	if len(clean_prefix) > 1 && strings.has_suffix(clean_prefix, "/") {
		clean_prefix = clean_prefix[:len(clean_prefix) - 1]
	}

	mount := Static_Mount{
		route_prefix = strings.clone(clean_prefix),
		fs_dir       = strings.clone(fs_dir),
		options      = options,
	}

	r.static_mounts[r.num_static_mounts] = mount
	r.num_static_mounts += 1

	// Spawn OS file watcher for real-time change detection
	start_static_mount_watcher(&r.static_mounts[r.num_static_mounts - 1])

	return true
}

// Register a static directory on Server (e.g. s, "/static", "odnetdemo/static")
server_static :: proc(s: ^Server, route_prefix: string, fs_dir: string, options := DEFAULT_STATIC_OPTIONS) -> bool {
	return router_add_static_mount(&s.router, route_prefix, fs_dir, options)
}

// Clear all cached files and reset the static cache (useful for clean teardown and unit tests)
reset_static_cache :: proc() {
	sync.lock(&global_static_cache.mutex)
	defer sync.unlock(&global_static_cache.mutex)
	for i in 0 ..< global_static_cache.num_files {
		entry := &global_static_cache.files[i]
		if entry.content != nil do delete(entry.content)
		if len(entry.path) > 0 do delete(entry.path)
		if len(entry.etag) > 0 do delete(entry.etag)
		if len(entry.last_mod_str) > 0 do delete(entry.last_mod_str)
		entry^ = {}
	}
	global_static_cache.num_files = 0
	global_static_cache.version = 0
}

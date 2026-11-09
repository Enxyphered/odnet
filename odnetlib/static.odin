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
	in_memory:       bool, // When true, all files under this mount are loaded into memory and served without per-request disk stats
}

DEFAULT_STATIC_OPTIONS :: Static_Options{
	max_age_seconds = 3600,
	immutable       = false,
	index_file      = "index.html",
	in_memory       = false,
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
	in_memory:     bool,
}

Static_Cache :: struct {
	files:         [MAX_CACHED_FILES]Cached_File,
	num_files:     int,
	version:       u64,
	rw_lock:       sync.RW_Mutex,
}

global_static_cache: Static_Cache

// Normalize relative static paths to consistent forward slashes without leading ./
normalize_static_path :: proc(p: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(p) {
		if p[i] == '\\' {
			strings.write_byte(&b, '/')
		} else {
			strings.write_byte(&b, p[i])
		}
	}
	res := strings.to_string(b)
	if strings.has_prefix(res, "./") {
		res = res[2:]
	}
	return res
}

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

// Internal helper to load/update a file into the static cache (caller must hold write lock)
static_cache_load_file_internal :: proc(file_path: string, in_mem: bool) -> bool {
	norm_target := normalize_static_path(file_path)

	fi, stat_err := os.stat(file_path, context.temp_allocator)
	if stat_err != nil {
		return false
	}
	if fi.type == .Directory do return false

	data, read_err := os.read_entire_file(file_path, context.allocator)
	if read_err != nil {
		return false
	}

	content_type := mime_lookup(file_path)
	etag := fmt.aprintf("\"%x-%x\"", fi.size, time.to_unix_nanoseconds(fi.modification_time))

	date_buf: [32]u8
	last_mod := format_http_date_time(fi.modification_time, date_buf[:])
	last_mod_str := strings.clone(last_mod)

	cached_idx := -1
	for i in 0 ..< global_static_cache.num_files {
		if global_static_cache.files[i].path == norm_target {
			cached_idx = i
			break
		}
	}

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

	entry.path = strings.clone(norm_target)
	entry.content = data
	entry.content_type = content_type
	entry.etag = etag
	entry.last_mod_str = last_mod_str
	entry.mod_time = fi.modification_time
	entry.size = fi.size
	entry.cache_version = global_static_cache.version
	entry.valid = true
	entry.in_memory = in_mem
	return true
}

// Preload an individual file directly into in-memory cache
static_cache_preload_file :: proc(file_path: string) -> bool {
	sync.rw_mutex_lock(&global_static_cache.rw_lock)
	defer sync.rw_mutex_unlock(&global_static_cache.rw_lock)
	return static_cache_load_file_internal(file_path, true)
}

// Recursively preload all files within a directory into in-memory cache
static_cache_preload_dir :: proc(fs_dir: string) {
	if !os.exists(fs_dir) || !os.is_dir(fs_dir) do return

	w := os.walker_create(fs_dir)
	defer os.walker_destroy(&w)

	sync.rw_mutex_lock(&global_static_cache.rw_lock)
	defer sync.rw_mutex_unlock(&global_static_cache.rw_lock)

	for info in os.walker_walk(&w) {
		if _, err := os.walker_error(&w); err != nil {
			continue
		}
		if info.type == .Directory do continue

		static_cache_load_file_internal(info.fullpath, true)
	}
}

// Serve a static file from memory cache or disk with full HTTP/1.1 cache headers
serve_file :: proc(req: ^Request, res: ^Response, file_path: string, options := DEFAULT_STATIC_OPTIONS) -> bool {
	target_path := file_path
	if os.is_dir(file_path) {
		if len(options.index_file) == 0 do return false
		index_path, _ := filepath.join({file_path, options.index_file}, context.temp_allocator)
		if !os.exists(index_path) || os.is_dir(index_path) do return false
		target_path = index_path
	}

	norm_target := normalize_static_path(target_path)

	// 1. FAST PATH: If in_memory is enabled, check in-memory cache with concurrent shared reader lock (zero disk I/O)
	if options.in_memory {
		sync.rw_mutex_shared_lock(&global_static_cache.rw_lock)
		cached_idx := -1
		for i in 0 ..< global_static_cache.num_files {
			if global_static_cache.files[i].path == norm_target {
				cached_idx = i
				break
			}
		}

		if cached_idx >= 0 && global_static_cache.files[cached_idx].valid {
			entry := &global_static_cache.files[cached_idx]

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
					sync.rw_mutex_shared_unlock(&global_static_cache.rw_lock)
					return true
				}
			}

			if ims, ok := get_header(req, "If-Modified-Since"); ok {
				if ims == entry.last_mod_str {
					res.status = .Not_Modified
					res.content_type = entry.content_type
					res.body = nil
					sync.rw_mutex_shared_unlock(&global_static_cache.rw_lock)
					return true
				}
			}

			if req.method == .HEAD {
				res.status = .OK
				res.content_type = entry.content_type
				res.body = nil
				sync.rw_mutex_shared_unlock(&global_static_cache.rw_lock)
				return true
			}

			res.status = .OK
			response_set_body(res, entry.content, entry.content_type)
			sync.rw_mutex_shared_unlock(&global_static_cache.rw_lock)
			return true
		}
		sync.rw_mutex_shared_unlock(&global_static_cache.rw_lock)
	}

	// 2. SLOW PATH: Cache miss or disk-verified mode (options.in_memory == false)
	fi, stat_err := os.stat(target_path, context.temp_allocator)
	if stat_err != nil {
		return false
	}

	sync.rw_mutex_lock(&global_static_cache.rw_lock)
	defer sync.rw_mutex_unlock(&global_static_cache.rw_lock)

	cached_idx := -1
	for i in 0 ..< global_static_cache.num_files {
		if global_static_cache.files[i].path == norm_target {
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

		entry.path = strings.clone(norm_target)
		entry.content = data
		entry.content_type = content_type
		entry.etag = etag
		entry.last_mod_str = last_mod_str
		entry.mod_time = fi.modification_time
		entry.size = fi.size
		entry.cache_version = global_static_cache.version
		entry.valid = true
		entry.in_memory = options.in_memory
	}

	entry := &global_static_cache.files[cached_idx]

	response_add_header(res, "ETag", entry.etag)
	response_add_header(res, "Last-Modified", entry.last_mod_str)

	cache_val: string
	if options.immutable {
		cache_val = fmt.tprintf("public, max-age=%d, immutable", options.max_age_seconds)
	} else {
		cache_val = fmt.tprintf("public, max-age=%d", options.max_age_seconds)
	}
	response_add_header(res, "Cache-Control", cache_val)

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

	// If in_memory caching is enabled, preload all files under this directory into RAM
	if options.in_memory {
		static_cache_preload_dir(mount.fs_dir)
	}

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
	sync.rw_mutex_lock(&global_static_cache.rw_lock)
	defer sync.rw_mutex_unlock(&global_static_cache.rw_lock)
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

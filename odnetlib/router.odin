package odnetlib

import "core:fmt"
import "core:strings"

Segment_Kind :: enum u8 {
	Static,
	Param,    // {shortId} or :shortId
	Wildcard, // *
}

Route_Segment :: struct {
	kind: Segment_Kind,
	name: string,
}

MAX_SEGMENTS :: 16
MAX_ROUTES   :: 256

Route :: struct {
	method:       Method,
	pattern:      string,
	is_static:    bool,
	segments:     [MAX_SEGMENTS]Route_Segment,
	num_segments: int,
	handler:      Handler_Proc,
}

Router :: struct {
	routes:     [MAX_ROUTES]Route,
	num_routes: int,
	not_found:  Handler_Proc,
}

default_not_found :: proc(req: ^Request, res: ^Response) {
	res.status = .Not_Found
	response_set_body_string(res, "404 Not Found\n", "text/plain; charset=utf-8")
}

router_init :: proc(r: ^Router) {
	r.num_routes = 0
	r.not_found = default_not_found
}

// Parses route pattern segments at registration time (e.g. "/books/{shortId}/delete")
compile_segments :: proc(pattern: string, route: ^Route) {
	route.is_static = true
	route.num_segments = 0

	s := pattern
	// Strip leading slash
	if len(s) > 0 && s[0] == '/' do s = s[1:]
	// Strip trailing slash
	if len(s) > 0 && s[len(s)-1] == '/' do s = s[:len(s)-1]

	if len(s) == 0 {
		return
	}

	start := 0
	for i := 0; i <= len(s); i += 1 {
		if i == len(s) || s[i] == '/' {
			part := s[start:i]
			start = i + 1

			if len(part) > 0 && route.num_segments < MAX_SEGMENTS {
				seg := &route.segments[route.num_segments]
				if part[0] == '{' && part[len(part)-1] == '}' {
					seg.kind = .Param
					seg.name = part[1 : len(part)-1]
					route.is_static = false
				} else if part[0] == ':' {
					seg.kind = .Param
					seg.name = part[1:]
					route.is_static = false
				} else if part == "*" {
					seg.kind = .Wildcard
					seg.name = "*"
					route.is_static = false
				} else {
					seg.kind = .Static
					seg.name = part
				}
				route.num_segments += 1
			}
		}
	}
}

// Checks whether two routes have conflicting structures
routes_conflict :: proc(a: ^Route, b: ^Route) -> bool {
	if a.method != b.method do return false
	if a.num_segments != b.num_segments do return false

	for i in 0..<a.num_segments {
		seg_a := &a.segments[i]
		seg_b := &b.segments[i]

		if seg_a.kind == .Static && seg_b.kind == .Static {
			if seg_a.name != seg_b.name do return false
		} else if seg_a.kind == .Param && seg_b.kind == .Param {
			// Both occupy the same dynamic parameter slot (e.g. {shortId} and {bookId})
			continue
		} else if seg_a.kind == .Wildcard && seg_b.kind == .Wildcard {
			continue
		} else {
			// Different segment kinds (e.g. one is static override, one is dynamic param)
			// Specific static routes take priority over generic dynamic routes in Tier 1
			return false
		}
	}
	return true
}

// Checks if a candidate route would collide with any already registered route.
// Returns the conflicting route pattern if a collision is found.
router_check_collision :: proc(r: ^Router, method: Method, pattern: string) -> (conflicting: string, has_conflict: bool) {
	temp_route: Route
	temp_route.method = method
	temp_route.pattern = pattern
	compile_segments(pattern, &temp_route)

	for i in 0..<r.num_routes {
		existing := &r.routes[i]
		if routes_conflict(existing, &temp_route) {
			return existing.pattern, true
		}
	}
	return "", false
}

router_add :: proc(r: ^Router, method: Method, pattern: string, handler: Handler_Proc) -> bool {
	if r.num_routes >= MAX_ROUTES {
		fmt.eprintln("[odnetlib] ERROR: Maximum route limit reached:", MAX_ROUTES)
		return false
	}

	// Startup Collision Check: runs ONCE at registration, 0 cost during requests
	conflicting, has_conflict := router_check_collision(r, method, pattern)
	if has_conflict {
		fmt.eprintln("\n================================================================================")
		fmt.eprintln("[odnetlib] FATAL ROUTE COLLISION DETECTED AT STARTUP!")
		fmt.eprintf("  Attempted to register : %s %s\n", method_to_string(method), pattern)
		fmt.eprintf("  Collides with route   : %s %s\n", method_to_string(method), conflicting)
		fmt.eprintln("  Explanation           : Both routes share the exact same segment structure.")
		fmt.eprintln("================================================================================\n")
		panic("Route collision detected during registration")
	}

	temp_route: Route
	temp_route.method = method
	temp_route.pattern = pattern
	temp_route.handler = handler
	compile_segments(pattern, &temp_route)

	r.routes[r.num_routes] = temp_route
	r.num_routes += 1
	return true
}

// Zero-allocation path segment scanner for incoming requests
match_dynamic_route :: proc(route: ^Route, path: string, req: ^Request) -> bool {
	s := path
	if len(s) > 0 && s[0] == '/' do s = s[1:]
	if len(s) > 0 && s[len(s)-1] == '/' do s = s[:len(s)-1]

	seg_idx := 0
	start := 0
	num_saved_params := req.num_params

	for i := 0; i <= len(s); i += 1 {
		if i == len(s) || s[i] == '/' {
			if start == i && len(s) == 0 {
				break
			}
			part := s[start:i]
			start = i + 1

			if seg_idx >= route.num_segments {
				req.num_params = num_saved_params
				return false
			}

			seg := &route.segments[seg_idx]
			switch seg.kind {
			case .Static:
				if part != seg.name {
					req.num_params = num_saved_params
					return false
				}
			case .Param:
				// Zero-copy parameter slice extracted directly from req.path
				if req.num_params < MAX_PARAMS {
					req.params[req.num_params] = Param{
						key   = seg.name,
						value = part,
					}
					req.num_params += 1
				}
			case .Wildcard:
				// Matches rest of path
				return true
			}

			seg_idx += 1
		}
	}

	if seg_idx == route.num_segments {
		return true
	}

	req.num_params = num_saved_params
	return false
}

// Ultra-fast zero-allocation route dispatcher
router_dispatch :: proc(r: ^Router, req: ^Request, res: ^Response) {
	response_init(res)
	res.keep_alive = req.keep_alive
	method_matched := false

	// Tier 1: Fast Path for Exact Static Matches (5 - 10 nanoseconds)
	for i in 0..<r.num_routes {
		route := &r.routes[i]
		if route.is_static && route.pattern == req.path {
			if route.method == req.method {
				route.handler(req, res)
				return
			}
			method_matched = true
		}
	}

	// Tier 2: Dynamic Pattern Matching with Zero-Copy Parameter Extraction
	for i in 0..<r.num_routes {
		route := &r.routes[i]
		if !route.is_static {
			req.num_params = 0
			if match_dynamic_route(route, req.path, req) {
				if route.method == req.method {
					route.handler(req, res)
					return
				}
				method_matched = true
			}
		}
	}

	if method_matched {
		res.status = .Method_Not_Allowed
		response_set_body_string(res, "405 Method Not Allowed\n", "text/plain; charset=utf-8")
	} else {
		r.not_found(req, res)
	}
}

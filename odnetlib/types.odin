package odnetlib

import "core:sync"

// HTTP Methods
Method :: enum u8 {
	UNKNOWN,
	GET,
	HEAD,
	POST,
	PUT,
	DELETE,
	OPTIONS,
	PATCH,
}

method_from_string :: proc(s: string) -> Method {
	switch s {
	case "GET":     return .GET
	case "HEAD":    return .HEAD
	case "POST":    return .POST
	case "PUT":     return .PUT
	case "DELETE":  return .DELETE
	case "OPTIONS": return .OPTIONS
	case "PATCH":   return .PATCH
	case:           return .UNKNOWN
	}
}

method_to_string :: proc(m: Method) -> string {
	switch m {
	case .GET:     return "GET"
	case .HEAD:    return "HEAD"
	case .POST:    return "POST"
	case .PUT:     return "PUT"
	case .DELETE:  return "DELETE"
	case .OPTIONS: return "OPTIONS"
	case .PATCH:   return "PATCH"
	case .UNKNOWN: fallthrough
	case:          return "UNKNOWN"
	}
}

// HTTP Status Codes
Status_Code :: enum u16 {
	OK                    = 200,
	Created               = 201,
	Accepted              = 202,
	No_Content            = 204,
	Moved_Permanently     = 301,
	Found                 = 302,
	Not_Modified          = 304,
	Bad_Request           = 400,
	Unauthorized          = 401,
	Forbidden             = 403,
	Not_Found             = 404,
	Method_Not_Allowed    = 405,
	Payload_Too_Large     = 413,
	URI_Too_Long          = 414,
	Internal_Server_Error = 500,
	Not_Implemented       = 501,
	Bad_Gateway           = 502,
	Service_Unavailable   = 503,
}

status_reason :: proc(code: Status_Code) -> string {
	switch code {
	case .OK:                    return "OK"
	case .Created:               return "Created"
	case .Accepted:              return "Accepted"
	case .No_Content:            return "No Content"
	case .Moved_Permanently:     return "Moved Permanently"
	case .Found:                 return "Found"
	case .Not_Modified:          return "Not Modified"
	case .Bad_Request:           return "Bad Request"
	case .Unauthorized:          return "Unauthorized"
	case .Forbidden:             return "Forbidden"
	case .Not_Found:             return "Not Found"
	case .Method_Not_Allowed:    return "Method Not Allowed"
	case .Payload_Too_Large:     return "Payload Too Large"
	case .URI_Too_Long:          return "URI Too Long"
	case .Internal_Server_Error: return "Internal Server Error"
	case .Not_Implemented:       return "Not Implemented"
	case .Bad_Gateway:           return "Bad Gateway"
	case .Service_Unavailable:   return "Service Unavailable"
	case:                        return "Unknown"
	}
}

// Header represents a name-value string view pointing into the socket buffer
Header :: struct {
	name:  string,
	value: string,
}

// Route parameter extracted from dynamic path templates (e.g. {shortId} -> "abc-123")
Param :: struct {
	key:   string,
	value: string, // Direct slice into req.path (zero allocation)
}

MAX_HEADERS :: 64
MAX_PARAMS  :: 16

// Request parsed from raw input buffer without heap allocations.
Request :: struct {
	method:         Method,
	raw_method:     string,
	uri:            string,
	path:           string,
	query:          string,
	version_minor:  u8,      // 0 = HTTP/1.0, 1 = HTTP/1.1
	headers:        [MAX_HEADERS]Header,
	num_headers:    int,
	params:         [MAX_PARAMS]Param,
	num_params:     int,
	body:           []u8,
	content_length: int,
	keep_alive:     bool,
}

get_param :: proc(req: ^Request, key: string) -> (string, bool) {
	for i in 0..<req.num_params {
		if req.params[i].key == key {
			return req.params[i].value, true
		}
	}
	return "", false
}

get_header :: proc(req: ^Request, key: string) -> (string, bool) {
	for i in 0..<req.num_headers {
		if ascii_equal_case_insensitive(req.headers[i].name, key) {
			return req.headers[i].value, true
		}
	}
	return "", false
}

// Response structure populated by route handlers.
Response :: struct {
	status:        Status_Code,
	content_type:  string,
	headers:       [32]Header,
	num_headers:   int,
	body:          []u8,
	keep_alive:    bool,
}

response_init :: proc(res: ^Response) {
	res.status = .OK
	res.content_type = "text/plain; charset=utf-8"
	res.num_headers = 0
	res.body = nil
	res.keep_alive = true
}

response_add_header :: proc(res: ^Response, name: string, value: string) {
	if res.num_headers < len(res.headers) {
		res.headers[res.num_headers] = Header{name = name, value = value}
		res.num_headers += 1
	}
}

response_set_body :: proc(res: ^Response, body: []u8, content_type: string = "text/plain; charset=utf-8") {
	res.body = body
	res.content_type = content_type
}

response_set_body_string :: proc(res: ^Response, body_str: string, content_type: string = "text/plain; charset=utf-8") {
	res.body = transmute([]u8)body_str
	res.content_type = content_type
}

response_set_json :: proc(res: ^Response, json_str: string) {
	res.body = transmute([]u8)json_str
	res.content_type = "application/json"
}

Handler_Proc :: proc(req: ^Request, res: ^Response)

// Server performance statistics
Server_Stats :: struct {
	total_connections:  u64,
	active_connections: i64,
	total_requests:     u64,
	bytes_received:     u64,
	bytes_sent:         u64,
}

stats_inc_connection :: proc(s: ^Server_Stats) {
	sync.atomic_add(&s.total_connections, 1)
	sync.atomic_add(&s.active_connections, 1)
}

stats_dec_connection :: proc(s: ^Server_Stats) {
	sync.atomic_sub(&s.active_connections, 1)
}

stats_inc_request :: proc(s: ^Server_Stats) {
	sync.atomic_add(&s.total_requests, 1)
}

stats_add_bytes_recv :: proc(s: ^Server_Stats, count: int) {
	sync.atomic_add(&s.bytes_received, u64(count))
}

stats_add_bytes_sent :: proc(s: ^Server_Stats, count: int) {
	sync.atomic_add(&s.bytes_sent, u64(count))
}

package odnetlib

import "core:strings"

mime_lookup_ext :: proc(ext: string) -> string {
	e := ext
	if len(e) > 0 && e[0] == '.' {
		e = e[1:]
	}

	switch e {
	// Text & Code
	case "html", "htm":   return "text/html; charset=utf-8"
	case "css":           return "text/css; charset=utf-8"
	case "js", "mjs":     return "application/javascript; charset=utf-8"
	case "json", "map":   return "application/json"
	case "txt", "md":     return "text/plain; charset=utf-8"
	case "xml":           return "application/xml"
	case "csv":           return "text/csv; charset=utf-8"

	// Images
	case "svg":           return "image/svg+xml"
	case "png":           return "image/png"
	case "jpg", "jpeg":   return "image/jpeg"
	case "gif":           return "image/gif"
	case "webp":          return "image/webp"
	case "avif":          return "image/avif"
	case "ico":           return "image/x-icon"
	case "bmp":           return "image/bmp"

	// Web Fonts
	case "woff2":         return "font/woff2"
	case "woff":          return "font/woff"
	case "ttf":           return "font/ttf"
	case "otf":           return "font/otf"
	case "eot":           return "application/vnd.ms-fontobject"

	// Media & Binary
	case "wasm":          return "application/wasm"
	case "pdf":           return "application/pdf"
	case "mp4":           return "video/mp4"
	case "webm":          return "video/webm"
	case "mp3":           return "audio/mpeg"
	case "wav":           return "audio/wav"
	case "zip":           return "application/zip"
	case "gz":            return "application/gzip"

	case:                 return "application/octet-stream"
	}
}

mime_lookup :: proc(filepath_or_name: string) -> string {
	last_dot := strings.last_index_byte(filepath_or_name, '.')
	if last_dot < 0 {
		return "application/octet-stream"
	}
	return mime_lookup_ext(filepath_or_name[last_dot:])
}

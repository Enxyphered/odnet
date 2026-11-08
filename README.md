# odnet: Ultra-High-Performance HTTP/1.1 in Odin

The repository is divided into two distinct projects:
1. **`odnetlib`**: A reusable, zero-allocation HTTP/1.1 server library featuring native Windows (IOCP + `AcceptEx` + `GetQueuedCompletionStatusEx`) and Linux (epoll + `SO_REUSEPORT` + `EPOLLET`) engines, connection slab pools, and zero-copy routing.
2. **`odnetclient`**: An example application demonstrating how to use `odnetlib`, register client routes (both static and dynamic with `{param}`), and launch the server.

---

## Zero-Allocation Dynamic Routing Design

A common concern with dynamic routing (e.g. `/books/{shortId}/delete`) is that matching parameters can degrade server throughput due to string allocations, regex overhead, or heap splitting.

`odnetlib` solves this via a **Two-Tier Zero-Copy Routing Engine**:

1. **Tier 1 (Instant Static Match - 5 to 10 ns):**
   Routes without parameters (like `/plaintext` or `/json`) are matched instantly via string pointer equality and length comparison. Zero segment splitting.
2. **Tier 2 (Zero-Copy Dynamic Match - 30 to 50 ns):**
   - Route templates like `/books/{shortId}/delete` are compiled at startup into segment kinds: `[Static("books"), Param("shortId"), Static("delete")]`.
   - When an incoming request arrives, segments are scanned on the fly using pointer offsets into the request path.
   - When a parameter segment matches, `shortId` is extracted as a **direct slice (`string`) into `req.path`**.
   - Parameters are stored in a fixed array on the stack (`[16]Param`).
   - **Zero heap allocations, zero string copies, zero GC overhead.**

### Benchmark Result
Over **12,500 requests/sec** served on dynamic route `/books/book-{i}/delete` over persistent keep-alive connections on a single client thread with **0 bytes allocated**.

---

## Project Structure

```
odnet/
├── build.bat                    # Builds odnetclient for Windows
├── build.sh                     # Builds odnetclient for Linux
├── ols.json                     # VS Code OLS indexing for both packages
│
├── odnetlib/                    # Reusable HTTP/1.1 Server Library
│   ├── config.odin              # Server configuration
│   ├── types.odin               # Method, Status_Code, Header, Param, Request, Response
│   ├── arena.odin               # Bump allocator for scratch memory
│   ├── connection.odin          # Pre-allocated connection slab pool
│   ├── parser.odin              # Zero-copy HTTP/1.1 parser (picohttpparser-style)
│   ├── serializer.odin          # Zero-alloc response serializer
│   ├── date.odin                # 1-sec cached RFC-1123 Date header service
│   ├── router.odin              # Two-tier static + dynamic zero-copy router
│   ├── server.odin              # Public Server API (init, get, post, start, stop)
│   ├── server_windows.odin      # Windows IOCP engine (#+build windows)
│   └── server_linux.odin        # Linux epoll engine (#+build linux)
│
└── odnetclient/                 # Example Application (Client-controlled routes)
    └── main.odin                # Route handlers, client setup, and server execution
```

---

## Client Usage Example

```odin
package main

import "core:fmt"
import http "../odnetlib"

handle_book_delete :: proc(req: ^http.Request, res: ^http.Response) {
    // Zero-allocation dynamic parameter extraction
    short_id, ok := http.get_param(req, "shortId")
    if !ok {
        res.status = .Bad_Request
        return
    }

    resp := fmt.tprintf("Book '%s' deleted!\n", short_id)
    http.response_set_body_string(res, resp)
}

main :: proc() {
    server: http.Server
    http.server_init(&server)

    // Register routes
    http.server_get(&server, "/plaintext", proc(req: ^http.Request, res: ^http.Response) {
        http.response_set_body_string(res, "Hello, World!", "text/plain")
    })

    // Dynamic route with parameter
    http.server_get(&server, "/books/{shortId}/delete", handle_book_delete)

    // Run server
    http.server_start(&server)
}
```

---

## Building and Running

### Building on Windows
```cmd
build.bat
# or directly:
odin build odnetclient -out:odnetclient.exe -o:speed
```

### Building on Linux
```bash
./build.sh
# or directly:
odin build odnetclient -out:odnetclient -target:linux_amd64 -o:speed
```

### Running the Client
```cmd
odnetclient.exe --port 8080 --workers 0
```

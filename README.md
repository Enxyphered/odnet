# odnet

`odnet` is a lightweight HTTP/1.1 web server framework and compile-time HTML component engine written in [Odin](https://odin-lang.org/).

## Modules

The repository is organized into three main components:

- **`odnetlib`**: Core HTTP/1.1 server library providing platform-native networking (IOCP on Windows, epoll on Linux), request parsing, routing, and static file serving with HTTP caching.
- **`odnetgen`**: Standalone HTML template compiler that turns standard `.html` component files into type-safe Odin render procedures.
- **`odnetclient`**: Example application demonstrating how to build web pages with components, serve static assets, handle form submissions via HTMX, and configure routing.

---

## Quickstart

### Prerequisites
- [Odin compiler](https://odin-lang.org/docs/install/) (latest release or dev)
- *(Optional)* [Tailwind CSS Standalone CLI](https://github.com/tailwindlabs/tailwindcss/releases/latest) if you want to modify stylesheet sources (`Input.css`).

### Build & Run

All build artifacts are placed into the `output/` directory (which is gitignored).

#### Windows
```cmd
build.bat
output\odnetclient.exe --port 9090
```

#### Linux
```bash
chmod +x build.sh
./build.sh
./output/odnetclient --port 9090
```

Once running, visit **`http://localhost:9090/home`** in your browser.

---

## Building from Scratch

The build scripts handle the complete pipeline:

1. **Tailwind CSS Compilation**: If `tailwindcss` is found on your PATH, minifies `odnetclient/Input.css` to `odnetclient/static/css/Styles.css`. If not found, uses the existing pre-built stylesheet.
2. **Compile Generator**: Builds `output/odnetgen` from `odnetgen/`.
3. **Compile Templates**: Runs `odnetgen` against `odnetclient/templates/` to produce `odnetclient/templates_gen.odin`.
4. **Build Application**: Compiles the final executable (`output/odnetclient`).

---

## HTML Component Engine (`odnetgen`)

`odnetgen` compiles native HTML files into Odin procedures. Components can be nested, accept parameters, and support slot insertion.

### Template Syntax

| Feature | Syntax | Example |
| :--- | :--- | :--- |
| **Variables** | `{name}` | `<h1>Hello, {title} {name}!</h1>` |
| **Component Call** | `@Component(...)` | `@Greet(title: "Mr.", name: name, badge_id: "007")` |
| **Tag Style** | `<Component ... />` | `<Button label="Submit" variant="primary" />` |
| **Default Slot** | `{slot}` & `@Component(...) { ... }` | `@Card(title: "Overview") { <p>Slot content</p> }` |
| **Named Slots** | `{slot:name}` & `<slot:name>` / `@slot(name)` | `<Card><slot:actions><button>OK</button></slot:actions></Card>` |
| **Polymorphic / Fallback Slots** | `{slot:name ?? var}` or `{slot:name \|\| "Default"}` | `<h3>{slot:title ?? title}</h3>` |
| **Escaped Braces** | `{{` / `}}` or `\{` / `\}` | `body {{ margin: 0; }}` renders literal `{ margin: 0; }` |
| **Escaped At** | `@@` or `\@` | `user@@example.com` renders literal `@` |

### Using Generated Components in Odin

```odin
import "core:strings"

handle_home :: proc(req: ^http.Request, res: ^http.Response) {
    b := strings.builder_make(context.temp_allocator)
    render_home(&b, username = "Shaamil", name = "Shaamil", badge_id = "007")
    http.response_set_html(res, strings.to_string(b))
}
```

---

## Routing & Handlers

`odnetlib` supports static paths, dynamic route parameters, and static directory mounting:

```odin
package main

import "core:fmt"
import http "../odnetlib"

main :: proc() {
    cfg := http.DEFAULT_CONFIG
    cfg.port = 9090

    server: http.Server
    http.server_init(&server, cfg)

    // Static Routes
    http.server_get(&server, "/", handle_index)
    http.server_get(&server, "/home", handle_home)
    http.server_post(&server, "/api/greeting", handle_update_greeting)

    // Dynamic Parameter Routes
    http.server_get(&server, "/users/{id}/profile", handle_profile)

    // Static File Serving with Caching
    http.server_static(&server, "/static", "odnetclient/static")

    // Start Server
    http.server_start(&server)
}

handle_profile :: proc(req: ^http.Request, res: ^http.Response) {
    user_id, ok := http.get_param(req, "id")
    if !ok {
        res.status = .Bad_Request
        return
    }
    http.response_set_body_string(res, fmt.tprintf("User ID: %s", user_id))
}
```

---

## Static File Serving & Caching

Mount any directory to a URL prefix:

```odin
http.server_static(&server, "/static", "odnetclient/static")
```

Features included:
- **MIME Type Resolution**: Maps common web file extensions (`.html`, `.css`, `.js`, `.svg`, `.json`, `.woff2`, etc.) to standard MIME headers.
- **HTTP/1.1 Cache Validation**: Sends `ETag` and `Last-Modified` headers. When a client sends `If-None-Match` or `If-Modified-Since`, the server validates them and returns `304 Not Modified`.
- **Live File Watcher**: Watches served static directories for modifications and refreshes cached file metadata automatically.
- **Security**: Traversal prevention rejects requests attempting to access parent directories using `..` or illegal characters.

---

## Tailwind CSS Setup (Optional)

If you wish to modify the styling in `odnetclient/Input.css`:

1. Download the standalone Tailwind CLI executable for your platform from [Tailwind CSS Releases](https://github.com/tailwindlabs/tailwindcss/releases/latest).
2. Rename the binary to `tailwindcss` (or `tailwindcss.exe` on Windows) and place it somewhere in your `PATH`.
3. Run in watch mode while developing:
   ```cmd
   tailwindcss -i odnetclient/Input.css -o odnetclient/static/css/Styles.css --watch
   ```
   The server's file watcher will pick up new CSS changes as soon as Tailwind saves the file.

---

## Running Tests

Run each package's test suite with Odin's built-in test runner:

```cmd
odin test odnetlib
odin test odnetlib/html
odin test odnetgen
odin test odnetclient
```

## License

MIT

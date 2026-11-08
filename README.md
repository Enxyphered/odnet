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

`odnetgen` is a compile-time HTML template engine that translates standard `.html` component files into type-safe Odin render procedures. Components can be nested, accept parameters, and support multiple named slots and variable fallbacks with zero runtime allocation overhead.

### Template Syntax

| Feature | Syntax | Example |
| :--- | :--- | :--- |
| **Variables** | `{name}` | `<h1>Hello, {title} {name}!</h1>` |
| **Component Call (At)** | `@Component(...)` | `@Greet(title: "Mr.", name: name, badge_id: "007")` |
| **Component Call (Tag)** | `<Component ... />` | `<Button label="Submit" variant="primary" />` |
| **Default Slot** | `{slot}` | `@Card(title: "Overview") { <p>Slot content</p> }` |
| **Named Slots** | `{slot:name}` | `<slot:actions><button>Save</button></slot:actions>` |
| **Polymorphic / Fallback Slots** | `{slot:name ?? var}` or `{slot:name \|\| "Default"}` | `<h3>{slot:title ?? title}</h3>` |
| **Block Slot Fallback** | `<slot:name><h3>{title}</h3></slot:name>` | Renders `<h3>{title}</h3>` if slot is omitted |
| **Escaped Braces** | `{{` / `}}` or `\{` / `\}` | `body {{ margin: 0; }}` renders literal `{ margin: 0; }` |
| **Escaped At** | `@@` or `\@` | `user@@example.com` renders literal `@` |

---

### Component Slots & Polymorphic Fallbacks

Components can define multiple named slots alongside default child content, as well as automatic fallbacks when a slot is not provided. There are two patterns depending on whether the wrapper tag is part of the fallback:

#### Pattern A: Block Slot Fallback (Replaces the entire wrapper tag)

Use `<slot:name>...</slot:name>` or `@slot(name) { ... }` in your component definition when you want the caller's custom slot to **completely replace** the tag (e.g., avoiding an unwanted `<h3>` wrapper around custom markup):

```html
<div class="card bg-white rounded-2xl border border-slate-200 shadow-sm overflow-hidden">
  <div class="px-6 py-4 border-b border-slate-100 bg-slate-50 flex items-center justify-between">
    <!-- If <slot:title> is provided, it renders directly.
         If omitted, it falls back to rendering <h3>{title}</h3> -->
    <slot:title>
      <h3 class="text-base font-semibold text-slate-900 tracking-tight">{title}</h3>
    </slot:title>
    
    <div class="flex items-center gap-2">
      {slot:actions}
    </div>
  </div>

  <div class="p-6">
    {slot}
  </div>
</div>
```

#### Pattern B: Inline Slot Fallback (Inside an existing wrapper tag)

Use `{slot:name ?? var}` or `{slot:name || "Default"}` when the wrapper tag is always present and you only want to customize the inner content:

```html
<button class="btn">
  <!-- Always stays a button, customizes inner icon/text -->
  {slot:label ?? label}
</button>
```

#### 2. Using Named Slots in Caller Templates

**Tag Style:**
```html
<Card title="Account Overview">
  <slot:actions>
    <span class="badge bg-emerald-50 text-emerald-700">Active</span>
  </slot:actions>

  <!-- Content outside explicit slot tags goes directly to the default slot -->
  <p>Welcome back, {username}!</p>
</Card>
```

**At-Syntax Style:**
```html
@Card(title: "Account Overview") {
  @slot(actions) {
    <span class="badge bg-emerald-50 text-emerald-700">Active</span>
  }
  <p>Welcome back, {username}!</p>
}
```

---

### Using Generated Components in Odin

When compiled by `odnetgen`, each component produces a procedure with optional named parameters for variables and slots:

```odin
import "core:strings"

handle_home :: proc(req: ^http.Request, res: ^http.Response) {
    b := strings.builder_make(context.temp_allocator)
    
    // Direct Odin invocation with custom slots
    render_card(
        &b,
        title = "Dashboard",
        slot_actions = proc(b: ^strings.Builder, user_data: rawptr) {
            strings.write_string(b, "<button class=\"btn-sm\">Refresh</button>")
        },
        slot = proc(b: ^strings.Builder, user_data: rawptr) {
            strings.write_string(b, "<p>Real-time analytics data here.</p>")
        },
    )
    
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

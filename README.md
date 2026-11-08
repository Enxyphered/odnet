# odnet: Ultra-High-Performance HTTP/1.1 in Odin

The repository is divided into three distinct modules:
1. **`odnetlib`**: A reusable, zero-allocation HTTP/1.1 server library featuring native Windows (IOCP + `AcceptEx` + `GetQueuedCompletionStatusEx`) and Linux (epoll + `SO_REUSEPORT` + `EPOLLET`) engines, connection slab pools, zero-copy routing, static file streaming with HTTP/1.1 caching, and real-time OS file change detection.
2. **`odnetgen`**: A standalone compile-time HTML component generator that compiles pure HTML templates into type-safe, zero-allocation Odin procedures streaming directly into socket builders.
3. **`odnetclient`**: An application demonstrating how to use `odnetlib` and `odnetgen`, register client routes, mount static assets, and serve Tailwind & shadcn UI components.

---

## Tailwind CSS Setup & Compilation

`odnet` uses the official **standalone Tailwind CLI executable** (no Node.js or npm required).

### 1. Download Tailwind Standalone CLI
Download the standalone executable for your operating system from GitHub Releases:
👉 **[Tailwind CSS Releases](https://github.com/tailwindlabs/tailwindcss/releases/latest)**

- **Windows**: Download `tailwindcss-windows-x64.exe`
- **Linux**: Download `tailwindcss-linux-x64`
- **macOS**: Download `tailwindcss-macos-arm64` (Apple Silicon) or `tailwindcss-macos-x64` (Intel)

### 2. Rename & Add to PATH
1. Rename the downloaded executable to `tailwindcss.exe` (Windows) or `tailwindcss` (Linux/macOS).
2. Move it to a folder in your system `PATH` (e.g. `C:\Tools\` on Windows, or `/usr/local/bin/` on Linux):
   ```bash
   # Linux / macOS
   chmod +x tailwindcss
   sudo mv tailwindcss /usr/local/bin/
   ```
3. Verify by opening a new terminal and running:
   ```cmd
   tailwindcss --help
   ```

### 3. Compiling CSS
- **Input file**: `odnetclient/Input.css`
- **Output file**: `odnetclient/static/css/Styles.css`

You can build minified styles manually:
```cmd
tailwindcss -i odnetclient/Input.css -o odnetclient/static/css/Styles.css --minify
```

Or run watch mode during active frontend development:
```cmd
tailwindcss -i odnetclient/Input.css -o odnetclient/static/css/Styles.css --watch
```
> [!NOTE]
> When `tailwindcss` writes changes to `Styles.css`, the server's **OS File Watcher** instantly detects the modification, updates the `ETag` and `Last-Modified` timestamps, and serves the new stylesheet without requiring a server restart.

---

## Zero-Allocation HTML Component Engine (`odnetgen`)

Frontend developers write 100% native `.html` templates in `odnetclient/templates/`. `odnetgen` compiles them into type-safe Odin procedures in `odnetclient/templates_gen.odin`.

### Component Syntax

| Feature | Syntax | Example |
| :--- | :--- | :--- |
| **Variables** | `{var_name}` | `<h1>Hello, {title} {name}!</h1>` |
| **Escaped Braces** | `{{` / `}}` or `\{` / `\}` | `body {{ margin: 0; }}` renders literal `{ margin: 0; }` |
| **Escaped At** | `@@` or `\@` | `user@@example.com` renders literal `@` |
| **Component Call** | `@Component(...)` | `@Greet(title: "Mr.", name: name, badge_id: "007")` |
| **HTML Tag Style** | `<Component ... />` | `<Button label="Save" variant="primary" />` |
| **Slots (Children)**| `{slot}` & `{ ... }` | `@Card(title: "Settings") { @Input(...) }` |

### Zero-Allocation Slots
When a parent template injects variables into a child slot, `odnetgen` emits a stack-allocated context struct (`Slot_Ctx`) and passes it into `user_data: rawptr`. No heap allocations, closures, or runtime overhead.

---

## Static File Serving & HTTP/1.1 Caching

`odnetlib` includes an ultra-fast static file server with real-time OS file change detection.

```odin
// Mount directory odnetclient/static at URL path /static
http.server_static(&server, "/static", "odnetclient/static")
```

### Features:
1. **Automated MIME Type Detection**: Comprehensive table supporting `.html`, `.css`, `.js`, `.json`, `.svg`, `.png`, `.jpg`, `.webp`, `.woff2`, `.ttf`, `.wasm`, `.pdf`, etc.
2. **Directory Traversal Security**: Automatically rejects malicious paths containing `..`, volume drives `:`, or null bytes (`403 Forbidden`).
3. **HTTP/1.1 Cache Headers**:
   - `Cache-Control`: `public, max-age=3600` (configurable)
   - `ETag`: Unique hex hash based on file size and nanosecond modification time
   - `Last-Modified`: RFC-1123 HTTP date
4. **Conditional Request Validation (304 Not Modified)**:
   - Validates client `If-None-Match` against `ETag`
   - Validates client `If-Modified-Since` against `Last-Modified`
   - Returns instant `304 Not Modified` with zero network body transfer
5. **Real-Time OS File Watcher**:
   - Uses Windows `FindFirstChangeNotificationW` (and Linux `inotify`)
   - When Tailwind or an editor updates `Styles.css` on disk, the server kernel watcher immediately invalidates the cache and generates fresh ETags and timestamps on the next request.

---

## Zero-Allocation Dynamic Routing Design

`odnetlib` solves dynamic routing via a **Two-Tier Zero-Copy Routing Engine**:

1. **Tier 1 (Instant Static Match - 5 to 10 ns):**
   Routes without parameters (like `/plaintext`, `/json`, or `/home`) are matched instantly via string pointer equality and length comparison. Zero segment splitting.
2. **Tier 1.5 (Static File Mounts):**
   Mounted directories (like `/static/*`) serve files with in-memory caching and ETags.
3. **Tier 2 (Zero-Copy Dynamic Match - 30 to 50 ns):**
   - Route templates like `/books/{shortId}/delete` extract parameters as a **direct slice (`string`) into `req.path`**.
   - Parameters are stored in a fixed array on the stack (`[16]Param`).
   - Zero heap allocations, zero string copies, zero GC overhead.

---

## Building and Running

### Build All (Windows)
```cmd
build.bat
```
`build.bat` automatically:
1. Compiles Tailwind CSS if `tailwindcss` is found in PATH.
2. Compiles `output\odnetgen.exe` executable.
3. Runs `output\odnetgen.exe` to generate `odnetclient/templates_gen.odin`.
4. Compiles `output\odnetclient.exe` with speed optimizations (`-o:speed`).

### Build All (Linux)
```bash
./build.sh
```

### Running the Server
```cmd
output\odnetclient.exe --port 9090
```
On Linux:
```bash
./output/odnetclient --port 9090
```

### Endpoints Available
- `GET  /` - Application info and endpoints
- `GET  /home` - Zero-allocation HTML page composed with Tailwind & shadcn UI
- `GET  /static/css/Styles.css` - Static CSS with HTTP/1.1 caching, ETag & 304 validation
- `GET  /plaintext` - TechEmpower plaintext benchmark
- `GET  /json` - TechEmpower JSON benchmark
- `GET  /books/{shortId}/delete` - Dynamic zero-copy route parameter
- `GET  /users/{id}/profile` - Dynamic zero-copy route parameter
- `POST /echo` - Echo payload back to client

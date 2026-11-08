# odnet

A fast, lightweight HTTP/1.1 web server and compile-time HTML template engine written in [Odin](https://odin-lang.org/).

## Overview

The repository consists of three packages:

- **`odnetlib`**: An HTTP/1.1 server library using platform-native I/O with Windows IOCP and Linux epoll. Includes request parsing, routing with dynamic path parameters, static file serving, and HTTP cache validation.
- **`odnetgen`**: A compile-time template generator that compiles HTML templates into type-safe Odin procedures. Supports strongly-typed props, control flow, loops, slots, and multi-package template discovery.
- **`odnetclient`**: An example application demonstrating routing, server-rendered components, HTMX integration, and modular subpackages.

---

## Quickstart

### Requirements
- [Odin compiler](https://odin-lang.org/docs/install/)
- Tailwind CSS standalone CLI to compile stylesheets from `Input.css`

### Build and Run

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

Routes available when running:
- `http://localhost:9090/home` - Interactive dashboard with HTMX form swapping
- `http://localhost:9090/books` - Library catalog demonstrating typed models, loops, and conditional badges
- `http://localhost:9090/json` - JSON endpoint
- `http://localhost:9090/plaintext` - Plaintext endpoint

---

## Build Pipeline

The `build.bat` and `build.sh` scripts run the following steps:

1. **Tailwind CSS**: Builds `odnetclient/Input.css` into `odnetclient/static/css/Styles.css` if `tailwindcss` is available on the PATH.
2. **Template Compiler**: Builds `odnetgen` into `output/odnetgen`.
3. **Template Generation**: Runs `odnetgen`, which scans for folders containing a `templates` directory with `.html` files, infers the package name, and writes `template_gen.odin` in the parent module folder.
4. **Application Build**: Compiles `odnetclient` into `output/odnetclient`.

---

## Template Compiler: `odnetgen`

`odnetgen` converts HTML templates into type-safe Odin procedures at build time. Output procedures write directly to a `strings.Builder` with zero runtime allocations.

### Multi-Module Discovery

Running `odnetgen` with no arguments scans the project tree and compiles any module with a `templates` directory:

```
odnetclient/
├── templates/             -> compiles to odnetclient/template_gen.odin (package main)
└── books/
    └── templates/         -> compiles to odnetclient/books/template_gen.odin (package books)
```

The package name is inferred from existing `.odin` files in the directory. Generated render procedures are placed directly in the module's package. Templates inside `odnetclient/books/templates/` have access to all declarations in `package books` without explicit package qualifiers.

### Syntax Cheatsheet

| Feature | Syntax |
| :--- | :--- |
| Variable interpolation | `{name}` or `{expression}` |
| Props header | `@props(name: Type = default)` |
| Package imports | `@import "path"` or `@import alias "path"` |
| Conditionals | `@if (cond) { ... } @else if (cond) { ... } @else { ... }` |
| Switch-case | `@switch (val) { @case (x) { ... } @default { ... } }` |
| Foreach loop | `@foreach item, idx in collection { ... }` |
| Range loop | `@for i in 0..<count { ... }` |
| Component call | `@ComponentName(prop: value)` |
| Default slot | `{slot}` |
| Named slot | `{slot:name}` |
| Slot fallback | `<slot:name>Fallback HTML</slot:name>` or `{slot:name ?? fallback_var}` |
| Literal escapes | `{{` and `}}` for braces, `@@` for at-signs |

Tag equivalents `<if>`, `<switch>`, `<case>`, `<default>`, `<foreach>`, and `<for>` are also supported.

### Props and Imports

Templates declare props at the top of the file:

```html
@import "core:fmt"
@import models "../models"
@props(
  book: models.Book,
  items: []string = nil,
  show_price: bool = true,
  title: string = "Catalog",
)

<div class="card">
  <h3>{title}</h3>
  <p>{book.title} by {book.author}</p>
  @if (show_price) {
    <span>${book.price}</span>
  }
</div>
```

- Field access on structs uses standard dot notation.
- Unspecified variables default to `string = ""`.
- Loop iteration variables are scoped to the loop body and do not become component parameters.

### Control Flow

#### Conditionals
```html
@if (is_admin) {
  <span class="badge badge-admin">Admin</span>
} @else if (role == "editor") {
  <span class="badge badge-editor">Editor</span>
} @else {
  <span class="badge">Reader</span>
}
```

#### Switch-Case
```html
@switch (book.status) {
  @case ("in_stock") {
    <span class="badge-green">In Stock</span>
  }
  @case ("backorder") {
    <span class="badge-amber">Backordered</span>
  }
  @default {
    <span class="badge-red">Out of Stock</span>
  }
}
```

#### Loops
```html
@foreach book, idx in books {
  <div class="row">
    <span>#{idx + 1}</span>
    @BookCard(book: book, show_price: true)
  </div>
}

@for i in 0..<5 {
  <span class="star">★</span>
}
```

### Slots

#### Block Slots with Fallbacks
Use `<slot:name>` when the caller may replace the entire block:

```html
<div class="card">
  <div class="card-header">
    <slot:title>
      <h3 class="font-bold">{title}</h3>
    </slot:title>
    {slot:actions}
  </div>
  <div class="card-body">
    {slot}
  </div>
</div>
```

Callers can pass markup into specific slots:

```html
<Card title="Account Details">
  <slot:actions>
    <button class="btn">Edit</button>
  </slot:actions>

  <p>Default slot body content goes here.</p>
</Card>
```

#### Inline Fallbacks
For inner text fallbacks inside fixed tags:

```html
<button class="btn">
  {slot:label ?? label}
</button>
```

---

## Server and Routing: `odnetlib`

```odin
package main

import "core:fmt"
import http "../odnetlib"

main :: proc() {
    cfg := http.DEFAULT_CONFIG
    cfg.port = 9090

    server: http.Server
    http.server_init(&server, cfg)

    // Routing
    http.server_get(&server, "/", handle_index)
    http.server_get(&server, "/books/{id}", handle_book)
    http.server_post(&server, "/api/submit", handle_submit)

    // Static assets
    http.server_static(&server, "/static", "odnetclient/static")

    http.server_start(&server)
}

handle_book :: proc(req: ^http.Request, res: ^http.Response) {
    id, ok := http.get_param(req, "id")
    if !ok {
        res.status = .Bad_Request
        return
    }
    http.response_set_body_string(res, fmt.tprintf("Book: %s\n", id))
}
```

### Static File Serving
Static routes mounted via `http.server_static` include:
- MIME detection from file extensions
- `ETag` and `Last-Modified` validation returning `304 Not Modified`
- Runtime directory monitoring for stylesheet and asset reloads
- Path traversal protection

---

## Testing

Run test suites across all packages:

```cmd
odin test odnetlib
odin test odnetlib/html
odin test odnetgen
odin test odnetclient
```

## License

MIT

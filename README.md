# odnet

A fast, lightweight HTTP/1.1 web server and compile-time HTML template engine written in [Odin](https://odin-lang.org/).

## Overview

The repository consists of four components:

- **`odnetlib`**: An HTTP/1.1 server library using platform-native I/O with Windows IOCP and Linux epoll. Includes request parsing, routing with dynamic path parameters, static file serving, and HTTP cache validation.
- **`odnetgen`**: A compile-time template generator that compiles `.odhtml` templates into type-safe Odin procedures. Supports strongly-typed props, control flow, loops, slots, and multi-package template discovery.
- **`odhtml_lsp`**: A high-performance native Odin Language Server and VS Code extension for `.odhtml` templates featuring syntax highlighting, real-time diagnostics, autocompletion, hover tooltips, and go-to-definition.
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
2. **Compiler & Language Server**: Builds `odnetgen` into `output/odnetgen` and the native `odhtml_lsp` server into `output/odhtml-lsp`.
3. **Template Generation**: Runs `odnetgen`, which scans for folders containing a `templates` directory with `.odhtml` (or `.html`) files, infers the package name, and writes `template_gen.odin` in the parent module folder.
4. **Application Build**: Compiles `odnetclient` into `output/odnetclient`.

---

## Template Compiler: `odnetgen`

`odnetgen` converts `.odhtml` templates into type-safe Odin procedures at build time. Output procedures write directly to a `strings.Builder` with zero runtime allocations.

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

```odhtml
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
```odhtml
@if (is_admin) {
  <span class="badge badge-admin">Admin</span>
} @else if (role == "editor") {
  <span class="badge badge-editor">Editor</span>
} @else {
  <span class="badge">Reader</span>
}
```

#### Switch-Case
```odhtml
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
```odhtml
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

```odhtml
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

```odhtml
<Card title="Account Details">
  <slot:actions>
    <button class="btn">Edit</button>
  </slot:actions>

  <p>Default slot body content goes here.</p>
</Card>
```

#### Inline Fallbacks
For inner text fallbacks inside fixed tags:

```odhtml
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

## Developer Tooling: `odhtml_lsp`

The `odhtml_lsp/` directory contains a high-performance developer tooling stack for `.odhtml` templates, consisting of a native Odin Language Server and a self-contained VS Code extension.

### Features
- **Syntax Highlighting**: Comprehensive TextMate grammar (`syntaxes/odhtml.tmLanguage.json`) providing rich syntax coloring for:
  - Header directives: `@props(...)`, `@import`
  - Control flow: `@if`, `@else if`, `@else`, `@switch`, `@case`, `@default`, `@foreach`, `@for`
  - Component calls and tags: `@ComponentName(...)` and `<ComponentName ...>`
  - Slots: `<slot:name>`, `<slot>`, `{slot:name}`, `{slot:name ?? fallback}`
  - Interpolations: `#{expr}` and `{expr}` with Odin expression coloring (variables, types, operators, numbers, strings)
  - Classic HTML `< / >` file icon for all `.odhtml` files
- **Cross-Language Go to Definition**:
  - **Component tags & calls** (`@BookCard` or `<BookCard`): Jumps straight to `book_card.odhtml`.
  - **Template props** (`show_price`, `index`): Jumps to the `@props(...)` declaration at the top of the file.
  - **Odin types & fields** (`Book`, `is_bestseller`, `price`): Jumps cross-language directly into the `.odin` source file where the struct, enum, union, or field is declared (e.g., `Book :: struct` in `books.odin`).
- **Real-Time Diagnostics**: Flags unmatched braces, unclosed tags, malformed `@props`, unknown component calls, and missing required props with live inline squiggles.
- **Hover Tooltips**: Inspecting `@ComponentName` displays component file path, declared props table (name, type, default value, required status), and available slots. Hovering over directives or props shows typed signatures and usage documentation.
- **Autocompletions**: Intelligent completions for `@props`, `@if`, `@foreach`, `@switch`, workspace components (with required argument snippets), prop parameters, slot tags, and template variables inside `{...}`.
- **Document Symbols & Outline**: Hierarchical symbol outlines for the VS Code Outline pane and breadcrumbs.

---

### Quick Setup for VS Code

You can set up the entire language server and install the VS Code extension in **one command**:

#### One-Click Script (Windows)
```cmd
setup_lsp.bat
```

#### One-Click Script (Linux / macOS)
```bash
chmod +x setup_lsp.sh
./setup_lsp.sh
```

The script automatically:
1. Compiles the native `odhtml-lsp` binary into `output/odhtml-lsp.exe` (and copies it to `odhtml_lsp/`).
2. Ensures the pre-packaged `odhtml-lsp-0.1.0.vsix` is ready.
3. Installs the extension into VS Code (`code --install-extension ...`).

Once installed, simply press `Ctrl+Shift+P` in VS Code and select **Developer: Reload Window**.

---

### Manual Setup (Step-by-Step)

If you prefer to run each step manually:

#### Step 1: Build the Language Server Binary
Run `build.bat` (or `build.sh`), which automatically compiles the native language server to `output/odhtml-lsp.exe`:
```cmd
build.bat
```
Alternatively, build only the language server directly:
```cmd
odin build odhtml_lsp -out:output/odhtml-lsp.exe -o:speed
```

#### Step 2: Install the VS Code Extension
Install the pre-packaged `.vsix` extension file located in `odhtml_lsp/`:
```cmd
code --install-extension odhtml_lsp/odhtml-lsp-0.1.0.vsix --force
```

*Or via the VS Code GUI:*
1. Open the Extensions sidebar (`Ctrl+Shift+X`).
2. Click the `...` menu in the top-right corner of the Extensions panel.
3. Select **Install from VSIX...** and choose `odhtml_lsp/odhtml-lsp-0.1.0.vsix`.

#### Step 3: Reload VS Code
Press `Ctrl+Shift+P`, type **Developer: Reload Window**, and press Enter.

Open any `.odhtml` file (e.g. `odnetclient/books/templates/book_card.odhtml`). The extension will automatically discover `output/odhtml-lsp.exe`, activate syntax highlighting, and start the language server.

---

### Troubleshooting & Configuration

- **Verify Language Server Output**:
  In VS Code, open the **Output** panel (`Ctrl+Shift+U`) and select **odhtml Language Server** from the dropdown menu to see startup logs, discovered binary path, and server status.
- **Restart Language Server**:
  Press `Ctrl+Shift+P` and execute **odhtml: Restart Language Server**.
- **Custom Binary Path**:
  By default, the extension checks `output/odhtml-lsp.exe`, the active workspace folders, and the system `PATH`. If your binary is located elsewhere, configure it in VS Code Settings (`Ctrl+,`):
  ```json
  "odhtml.serverPath": "C:/path/to/output/odhtml-lsp.exe"
  ```

---

### Building the VS Code Extension from Source

The VS Code extension client is bundled using `esbuild` into a single standalone file with zero runtime dependencies. To rebuild the `.vsix` package:

```cmd
cd odhtml_lsp
npm install
npm run compile
npx @vscode/vsce package --no-dependencies --allow-missing-repository
```

This updates `odhtml_lsp/odhtml-lsp-0.1.0.vsix`.

---

### Using with Other Editors (Neovim / Helix / Zed)
Because `odhtml-lsp` is a standard LSP server communicating via JSON-RPC over stdio, it works out of the box with any LSP-compatible editor:

#### Helix (`~/.config/helix/languages.toml`)
```toml
[[language]]
name = "odhtml"
scope = "text.html.odhtml"
file-types = ["odhtml"]
roots = ["build.bat", "build.sh", "ols.json"]
language-servers = ["odhtml-lsp"]

[language-server.odhtml-lsp]
command = "output/odhtml-lsp"
```

#### Neovim (`nvim-lspconfig`)
```lua
local lspconfig = require('lspconfig')
local configs = require('lspconfig.configs')

if not configs.odhtml_lsp then
  configs.odhtml_lsp = {
    default_config = {
      cmd = { vim.fn.getcwd() .. '/output/odhtml-lsp.exe' },
      filetypes = { 'odhtml' },
      root_dir = lspconfig.util.root_pattern('build.bat', 'build.sh', 'ols.json'),
    },
  }
end

lspconfig.odhtml_lsp.setup({})
```

---

## Testing

Run test suites across all packages:

```cmd
odin test odnetlib
odin test odnetlib/html
odin test odnetgen
odin test odhtml_lsp
odin test odnetclient
```

## License

MIT

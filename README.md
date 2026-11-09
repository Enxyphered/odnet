# odnet

A simple, fast web server and HTML template engine for [Odin](https://odin-lang.org/).

`odnet` gives you the core building blocks to create full-stack web applications in Odin:
- **`odnetlib`**: An HTTP server with easy routing, path parameters (`/users/{id}`), and static file serving.
- **`odnetgen`**: A template compiler that turns `.odhtml` component files into plain Odin procedures.
- **`odhtml_lsp`**: A VS Code extension with syntax highlighting, autocomplete, and error checking for `.odhtml` files.
- **`odnetdemo`**: A complete sample application showing HTMX integration, server-side rendering, and routing.

---

## Table of Contents
- [Quickstart: Run the Demo](#quickstart-run-the-demo)
- [Starting a New Project](#starting-a-new-project)
- [How to Build Your App](#how-to-build-your-app)
- [Writing HTML Templates (`.odhtml`)](#writing-html-templates-odhtml)
- [Writing Web Handlers (`odnetlib`)](#writing-web-handlers-odnetlib)
- [VS Code Extension](#vs-code-extension)
- [Running Tests](#running-tests)
- [License](#license)

---

## Quickstart: Run the Demo

Want to see it in action first? Clone this repo and run the demo:

### Prerequisites
- [Odin compiler](https://odin-lang.org/docs/install/) installed and added to your `PATH`.
- *(Optional)* [Tailwind CSS standalone CLI](https://tailwindcss.com/blog/standalone-cli) if you want to rebuild the demo's CSS.

### Run on Windows
```cmd
git clone https://github.com/Enxyphered/odnet.git
cd odnet
build.bat
output\odnetdemo.exe --port 9090
```

### Run on Linux / macOS
```bash
git clone https://github.com/Enxyphered/odnet.git
cd odnet
chmod +x build.sh
./build.sh
./output/odnetdemo --port 9090
```

Open **`http://localhost:9090/home`** in your browser. You will see an interactive dashboard using HTMX and components.

---

## Starting a New Project

You don't have to clone the entire `odnet` repository to build your own app. You can just pull in `odnetlib` as a dependency.

### 1. Initialize your project
Create a project folder and initialize Git:
```cmd
mkdir my-app
cd my-app
git init
```

### 2. Add `odnetlib` as a submodule
Run this to download **only** the `odnetlib` folder into `lib/odnet`:
```cmd
git submodule add https://github.com/Enxyphered/odnet.git lib/odnet
cd lib/odnet
git sparse-checkout set --no-cone "/odnetlib/"
cd ../..
```

### 3. Create your `main.odin`
Create a basic web server in `main.odin`:

```odin
package main

import "core:fmt"
import http "lib/odnet/odnetlib"

handle_index :: proc(req: ^http.Request, res: ^http.Response) {
	http.response_set_body_string(res, "Hello from my Odin app!", "text/plain")
}

main :: proc() {
	cfg := http.DEFAULT_CONFIG
	cfg.port = 8080

	server: http.Server
	http.server_init(&server, cfg)

	http.server_get(&server, "/", handle_index)

	fmt.println("Server running on http://localhost:8080")
	http.server_start(&server)
}
```

### 4. Build and run
```cmd
odin build . -out:output\app.exe -o:speed
output\app.exe
```
Visit `http://localhost:8080` in your browser.

---

## How to Build Your App

Instead of typing build commands manually every time, you can drop a `build.bat` (Windows) or `build.sh` (Linux) in your project root. 

If your app uses `.odhtml` templates, this script will automatically download `odnetgen.exe` from GitHub releases to compile them before building Odin:

### Windows (`build.bat`)
```bat
@echo off
setlocal enabledelayedexpansion

if not exist output mkdir output

REM 1. Detect Odin source directory (src/ or root .)
set "ODIN_TARGET=."
if exist "src\*.odin" (
    set "ODIN_TARGET=src"
) else if not exist "*.odin" (
    echo [ERROR] No .odin files found in root or src/ directory.
    exit /b 1
)

REM 2. Compile Tailwind CSS if input.css (or Input.css) exists
set "INPUT_CSS="
if exist "input.css" set "INPUT_CSS=input.css"
if exist "Input.css" set "INPUT_CSS=Input.css"

if defined INPUT_CSS (
    set "TAILWIND_BIN="
    where tailwindcss >nul 2>nul
    if !ERRORLEVEL! EQU 0 (
        set "TAILWIND_BIN=tailwindcss"
    ) else if exist "output\tailwindcss.exe" (
        set "TAILWIND_BIN=output\tailwindcss.exe"
    ) else (
        echo [INFO] tailwindcss CLI not found on PATH. Downloading into output/...
        where curl >nul 2>nul
        if !ERRORLEVEL! EQU 0 (
            curl -s -L "https://github.com/tailwindlabs/tailwindcss/releases/download/v3.4.17/tailwindcss-windows-x64.exe" -o "output\tailwindcss.exe"
        ) else (
            powershell -Command "Invoke-WebRequest -Uri 'https://github.com/tailwindlabs/tailwindcss/releases/download/v3.4.17/tailwindcss-windows-x64.exe' -OutFile 'output\tailwindcss.exe' -UseBasicParsing"
        )
        set "TAILWIND_BIN=output\tailwindcss.exe"
    )

    if exist "!TAILWIND_BIN!" (
        echo [1/3] Compiling Tailwind CSS: !INPUT_CSS! -^> static/css/styles.css...
        if not exist "static\css" mkdir "static\css"
        !TAILWIND_BIN! -i !INPUT_CSS! -o static/css/styles.css --content "./**/*.{odhtml,html,odin}" --minify
    )
)

REM 3. Compile templates if templates/ exists in root or src/
set "HAS_TEMPLATES=0"
if exist "templates" set "HAS_TEMPLATES=1"
if exist "src\templates" set "HAS_TEMPLATES=1"

if "%HAS_TEMPLATES%"=="1" (
    set "ODNETGEN_BIN="
    where odnetgen >nul 2>nul
    if !ERRORLEVEL! EQU 0 (
        set "ODNETGEN_BIN=odnetgen"
    ) else if exist "output\odnetgen.exe" (
        set "ODNETGEN_BIN=output\odnetgen.exe"
    ) else (
        echo [INFO] odnetgen not found on PATH. Downloading into output/ from release...
        powershell -Command "Invoke-WebRequest -Uri 'https://github.com/Enxyphered/odnet/releases/download/0.1.0/odnetgen.exe' -OutFile 'output\odnetgen.exe' -UseBasicParsing"
        set "ODNETGEN_BIN=output\odnetgen.exe"
    )

    echo [2/3] Compiling templates with !ODNETGEN_BIN!...
    !ODNETGEN_BIN!
    if !ERRORLEVEL! NEQ 0 exit /b !ERRORLEVEL!
) else (
    echo [2/3] No templates directory found. Skipping template generation.
)

REM 4. Build Odin application
echo [3/3] Building Odin app from '!ODIN_TARGET!'...
odin build !ODIN_TARGET! -out:output\app.exe -o:speed
if %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%

echo ====================================================
echo [SUCCESS] Built output\app.exe
echo ====================================================
```

### Linux / macOS (`build.sh`)
```bash
#!/usr/bin/env bash
set -e

mkdir -p output

# 1. Detect Odin source directory (src/ or root .)
ODIN_TARGET="."
if [ -d "src" ] && ls src/*.odin &> /dev/null; then
    ODIN_TARGET="src"
elif ! ls *.odin &> /dev/null; then
    echo "[ERROR] No .odin files found in root or src/ directory."
    exit 1
fi

# 2. Compile Tailwind CSS if input.css (or Input.css) exists
INPUT_CSS=""
if [ -f "input.css" ]; then
    INPUT_CSS="input.css"
elif [ -f "Input.css" ]; then
    INPUT_CSS="Input.css"
fi

if [ -n "$INPUT_CSS" ]; then
    TAILWIND_BIN=""
    if command -v tailwindcss &> /dev/null; then
        TAILWIND_BIN="tailwindcss"
    elif [ -f "output/tailwindcss" ]; then
        TAILWIND_BIN="./output/tailwindcss"
    else
        echo "[INFO] tailwindcss CLI not found on PATH. Downloading into output/..."
        OS="linux-x64"
        if [ "$(uname)" = "Darwin" ]; then
            OS="macos-arm64"
        fi
        curl -s -L "https://github.com/tailwindlabs/tailwindcss/releases/download/v3.4.17/tailwindcss-$OS" -o "output/tailwindcss"
        chmod +x "output/tailwindcss"
        TAILWIND_BIN="./output/tailwindcss"
    fi

    if [ -n "$TAILWIND_BIN" ] && [ -x "$TAILWIND_BIN" ]; then
        echo "[1/3] Compiling Tailwind CSS: $INPUT_CSS -> static/css/styles.css..."
        mkdir -p static/css
        $TAILWIND_BIN -i "$INPUT_CSS" -o static/css/styles.css --content "./**/*.{odhtml,html,odin}" --minify
    fi
fi

# 3. Compile templates if templates/ exists in root or src/
if [ -d "templates" ] || [ -d "src/templates" ]; then
    ODNETGEN_BIN=""
    if command -v odnetgen &> /dev/null; then
        ODNETGEN_BIN="odnetgen"
    elif [ -f "output/odnetgen" ]; then
        ODNETGEN_BIN="./output/odnetgen"
    elif [ -f "./odnetgen" ]; then
        ODNETGEN_BIN="./odnetgen"
    fi

    if [ -n "$ODNETGEN_BIN" ]; then
        echo "[2/3] Compiling templates with $ODNETGEN_BIN..."
        $ODNETGEN_BIN
    else
        echo "[WARN] odnetgen not found on PATH or in output/. Skipping."
    fi
else
    echo "[2/3] No templates directory found. Skipping template generation."
fi

# 4. Build Odin application
echo "[3/3] Building Odin app from '$ODIN_TARGET'..."
odin build "$ODIN_TARGET" -out:output/app -o:speed
echo "[SUCCESS] Built output/app"
```

> **Tip: Using Tailwind CSS without Node / npm**  
> Download the official standalone executable from [Tailwind Standalone CLI](https://tailwindcss.com/blog/standalone-cli), rename it to `tailwindcss.exe` (or `tailwindcss`), and drop it in your tools folder (`C:\tools\odnet\` or system `PATH`). The build script will automatically detect and run it when `input.css` exists.

---

## Writing HTML Templates (`.odhtml`)

`odnetgen` compiles `.odhtml` files into type-safe Odin code (`template_gen.odin`). This means your templates have access to your Odin structs, loops, and types, and any syntax mistakes are caught at compile time.

### Where to put templates
Create a `templates/` folder in your project. Any file named `*.odhtml` inside it turns into an Odin procedure:
- `templates/button.odhtml` becomes `render_button(...)`
- `templates/home.odhtml` becomes `render_home(...)`

### Syntax Cheatsheet

| What you want to do | Syntax |
| :--- | :--- |
| Print a variable | `{name}` |
| Define props | `@props(name: string, count: int = 0)` |
| Import Odin packages | `@import "core:fmt"` |
| If / Else | `@if (is_logged_in) { ... } @else { ... }` |
| Switch / Case | `@switch (status) { @case ("active") { ... } @default { ... } }` |
| Loop over array / slice | `@foreach item, index in items { ... }` |
| Range loop | `@for i in 0..<5 { ... }` |
| Call another component | `@Button(text: "Submit")` |
| Component Slot | `{slot}` or `{slot:header}` |
| Escape `{` or `}` | `{{` and `}}` |

---

### Example: A Complete Component (`card.odhtml`)

```odhtml
@import "core:fmt"
@props(
  title: string,
  price: f32 = 0.0,
  in_stock: bool = true,
  tags: []string = nil
)

<div class="card">
  <h2>{title}</h2>
  <p>Price: ${fmt.tprintf("%.2f", price)}</p>

  @if (in_stock) {
    <span class="badge in-stock">Available</span>
  } @else {
    <span class="badge out-stock">Sold Out</span>
  }

  <ul>
    @foreach tag, idx in tags {
      <li>#{idx + 1}: {tag}</li>
    }
  </ul>
</div>
```

### Rendering Templates in Odin
To render that component in your server handler, just call the generated procedure:

```odin
package main

import "core:strings"
import http "lib/odnet/odnetlib"

handle_product :: proc(req: ^http.Request, res: ^http.Response) {
	b := strings.builder_make(context.temp_allocator)

	// Call the generated procedure from your template
	render_card(&b,
		title = "Mechanical Keyboard",
		price = 89.99,
		in_stock = true,
		tags = []string{"electronics", "gaming"},
	)

	http.response_set_html(res, strings.to_string(b))
}
```

---

## Writing Web Handlers (`odnetlib`)

### Routes & Parameters
You can set up GET and POST routes, read query strings, and use dynamic URL parameters:

```odin
package main

import "core:fmt"
import http "lib/odnet/odnetlib"

main :: proc() {
	cfg := http.DEFAULT_CONFIG
	cfg.port = 8080

	server: http.Server
	http.server_init(&server, cfg)

	// 1. Static route
	http.server_get(&server, "/", handle_home)

	// 2. Dynamic route with URL parameter {id}
	http.server_get(&server, "/users/{id}", handle_user)

	// 3. POST route
	http.server_post(&server, "/api/login", handle_login)

	// 4. Serve static files (CSS, JS, images)
	http.server_static(&server, "/static", "static")

	http.server_start(&server)
}

// Reading a URL parameter like /users/42
handle_user :: proc(req: ^http.Request, res: ^http.Response) {
	user_id, ok := http.get_param(req, "id")
	if !ok {
		res.status = .Bad_Request
		return
	}

	http.response_set_body_string(res, fmt.tprintf("User ID: %s", user_id), "text/plain")
}

// Sending JSON
handle_login :: proc(req: ^http.Request, res: ^http.Response) {
	http.response_set_json(res, "{\"success\": true}")
}
```

---

## Developer Tools (VS Code & CLI)

To get the full developer experience:

1. Download the tools from the [0.1.0 Release](https://github.com/Enxyphered/odnet/releases/tag/0.1.0):
   - `odnetgen.exe`: The template compiler.
   - `odhtml-lsp.exe`: The language server.
   - `odhtml-lsp-0.1.0.vsix`: The VS Code extension.
2. Put `odnetgen.exe` and `odhtml-lsp.exe` into a folder on your system `PATH` (such as `C:\tools\odnet\`):
   - When on your `PATH`, your build scripts can call `odnetgen` globally without downloading it per-project.
3. Install the extension in VS Code:
   ```cmd
   code --install-extension odhtml-lsp-0.1.0.vsix
   ```
4. Reload VS Code (`Ctrl+Shift+P` -> `Developer: Reload Window`).

You now get syntax highlighting, tag autocompletion, and real-time error checking inside all your `.odhtml` files.

---

## Running Tests

To run the built-in test suites across all packages:

```cmd
odin test odnetlib
odin test odnetlib/html
odin test odnetgen
odin test odhtml_lsp
odin test odnetdemo
```

---

## License

MIT

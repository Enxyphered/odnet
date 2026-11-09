#!/bin/bash
set -e

echo "===================================================="
echo "  Building odnet Project Stack (Linux)"
echo "===================================================="

# Ensure output directory exists
mkdir -p output

# 1. Compile Tailwind CSS if tailwindcss CLI is available in PATH
echo "[1/4] Checking Tailwind CSS Compilation..."
if command -v tailwindcss &> /dev/null; then
    echo "[INFO] Running Tailwind CLI compilation: odnetdemo/Input.css -> odnetdemo/static/css/Styles.css"
    tailwindcss -i odnetdemo/Input.css -o odnetdemo/static/css/Styles.css --minify
else
    echo "[INFO] 'tailwindcss' CLI not found in PATH. Using existing odnetdemo/static/css/Styles.css."
    echo "       (Refer to README.md to install the standalone Tailwind CLI executable)"
fi

# 2. Build odhtml Component Compiler (odnetgen) into output/
echo "[2/4] Building odhtml Component Compiler (odnetgen)..."
odin build odnetgen -out:output/odnetgen -o:speed

echo "[INFO] Building odhtml Language Server (odhtml-lsp)..."
odin build odhtml_lsp -out:output/odhtml-lsp -o:speed

# 3. Compile odhtml templates into type-safe Odin procs
echo "[3/4] Compiling odhtml templates..."
./output/odnetgen

# 4. Build odnetdemo executable into output/ for Linux
echo "[4/4] Building odnetdemo for Linux (epoll Multi-Reactor Engine)..."
odin build odnetdemo -out:output/odnetdemo -target:linux_amd64 -o:speed

# 5. Ensure VS Code Extension package exists
if [ ! -f "odhtml_lsp/odhtml-lsp-0.1.0.vsix" ]; then
    echo "[INFO] Packaging VS Code Extension: odhtml_lsp/odhtml-lsp-0.1.0.vsix..."
    if command -v npm &> /dev/null; then
        (cd odhtml_lsp && npm run compile && npx @vscode/vsce package --no-dependencies --allow-missing-repository)
    else
        echo "[WARN] 'npm' not found. Pre-built .vsix not found."
    fi
fi

echo "===================================================="
echo "[SUCCESS] Linux executable built: output/odnetdemo"
echo "===================================================="

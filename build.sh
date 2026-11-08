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
    echo "[INFO] Running Tailwind CLI compilation: odnetclient/Input.css -> odnetclient/static/css/Styles.css"
    tailwindcss -i odnetclient/Input.css -o odnetclient/static/css/Styles.css --minify
else
    echo "[INFO] 'tailwindcss' CLI not found in PATH. Using existing odnetclient/static/css/Styles.css."
    echo "       (Refer to README.md to install the standalone Tailwind CLI executable)"
fi

# 2. Build HTML Component Generator (odnetgen) into output/
echo "[2/4] Building HTML Component Compiler (odnetgen)..."
odin build odnetgen -out:output/odnetgen -o:speed

# 3. Compile HTML templates into type-safe Odin procs
echo "[3/4] Compiling HTML templates..."
./output/odnetgen

# 4. Build odnetclient executable into output/ for Linux
echo "[4/4] Building odnetclient for Linux (epoll Multi-Reactor Engine)..."
odin build odnetclient -out:output/odnetclient -target:linux_amd64 -o:speed
echo "===================================================="
echo "[SUCCESS] Linux executable built: output/odnetclient"
echo "===================================================="

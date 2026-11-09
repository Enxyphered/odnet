#!/bin/bash
set -e

echo "===================================================="
echo "  Setting up odhtml Language Server & VS Code Extension"
echo "===================================================="

# 1. Ensure output directory exists
mkdir -p output

# 2. Build native Odin language server
echo "[1/3] Building odhtml Language Server (output/odhtml-lsp)..."
odin build odhtml_lsp -out:output/odhtml-lsp -o:speed

# Copy to odhtml_lsp/ directory as fallback
cp output/odhtml-lsp odhtml_lsp/odhtml-lsp 2>/dev/null || true

# Copy to user-global directory (~/.local/bin) for system-wide access
mkdir -p "$HOME/.local/bin" 2>/dev/null || true
cp output/odhtml-lsp "$HOME/.local/bin/odhtml-lsp" 2>/dev/null && echo "[INFO] Global LSP binary updated at: $HOME/.local/bin/odhtml-lsp" || true

# 3. Package or verify VSIX package
if command -v npm &> /dev/null; then
    echo "[2/3] Packaging VS Code Extension..."
    (cd odhtml_lsp && npm run compile && npx @vscode/vsce package --no-dependencies --allow-missing-repository)
else
    if [ -f "odhtml_lsp/odhtml-lsp-0.1.0.vsix" ]; then
        echo "[2/3] Verified pre-built odhtml-lsp-0.1.0.vsix is ready."
    else
        echo "[ERROR] 'npm' not found and pre-built odhtml-lsp-0.1.0.vsix is missing."
        exit 1
    fi
fi

# 4. Install VSIX into VS Code
echo "[3/3] Installing extension into VS Code..."
if command -v code &> /dev/null; then
    code --install-extension odhtml_lsp/odhtml-lsp-0.1.0.vsix --force
    echo "===================================================="
    echo "[SUCCESS] odhtml LSP & VS Code extension installed!"
    echo ""
    echo "Next step: Press Ctrl+Shift+P in VS Code and select:"
    echo "           \"Developer: Reload Window\""
    echo "===================================================="
else
    echo "[WARN] 'code' command not found in PATH."
    echo "       Manually install by selecting 'Install from VSIX...' in VS Code"
    echo "       and choosing: odhtml_lsp/odhtml-lsp-0.1.0.vsix"
fi

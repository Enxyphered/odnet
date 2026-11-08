@echo off
setlocal enabledelayedexpansion

echo ====================================================
echo   Setting up odhtml Language Server ^& VS Code Extension
echo ====================================================

REM 1. Ensure output directory exists
if not exist output mkdir output

REM 2. Handle running server process if open in editor
if exist output\odhtml-lsp.exe.old del /f /q output\odhtml-lsp.exe.old >nul 2>nul
if exist output\odhtml-lsp.exe ren output\odhtml-lsp.exe odhtml-lsp.exe.old >nul 2>nul

REM 3. Build native Odin language server
echo [1/3] Building odhtml Language Server (output\odhtml-lsp.exe)...
odin build odhtml_lsp -out:output\odhtml-lsp.exe -o:speed
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Failed to compile odhtml-lsp.
    exit /b %ERRORLEVEL%
)
if exist output\odhtml-lsp.exe.old del /f /q output\odhtml-lsp.exe.old >nul 2>nul

REM Copy to odhtml_lsp/ directory as fallback
copy /y output\odhtml-lsp.exe odhtml_lsp\odhtml-lsp.exe >nul 2>nul

REM Copy to global tools directory for system-wide access (C:\tools\odhtml)
if not exist "C:\tools\odhtml" mkdir "C:\tools\odhtml" >nul 2>nul
copy /y output\odhtml-lsp.exe C:\tools\odhtml\odhtml-lsp.exe >nul 2>nul
if exist "C:\tools\odhtml\odhtml-lsp.exe" (
    echo [INFO] Global LSP binary updated at: C:\tools\odhtml\odhtml-lsp.exe
)

REM 4. Ensure VSIX package exists or build it
if not exist "odhtml_lsp\odhtml-lsp-0.1.0.vsix" (
    echo [2/3] Packaging VS Code Extension...
    where npm >nul 2>nul
    if %ERRORLEVEL% EQU 0 (
        pushd odhtml_lsp
        call npm run compile
        call npx @vscode/vsce package --no-dependencies --allow-missing-repository
        popd
    ) else (
        echo [ERROR] 'npm' not found and odhtml-lsp-0.1.0.vsix is missing.
        exit /b 1
    )
) else (
    echo [2/3] Verified odhtml-lsp-0.1.0.vsix is ready.
)

REM 5. Install VSIX into VS Code
echo [3/3] Installing extension into VS Code...
where code >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    call code --install-extension odhtml_lsp\odhtml-lsp-0.1.0.vsix --force
    echo ====================================================
    echo [SUCCESS] odhtml LSP ^& VS Code extension installed!
    echo.
    echo Next step: Press Ctrl+Shift+P in VS Code and select:
    echo            "Developer: Reload Window"
    echo ====================================================
) else (
    set "CODE_CMD=%LOCALAPPDATA%\Programs\Microsoft VS Code\bin\code.cmd"
    if exist "!CODE_CMD!" (
        call "!CODE_CMD!" --install-extension odhtml_lsp\odhtml-lsp-0.1.0.vsix --force
        echo ====================================================
        echo [SUCCESS] odhtml LSP ^& VS Code extension installed!
        echo.
        echo Next step: Press Ctrl+Shift+P in VS Code and select:
        echo            "Developer: Reload Window"
        echo ====================================================
    ) else (
        echo [WARN] 'code' command not found in PATH or standard directory.
        echo        Manually install by selecting "Install from VSIX..." in VS Code
        echo        and choosing: odhtml_lsp\odhtml-lsp-0.1.0.vsix
    )
)

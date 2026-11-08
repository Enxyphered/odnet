@echo off
setlocal enabledelayedexpansion

echo ====================================================
echo   Building odnet Project Stack
echo ====================================================

REM Ensure output directory exists
if not exist output mkdir output

REM 1. Compile Tailwind CSS if tailwindcss CLI is available in PATH
echo [1/4] Checking Tailwind CSS Compilation...
where tailwindcss >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    echo [INFO] Running Tailwind CLI compilation: odnetclient/Input.css -^> odnetclient/static/css/Styles.css
    tailwindcss -i odnetclient/Input.css -o odnetclient/static/css/Styles.css --minify
    if %ERRORLEVEL% NEQ 0 (
        echo [ERROR] Tailwind CSS compilation failed.
        exit /b %ERRORLEVEL%
    )
) else (
    echo [INFO] 'tailwindcss' CLI not found in PATH. Using existing odnetclient/static/css/Styles.css.
    echo        (Refer to README.md to install the standalone Tailwind CLI executable)
)

REM 2. Build HTML Component Generator (odnetgen) into output/
echo [2/4] Building HTML Component Compiler (odnetgen)...
odin build odnetgen -out:output\odnetgen.exe -o:speed
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Failed to build odnetgen.
    exit /b %ERRORLEVEL%
)

REM 3. Compile HTML templates into type-safe Odin procs
echo [3/4] Compiling HTML templates...
output\odnetgen.exe
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Template compilation failed.
    exit /b %ERRORLEVEL%
)

REM 4. Build odnetclient executable into output/
echo [4/4] Building odnetclient for Windows (IOCP Engine)...
odin build odnetclient -out:output\odnetclient.exe -o:speed
if %ERRORLEVEL% EQU 0 (
    echo ====================================================
    echo [SUCCESS] Windows executable built: output\odnetclient.exe
    echo ====================================================
) else (
    echo [ERROR] Windows build failed.
    exit /b %ERRORLEVEL%
)

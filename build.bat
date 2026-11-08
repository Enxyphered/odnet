@echo off
echo Building odnetclient for Windows (IOCP Engine)...
odin build odnetclient -out:odnetclient.exe -o:speed
if %ERRORLEVEL% EQU 0 (
    echo [SUCCESS] Windows executable built: odnetclient.exe
) else (
    echo [ERROR] Windows build failed.
    exit /b %ERRORLEVEL%
)

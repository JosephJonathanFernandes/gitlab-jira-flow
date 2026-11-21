@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0git_flow.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

:: If launched by double-clicking in Windows Explorer, pause so the window does not close immediately
echo %CMDCMDLINE% | findstr /i /c:"%~nx0" >nul 2>&1
if not errorlevel 1 (
    echo.
    pause
)
exit /b %EXIT_CODE%

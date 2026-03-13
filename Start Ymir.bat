@echo off
title CreatureCodex Session Manager
cd /d "%~dp0"

where python >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo  Python not found! Please install Python 3.10+ from https://www.python.org
    echo  Make sure to check "Add Python to PATH" during install.
    echo.
    pause
    exit /b 1
)

python session.py %*
echo.
pause

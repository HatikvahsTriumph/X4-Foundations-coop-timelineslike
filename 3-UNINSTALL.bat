@echo off
chcp 65001 >nul
title X4MP LAN pack - UNINSTALL
echo.
echo   Removing the X4MP extensions and the role config ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Recurse -File '%~dp0' -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\x4mp_install.ps1" -Uninstall
echo.
echo   --- done. you can close this window. ---
pause >nul

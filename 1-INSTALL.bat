@echo off
chcp 65001 >nul
title X4MP LAN pack - INSTALL
echo.
echo   X4MP LAN pack - installer starting ...
echo.
rem Files coming out of a downloaded zip carry a "blocked" mark; PowerShell refuses
rem to load a blocked script under some policies - clear it for this folder first.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Recurse -File '%~dp0' -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\x4mp_install.ps1" %*
echo.
echo   --- done. you can close this window. ---
pause >nul

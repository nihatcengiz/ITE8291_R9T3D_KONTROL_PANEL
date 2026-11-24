@echo off
if "%~1"=="" (set R=kirmizi) else (set R=%~1)
if "%~2"=="" (set B=50) else (set B=%~2)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ite.ps1" renk %R% -Parlaklik %B% -Kaydet

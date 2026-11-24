@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File \"%~dp0panel.ps1\"' -Verb RunAs"

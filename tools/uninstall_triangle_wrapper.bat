@echo off
setlocal

set "FEMM_BIN="
if exist "C:\femm42\bin\triangle_real.exe" set "FEMM_BIN=C:\femm42\bin"
if not defined FEMM_BIN if exist "C:\Program Files\femm42\bin\triangle_real.exe" set "FEMM_BIN=C:\Program Files\femm42\bin"
if not defined FEMM_BIN if exist "C:\Program Files (x86)\femm42\bin\triangle_real.exe" set "FEMM_BIN=C:\Program Files (x86)\femm42\bin"

if not defined FEMM_BIN (
  echo Could not find triangle_real.exe. Nothing restored.
  pause
  exit /b 1
)

copy /Y "%FEMM_BIN%\triangle_real.exe" "%FEMM_BIN%\triangle.exe" >nul
echo Restored original triangle.exe in "%FEMM_BIN%".
pause

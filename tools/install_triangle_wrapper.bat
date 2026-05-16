@echo off
setlocal

rem Installs TriangleWrapper.cs as FEMM's triangle.exe shim.
rem It renames the original triangle.exe to triangle_real.exe, then compiles
rem the wrapper to triangle.exe. Run uninstall_triangle_wrapper.bat to restore.

set "ROOT=%~dp0"
set "FEMM_BIN="

if exist "C:\femm42\bin\triangle.exe" set "FEMM_BIN=C:\femm42\bin"
if not defined FEMM_BIN if exist "C:\Program Files\femm42\bin\triangle.exe" set "FEMM_BIN=C:\Program Files\femm42\bin"
if not defined FEMM_BIN if exist "C:\Program Files (x86)\femm42\bin\triangle.exe" set "FEMM_BIN=C:\Program Files (x86)\femm42\bin"

if not defined FEMM_BIN (
  echo Could not find FEMM triangle.exe. Edit FEMM_BIN in this script.
  pause
  exit /b 1
)

set "CSC="
if exist "%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not defined CSC if exist "%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

if not defined CSC (
  echo Could not find csc.exe from .NET Framework.
  pause
  exit /b 1
)

if not exist "%ROOT%TriangleWrapper.cs" (
  echo Missing "%ROOT%TriangleWrapper.cs".
  pause
  exit /b 1
)

if not exist "%FEMM_BIN%\triangle_real.exe" (
  copy /Y "%FEMM_BIN%\triangle.exe" "%FEMM_BIN%\triangle_real.exe" >nul
)

"%CSC%" /nologo /target:exe /out:"%FEMM_BIN%\triangle.exe" "%ROOT%TriangleWrapper.cs"
if errorlevel 1 (
  echo Failed to compile wrapper.
  pause
  exit /b 1
)

echo Installed Triangle wrapper in "%FEMM_BIN%".
echo FEMM will now capture mesh files to Z:\captured_femm_triangle when solving Z:\tutorial.fem.
pause

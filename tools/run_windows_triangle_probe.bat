@echo off
setlocal

rem Run Windows FEMM's triangle.exe on the macOS-generated .poly input.
rem Expected location: this .bat and tutorial_from_macos.poly on the shared Z: drive.

set "ROOT=%~dp0"
set "TRIANGLE="

if exist "%ROOT%triangle.exe" set "TRIANGLE=%ROOT%triangle.exe"
if not defined TRIANGLE if exist "C:\femm42\bin\triangle.exe" set "TRIANGLE=C:\femm42\bin\triangle.exe"
if not defined TRIANGLE if exist "C:\femm42\triangle.exe" set "TRIANGLE=C:\femm42\triangle.exe"
if not defined TRIANGLE if exist "C:\Program Files\femm42\bin\triangle.exe" set "TRIANGLE=C:\Program Files\femm42\bin\triangle.exe"
if not defined TRIANGLE if exist "C:\Program Files (x86)\femm42\bin\triangle.exe" set "TRIANGLE=C:\Program Files (x86)\femm42\bin\triangle.exe"

if not defined TRIANGLE (
  echo Could not find triangle.exe.
  echo Copy triangle.exe next to this batch file or edit TRIANGLE in the script.
  pause
  exit /b 1
)

if not exist "%ROOT%tutorial_from_macos.poly" (
  echo Missing "%ROOT%tutorial_from_macos.poly".
  pause
  exit /b 1
)

set "OUT=%ROOT%win_triangle_on_mac_poly"
if not exist "%OUT%" mkdir "%OUT%"
copy /Y "%ROOT%tutorial_from_macos.poly" "%OUT%\tutorial.poly" >nul

pushd "%OUT%"
"%TRIANGLE%" -p -P -j -q33.000000 -e -A -a -z -Q -I tutorial
set "RC=%ERRORLEVEL%"
popd

echo triangle=%TRIANGLE% > "%ROOT%win_triangle_probe_summary.txt"
echo exit_code=%RC% >> "%ROOT%win_triangle_probe_summary.txt"

if exist "%OUT%\tutorial.node" (
  for /f "usebackq tokens=1,2,3,4" %%a in ("%OUT%\tutorial.node") do (
    echo node_header=%%a %%b %%c %%d >> "%ROOT%win_triangle_probe_summary.txt"
    goto got_node
  )
)
:got_node

if exist "%OUT%\tutorial.ele" (
  for /f "usebackq tokens=1,2,3" %%a in ("%OUT%\tutorial.ele") do (
    echo ele_header=%%a %%b %%c >> "%ROOT%win_triangle_probe_summary.txt"
    goto got_ele
  )
)
:got_ele

type "%ROOT%win_triangle_probe_summary.txt"
pause
exit /b %RC%

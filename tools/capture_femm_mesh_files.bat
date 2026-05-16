@echo off
setlocal enabledelayedexpansion

rem Start this, then immediately run Z:\regression_probe.lua in FEMM.
rem FEMM deletes tutorial.poly/.node/.ele/.edge after loading the mesh, so this
rem tight loop tries to copy them out during the short window where they exist.

set "ROOT=%~dp0"
set "OUT=%ROOT%captured_femm_mesh"
if not exist "%OUT%" mkdir "%OUT%"

echo Watching %ROOT% for FEMM mesh files...
echo Run Z:\regression_probe.lua in FEMM now. This window will stop after a while.

for /l %%i in (1,1,200000) do (
  if exist "%ROOT%tutorial.poly" copy /Y "%ROOT%tutorial.poly" "%OUT%\tutorial.poly" >nul
  if exist "%ROOT%tutorial.node" copy /Y "%ROOT%tutorial.node" "%OUT%\tutorial.node" >nul
  if exist "%ROOT%tutorial.ele"  copy /Y "%ROOT%tutorial.ele"  "%OUT%\tutorial.ele"  >nul
  if exist "%ROOT%tutorial.edge" copy /Y "%ROOT%tutorial.edge" "%OUT%\tutorial.edge" >nul
  if exist "%ROOT%tutorial.pbc"  copy /Y "%ROOT%tutorial.pbc"  "%OUT%\tutorial.pbc"  >nul
)

echo Done. Captured files, if any:
dir "%OUT%"
pause

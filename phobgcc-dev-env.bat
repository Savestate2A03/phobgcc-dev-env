@echo off

::  .--------------------------------------------------.
:: | mostly just runs the adjacent powershell script    |
:: | because batch files are easy to run (double click) |
::  *--------------------------------------------------*
:: script designed by rei wolf (https://github.com/Savestate2A03/)

if /i "%~1"=="child" goto child
if /i "%~1"=="buildask" goto buildask
start "PhobGCC Development Environment" "%ComSpec%" /d /c ""%~f0" child"
goto :eof

:child
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0script.ps1" -OpenShell
if errorlevel 1 goto :eof
goto :eof

:buildask

set "BUILD_FOLDER=build-rp2040"

doskey configure_firmware=echo. $T echo. ################################################### $T echo. # Configuring the PhobGCC firmware build files... # $T echo. ################################################### $T echo. $T cmake -S "%%CD%%\PhobGCC\rp2040" -B "%%CD%%\%BUILD_FOLDER%" -G Ninja -DPICO_PLATFORM=rp2040 -DCMAKE_BUILD_TYPE=Release
doskey build_firmware=echo. $T echo. #################################### $T echo. # Building the PhobGCC firmware... # $T echo. #################################### $T echo. $T cmake --build "%%CD%%\%BUILD_FOLDER%" --parallel

echo. Run the pre-configured build commands?
echo.
echo.   cmake -S "%%CD%%\PhobGCC\rp2040" -B "%%CD%%\%BUILD_FOLDER%" -G Ninja -DPICO_PLATFORM=rp2040 -DCMAKE_BUILD_TYPE=Release
echo.   cmake --build "%%CD%%\%BUILD_FOLDER%" --parallel
echo.
echo. Alternatively, you can choose [N] and instead run these aliases when you are ready:
echo.
echo.   configure_firmware
echo.   build_firmware
echo.
echo. [Y] will be chosen if you wait 30s
echo.

choice /c YN /t 30 /d Y /m " Choice ->"
if %errorlevel% equ 1 goto :yes
if %errorlevel% equ 2 goto :no

:yes
echo. Running pre-configured build commands...
echo.
cmake -S "%CD%\PhobGCC\rp2040" -B "%CD%\%BUILD_FOLDER%" -G Ninja -DPICO_PLATFORM=rp2040 -DCMAKE_BUILD_TYPE=Release
cmake --build "%CD%\%BUILD_FOLDER%" --parallel
echo.
echo. ...Build has finished!
echo.
echo.  If it was successful, you will be able to find the built firmware here:
echo.     %CD%\%BUILD_FOLDER%\phobgcc_rp2040.uf2
echo.
goto :eof

:no
echo.
echo. Automatic running of pre-configured build commands skipped!
echo.
echo. When you end up compiling, you'll be able to find the built firmware here:
echo.    %CD%\%BUILD_FOLDER%\phobgcc_rp2040.uf2
echo.
goto :eof


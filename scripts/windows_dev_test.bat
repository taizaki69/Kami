@echo off
rem Kami Windows development helper: runs SwiftPM tests for a package using
rem the VS Build Tools environment + user-local Swift toolchain.
rem Usage: windows_dev_test.bat <package-dir> [test|build]
setlocal enabledelayedexpansion

if "%~1"=="" (
    echo Usage: windows_dev_test.bat ^<package-dir^> [test^|build]
    exit /b 2
)

rem Resolve the package while still in the caller's working directory. The
rem helper changes directory to the Swift toolchain below, so keeping a
rem relative path here would make --package-path point inside that toolchain.
for %%I in ("%~1") do set "PKG=%%~fI"
set "ACTION=%~2"
if "%ACTION%"=="" set "ACTION=test"

call "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1

set "SWIFT_HOME=%LOCALAPPDATA%\Programs\Swift\Toolchains\6.3.3+Asserts\usr\bin"
set "PATH=%SWIFT_HOME%;%PATH%"
cd /d "%SWIFT_HOME%"

if /i "%ACTION%"=="build" (
    swift-build.exe --package-path "%PKG%"
) else (
    swift-test.exe --package-path "%PKG%"
)
exit /b %ERRORLEVEL%

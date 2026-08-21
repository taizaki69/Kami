@echo off
rem Kami Windows development helper: runs SwiftPM tests for a package using
rem the VS Build Tools environment + user-local Swift toolchain.
rem Usage: windows_dev_test.bat <package-dir> [test|build]
setlocal enabledelayedexpansion

set "PKG=%~1"
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

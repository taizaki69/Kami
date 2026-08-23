@echo off
rem Kami Windows development helper: runs SwiftPM tests for a package using
rem the installed Visual Studio C++ environment + user-local Swift toolchain.
rem Usage: windows_dev_test.bat <package-dir> [test|build]
setlocal enabledelayedexpansion

if "%~1"=="" (
    echo Usage: windows_dev_test.bat ^<package-dir^> [test^|build]
    exit /b 2
)

rem Resolve the package while still in the caller's working directory.
for %%I in ("%~1") do set "PKG=%%~fI"
set "ACTION=%~2"
if "%ACTION%"=="" set "ACTION=test"

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VS_INSTALL="
set "VCVARS="
if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%I in (`"%VSWHERE%" -latest -products * -property installationPath`) do set "VS_INSTALL=%%I"
)
if defined VS_INSTALL (
    if exist "!VS_INSTALL!\VC\Auxiliary\Build\vcvars64.bat" set "VCVARS=!VS_INSTALL!\VC\Auxiliary\Build\vcvars64.bat"
    if not defined VCVARS if exist "!VS_INSTALL!\VC\Auxiliary\Build\vcvarsall.bat" set "VCVARS=!VS_INSTALL!\VC\Auxiliary\Build\vcvarsall.bat"
)
if not defined VCVARS (
    echo Unable to find a Visual Studio installation with the C++ toolchain.
    exit /b 1
)

for %%I in ("!VCVARS!") do set "VCVARS_NAME=%%~nxI"
if /i "!VCVARS_NAME!"=="vcvarsall.bat" (
    call "!VCVARS!" x64 >nul 2>&1
) else (
    call "!VCVARS!" >nul 2>&1
)
if errorlevel 1 (
    echo Unable to initialize the Visual Studio x64 build environment.
    exit /b 1
)
if not exist "!VCToolsInstallDir!bin\Hostx64\x64\link.exe" if /i "!VCVARS_NAME!"=="vcvarsall.bat" (
    set "VC_TOOLS_VERSION="
    for /d %%I in ("!VS_INSTALL!\VC\Tools\MSVC\*") do if exist "%%~fI\bin\Hostx64\x64\link.exe" set "VC_TOOLS_VERSION=%%~nxI"
    if defined VC_TOOLS_VERSION call "!VCVARS!" x64 -vcvars_ver=!VC_TOOLS_VERSION! >nul 2>&1
)
where link.exe >nul 2>&1
if errorlevel 1 (
    echo Unable to find link.exe. Install the Visual Studio C++ x64 tools.
    exit /b 1
)

set "SWIFT_BIN="
for /f "delims=" %%I in ('where swift-test.exe 2^>nul') do if not defined SWIFT_BIN for %%J in ("%%I") do set "SWIFT_BIN=%%~dpJ"
if not defined SWIFT_BIN (
    for /d %%I in ("%LOCALAPPDATA%\Programs\Swift\Toolchains\*") do if not defined SWIFT_BIN if exist "%%~fI\usr\bin\swift-test.exe" set "SWIFT_BIN=%%~fI\usr\bin\"
)
if not defined SWIFT_BIN (
    echo Unable to find swift-test.exe. Install Swift 5.9 or newer first.
    exit /b 1
)
set "SWIFT_RUNTIME="
for /d %%I in ("%LOCALAPPDATA%\Programs\Swift\Runtimes\*") do if not defined SWIFT_RUNTIME if exist "%%~fI\usr\bin\swiftCore.dll" set "SWIFT_RUNTIME=%%~fI\usr\bin\"
if not defined SDKROOT (
    for /d %%I in ("%LOCALAPPDATA%\Programs\Swift\Platforms\*") do if not defined SDKROOT if exist "%%~fI\Windows.platform\Developer\SDKs\Windows.sdk" set "SDKROOT=%%~fI\Windows.platform\Developer\SDKs\Windows.sdk\"
)
if not defined SDKROOT (
    echo Unable to find the Swift Windows SDK.
    exit /b 1
)
set "PATH=!SWIFT_BIN!;!SWIFT_RUNTIME!;!PATH!"
pushd "!SWIFT_BIN!" >nul
if errorlevel 1 (
    echo Unable to enter the Swift toolchain directory.
    exit /b 1
)

if /i "%ACTION%"=="build" (
    "!SWIFT_BIN!swift-build.exe" --package-path "%PKG%"
) else (
    "!SWIFT_BIN!swift-test.exe" --package-path "%PKG%"
)
set "RESULT=!ERRORLEVEL!"
popd
exit /b !RESULT!

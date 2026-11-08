@echo off
title Fix Apple USB Drivers
echo ========================================
echo   Fix Apple USB Sub-Devices
echo ========================================
echo.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERROR] Need Administrator permission
    echo.
    echo Right-click this file and choose
    echo    Run as administrator
    echo.
    pause
    exit /b 1
)

echo [1/6] Admin OK
echo.

set DRV=C:\Windows\System32\DriverStore\FileRepository\appleusb.inf_amd64_58854158183af679

echo [2/6] Check driver folder...
if not exist "%DRV%\AppleUsb.inf" (
    echo [ERROR] AppleUsb.inf not found
    pause
    exit /b 1
)
echo     OK
echo.

echo [3/6] Stop Apple Mobile Device Service...
net stop "Apple Mobile Device Service" >nul 2>&1
echo.

echo [4/6] Install driver to store...
pnputil /add-driver "%DRV%\AppleUsb.inf" /install
echo.

echo [5/6] Rescan hardware...
pnputil /scan-devices
echo.

echo Waiting 15 seconds...
timeout /t 15 >nul
echo.

echo [6/6] Restart Apple service...
net start "Apple Mobile Device Service" >nul 2>&1
timeout /t 3 >nul
echo.

echo ========================================
echo   Current Apple device status:
echo ========================================
powershell -NoProfile -Command "Get-PnpDevice | Where-Object { $_.InstanceId -like '*VID_05AC*' } | Select-Object Status, FriendlyName | Format-Table -AutoSize"

echo.
echo ========================================
echo   Expected: all 4 devices show OK
echo   If still Error, take a screenshot
echo ========================================
pause
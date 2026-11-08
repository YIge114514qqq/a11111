@echo off
chcp 65001 >nul
title LectureBuddy - iPhone 驱动绑定
echo ========================================
echo   iPhone 驱动绑定工具
echo ========================================
echo.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [错误] 权限不足
    echo.
    echo 请右键这个文件，选择「以管理员身份运行」
    pause
    exit /b 1
)
echo [1/5] 管理员权限 OK
echo.

echo [2/5] 重启 Apple Mobile Device Service...
net stop "Apple Mobile Device Service" >nul 2>&1
net start "Apple Mobile Device Service" >nul 2>&1
echo     完成
echo.

echo [3/5] 安装 Apple USB 驱动...
pnputil /add-driver "C:\Windows\System32\DriverStore\FileRepository\appleusb.inf_amd64_58854158183af679\AppleUsb.inf" /install
echo.

echo [4/5] 重新扫描硬件...
pnputil /scan-devices
echo.

echo [5/5] 等待设备初始化（10 秒）...
timeout /t 10 >nul
echo.

echo ========================================
echo   当前 iPhone 状态：
echo ========================================
powershell -NoProfile -Command "Get-PnpDevice | Where-Object { $_.InstanceId -like '*VID_05AC*' } | Select-Object Status, FriendlyName, Problem | Format-Table -AutoSize"
echo.
echo ========================================
echo   如果状态变成 OK：
echo     拔掉 iPhone，等 3 秒再插回去
echo     手机会弹出「要信任此电脑吗」
echo   如果还是 Error：
echo     把这窗口截图发给我
echo ========================================
pause
@echo off
chcp 65001 >nul
title Sideloadly - 管理员模式启动

echo ========================================
echo   以管理员权限准备 iPhone 连接
echo ========================================
echo.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [错误] 需要管理员权限
    echo 请右键本文件 - 以管理员身份运行
    pause
    exit /b 1
)
echo [1/4] 管理员权限 OK
echo.

echo [2/4] 关闭残留进程...
taskkill /F /IM sideloadly.exe >nul 2>&1
taskkill /F /IM sideloadlydaemon.exe >nul 2>&1
echo     完成
echo.

echo [3/4] 重启 Apple Mobile Device Service...
net stop "Apple Mobile Device Service" >nul 2>&1
timeout /t 2 >nul
net start "Apple Mobile Device Service" >nul 2>&1
echo     完成
echo.

echo [4/4] 等待服务就绪...
timeout /t 5 >nul
echo.

echo ========================================
echo   正在以管理员权限启动 Sideloadly
echo ========================================
echo.
echo 启动后请检查 Device 下拉框
echo 应该能看到 iPhone (iPhone 16 Pro Max)
echo.

start "" "C:\Program Files\Sideloadly\sideloadly.exe"

if not exist "C:\Program Files\Sideloadly\sideloadly.exe" (
    echo [提示] 没在默认路径找到，尝试打开安装目录...
    start "" "%LOCALAPPDATA%\Programs\Sideloadly\sideloadly.exe"
)

echo 如果 Sideloadly 没起来，请手动到安装目录双击 sideloadly.exe
pause

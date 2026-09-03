@echo off
chcp 65001 >nul
title OpenStoryline
setlocal EnableDelayedExpansion

:: ============================================================
:: OpenStoryline Windows Launcher (调试入口)
:: 正式安装包使用 app_tray.py（托盘 + 原生窗口，无控制台）。
:: 本脚本保留用于开发调试：带控制台直接看 Web 日志。
:: 功能: 设置环境 -> 首次启动下载模型 -> 启动 MCP + Web 服务 -> 打开浏览器
:: ============================================================

:: 获取安装根目录（start.bat 在 launcher\ 下，往上一级），并转为绝对路径
set ROOT=%~dp0..
for %%i in ("%ROOT%") do set ROOT=%%~fi

set PYTHON=%ROOT%\runtime\python\python.exe
set PYTHONW=%ROOT%\runtime\python\pythonw.exe

:: 设置内嵌 Python 和 FFmpeg 的路径
set PATH=%ROOT%\runtime\python;%ROOT%\runtime\python\Scripts;%ROOT%\runtime\ffmpeg;%PATH%
set PYTHONHOME=%ROOT%\runtime\python
set PYTHONPATH=%ROOT%\app\src
set OPENSTORYLINE_CONFIG=%ROOT%\app\config.toml
set PYTHONIOENCODING=utf-8

:: 创建输出目录
if not exist "%ROOT%\app\outputs\media" mkdir "%ROOT%\app\outputs\media"

:: ============================================================
:: 首次启动：下载模型文件（约 106MB）
:: ============================================================
if not exist "%ROOT%\app\.storyline\models\.downloaded" (
    echo.
    echo [OpenStoryline] 首次启动，正在下载模型文件（约 106MB），请耐心等待...
    if not exist "%ROOT%\app\.storyline\models" mkdir "%ROOT%\app\.storyline\models"
    curl.exe -L --retry 3 --retry-delay 2 -o "%ROOT%\app\.storyline\models.zip" "https://image-url-2-feature-1251524319.cos.ap-shanghai.myqcloud.com/openstoryline/models.zip"
    if errorlevel 1 (
        echo [错误] 模型下载失败，请检查网络连接后重新启动。
        pause
        exit /b 1
    )
    tar -xf "%ROOT%\app\.storyline\models.zip" -C "%ROOT%\app\.storyline\models"
    if errorlevel 1 (
        echo [错误] 模型解压失败，请删除 %ROOT%\app\.storyline\models.zip 后重新启动。
        pause
        exit /b 1
    )
    del /f /q "%ROOT%\app\.storyline\models.zip"
    type nul > "%ROOT%\app\.storyline\models\.downloaded"
    echo [OpenStoryline] 模型下载完成。
)

:: ============================================================
:: 启动服务（MCP server + Web 服务，与原项目 run.sh 保持一致）
:: ============================================================
cd /d "%ROOT%\app"

:: 后台启动 MCP server（无窗口），并记录 PID 便于退出时清理
set MCP_PID=
for /f "usebackq delims=" %%p in (`powershell -NoProfile -Command "(Start-Process -FilePath '%PYTHONW%' -ArgumentList '-m','open_storyline.mcp.server' -WorkingDirectory '%ROOT%\app' -PassThru).ProcessId"`) do set MCP_PID=%%p

:: 后台轮询，Web 服务就绪后自动打开浏览器（最多等 60 秒）
start "" /min cmd /v:on /c "set /a n=0 & :L & curl.exe -s -o nul --max-time 2 http://127.0.0.1:7860 && (start "" http://127.0.0.1:7860 & exit) & set /a n+=1 & if !n! geq 60 (start "" http://127.0.0.1:7860 & exit) & timeout /t 1 /nobreak >nul & goto L"

echo [OpenStoryline] 正在启动服务，浏览器将自动打开 http://127.0.0.1:7860 ...
echo [OpenStoryline] 使用完毕后直接关闭本窗口即可停止服务。
echo.
"%PYTHON%" -m uvicorn agent_fastapi:app --host 127.0.0.1 --port 7860

:: Web 服务退出后，收尾 MCP 进程
if defined MCP_PID taskkill /pid %MCP_PID% /t /f >nul 2>&1

echo.
echo [OpenStoryline] 服务已停止。
pause

#!/bin/bash
# ============================================================
# verify.sh — 打包前自检：确认构建所需的文件都已就位
# 用法: ./verify.sh [windows|macos]
# ============================================================
set -e
cd "$(dirname "$0")/.."

TARGET="${1:-all}"
FAIL=0

check() { # check <路径> <说明>
  if [ -e "$1" ]; then
    echo "  [OK] $2"
  else
    echo "  [缺失] $2 -> $1"
    FAIL=1
  fi
}

if [ "$TARGET" = "windows" ] || [ "$TARGET" = "all" ]; then
  echo "== Windows =="
  check runtime/python-win/python.exe "Windows Python"
  check runtime/python-win/Lib/site-packages/fastapi "依赖: fastapi"
  check runtime/python-win/Lib/site-packages/moviepy "依赖: moviepy"
  check runtime/ffmpeg-win/ffmpeg.exe "FFmpeg (Windows)"
  check installer/windows/setup.iss "Inno Setup 脚本"
  check launcher/start.bat "Windows 启动器"
  check launcher/app_tray.py "Windows GUI 启动器 (托盘)"
  check runtime/python-win/Lib/site-packages/pystray "依赖: pystray"
  check runtime/python-win/Lib/site-packages/webview "依赖: pywebview"
fi

if [ "$TARGET" = "macos" ] || [ "$TARGET" = "all" ]; then
  echo "== macOS =="
  check runtime/python-mac/python/bin/python3 "macOS Python"
  check runtime/python-mac/python/lib/python3.11/site-packages/fastapi "依赖: fastapi"
  check runtime/python-mac/python/lib/python3.11/site-packages/moviepy "依赖: moviepy"
  check runtime/ffmpeg-mac/ffmpeg "FFmpeg (macOS)"
  check installer/macos/build_dmg.sh "DMG 打包脚本"
  check installer/macos/Info.plist "Info.plist"
  check launcher/launcher.sh "macOS 启动器"
fi

echo "== 公共 =="
check source/agent_fastapi.py "项目源码"
check source/config.toml "配置文件"
check resources/bgms "资源: BGM"
check resources/fonts "资源: 字体"
check resources/script_templates/meta.json "资源: 脚本模板索引"
check resources/fonts/font_info.json "资源: 字体索引"
check resources/tts/tts_providers.json "资源: TTS 配置"
check assets/icon.ico "图标 (ico)"
check assets/icon.icns "图标 (icns)"

if [ $FAIL -eq 0 ]; then
  echo ""
  echo "自检通过 ✔"
else
  echo ""
  echo "自检未通过，请先补齐缺失项 ✘"
  exit 1
fi

#!/bin/bash
# ============================================================
# OpenStoryline macOS Launcher
# 打包后位置: OpenStoryline.app/Contents/MacOS/launcher
# 功能: 设置环境 -> 首次启动下载模型 -> 启动 MCP + Web 服务 -> 打开浏览器
# ============================================================

# 获取 .app 内 Resources 目录（launcher 在 Contents/MacOS/ 下）
ROOT="$(cd "$(dirname "$0")/../Resources" && pwd)"
PYTHON="$ROOT/runtime/python/bin/python3"
LOG_DIR="$HOME/Library/Logs"
LOG_FILE="$LOG_DIR/OpenStoryline.log"
PORT=7860
MODELS_URL="https://image-url-2-feature-1251524319.cos.ap-shanghai.myqcloud.com/openstoryline/models.zip"

mkdir -p "$LOG_DIR"
exec >> "$LOG_FILE" 2>&1
echo ""
echo "==== OpenStoryline 启动 $(date '+%Y-%m-%d %H:%M:%S') ===="

notify() {
  osascript -e "display notification \"$1\" with title \"OpenStoryline\"" >/dev/null 2>&1 || true
}

die() {
  osascript -e "display dialog \"$1\" with title \"OpenStoryline\" buttons {\"好\"} default button 1 with icon stop" >/dev/null 2>&1 || true
  echo "[错误] $1"
  exit 1
}

# ---------- 环境设置 ----------
export PATH="$ROOT/runtime/python/bin:$ROOT/runtime/ffmpeg:$PATH"
export PYTHONHOME="$ROOT/runtime/python"
export PYTHONPATH="$ROOT/app/src"
export OPENSTORYLINE_CONFIG="$ROOT/app/config.toml"
export PYTHONIOENCODING=utf-8

mkdir -p "$ROOT/app/outputs/media"

# ---------- 可写性检查（App Translocation / 未去 quarantine 时 .app 可能只读） ----------
if ! touch "$ROOT/app/.storyline_writetest" >/dev/null 2>&1; then
  die "应用目录不可写。请先在终端执行：xattr -cr /Applications/OpenStoryline.app 然后重新打开。"
fi
rm -f "$ROOT/app/.storyline_writetest"

# ---------- 首次启动：下载模型文件（约 106MB） ----------
if [ ! -f "$ROOT/app/.storyline/models/.downloaded" ]; then
  notify "首次启动，正在下载模型文件（约 106MB）..."
  mkdir -p "$ROOT/app/.storyline/models"
  if ! curl -L --retry 3 --retry-delay 2 -o "$ROOT/app/.storyline/models.zip" "$MODELS_URL"; then
    die "模型下载失败，请检查网络连接后重新启动。"
  fi
  if ! unzip -oq "$ROOT/app/.storyline/models.zip" -d "$ROOT/app/.storyline/models/"; then
    die "模型解压失败，请删除应用包内的 models.zip 后重新启动。"
  fi
  rm -f "$ROOT/app/.storyline/models.zip"
  touch "$ROOT/app/.storyline/models/.downloaded"
  notify "模型下载完成，正在启动服务..."
fi

# ---------- 启动服务（MCP server + Web 服务，与 run.sh 保持一致） ----------
cd "$ROOT/app" || die "找不到应用目录: $ROOT/app"

"$PYTHON" -m open_storyline.mcp.server &
MCP_PID=$!

"$PYTHON" -m uvicorn agent_fastapi:app --host 127.0.0.1 --port "$PORT" &
WEB_PID=$!

cleanup() {
  kill "$MCP_PID" "$WEB_PID" >/dev/null 2>&1 || true
}
trap cleanup INT TERM EXIT

# 轮询等待 Web 服务就绪后打开浏览器（最多等 60 秒；超时不硬开浏览器，改为报错）
(
  for i in $(seq 1 60); do
    if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT"; then
      open "http://127.0.0.1:$PORT"
      exit 0
    fi
    if ! kill -0 "$WEB_PID" 2>/dev/null; then
      break   # Web 进程已死，不用等满 60 秒
    fi
    sleep 1
  done
  osascript -e "display dialog \"服务启动失败，请查看日志：$LOG_FILE\" with title \"OpenStoryline\" buttons {\"好\"} default button 1 with icon stop" >/dev/null 2>&1 || true
) &

notify "服务启动中，浏览器将自动打开 http://127.0.0.1:$PORT"

# 等待 Web 进程；退出时清理 MCP 进程
wait "$WEB_PID"
EXIT_CODE=$?
kill "$MCP_PID" >/dev/null 2>&1 || true
echo "==== OpenStoryline 退出 (code=$EXIT_CODE) ===="
exit $EXIT_CODE

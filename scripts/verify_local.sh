#!/bin/bash
# ============================================================
# verify_local.sh — 本地验证（Linux 构建机 / 任意机器）
# 用系统 Python（需已安装 source/requirements.txt 的依赖）
# 直接拉起 MCP + Web 双进程，验证：
#   1. 服务能启动（不报 ImportError / 配置错误）
#   2. Web UI 可访问 (http://127.0.0.1:7860)
#   3. MCP server 端口可用 (127.0.0.1:8001)
# 用法: ./verify_local.sh [python 解释器，默认 python3]
# ============================================================
set -e
cd "$(dirname "$0")/../source"
PY="${1:-python3}"
PORT=7860
MCP_PORT=8001
export PYTHONPATH="$(pwd)/src"

echo "== 清理旧进程 =="
pkill -f "open_storyline.mcp.server" 2>/dev/null || true
pkill -f "uvicorn agent_fastapi:app" 2>/dev/null || true
sleep 1

echo "== 启动 MCP server =="
"$PY" -m open_storyline.mcp.server > /tmp/verify_mcp.log 2>&1 &
MCP_PID=$!

echo "== 启动 Web 服务 =="
"$PY" -m uvicorn agent_fastapi:app --host 127.0.0.1 --port $PORT > /tmp/verify_web.log 2>&1 &
WEB_PID=$!

cleanup() {
  kill $MCP_PID $WEB_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "== 等待服务就绪 =="
WEB_OK=0
for i in $(seq 1 60); do
  if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT"; then
    WEB_OK=1; break
  fi
  if ! kill -0 $WEB_PID 2>/dev/null; then
    echo "[失败] Web 进程已退出，日志："
    tail -20 /tmp/verify_web.log
    exit 1
  fi
  sleep 1
done
[ $WEB_OK -eq 1 ] || { echo "[失败] 60 秒内 Web 服务未就绪"; tail -20 /tmp/verify_web.log; exit 1; }
echo "[OK] Web 服务就绪 http://127.0.0.1:$PORT"

echo "== 校验 UI 页面 =="
curl -s "http://127.0.0.1:$PORT" | head -c 200; echo

echo "== 校验 MCP 端口 =="
if kill -0 $MCP_PID 2>/dev/null; then
  echo "[OK] MCP server 存活 (pid=$MCP_PID)"
else
  echo "[失败] MCP 进程已退出，日志："
  tail -20 /tmp/verify_mcp.log
  exit 1
fi

echo ""
echo "== 验证通过 ✔ 服务双进程正常，UI 可访问 =="
echo "日志: /tmp/verify_web.log /tmp/verify_mcp.log"

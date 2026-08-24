#!/bin/bash
# ============================================================
# prepare_deps.sh — 新机器 git clone 后恢复大资产（这些都不入 git）
# 用法: ./prepare_deps.sh [macos-arm64]
# 流程: resources -> python-build-standalone -> build_mac_deps.sh -> ffmpeg/ffprobe
# 已有 runtime/ 的完整工作目录不需要跑这个脚本。
# ============================================================
set -e
cd "$(dirname "$0")/.."

PLATFORM="${1:-macos-arm64}"
PYVER="3.11.9"
PBS_TAG="20240415"
PBS_BASE="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}"
COS="https://image-url-2-feature-1251524319.cos.ap-shanghai.myqcloud.com/openstoryline"

echo "== 1/4 静态资源 resources/ (446MB) =="
if [ -z "$(ls -A resources 2>/dev/null)" ]; then
  mkdir -p resources .downloads
  [ -f .downloads/resource.zip ] || curl -fL --retry 3 -C - -o .downloads/resource.zip "$COS/resource.zip"
  unzip -oq .downloads/resource.zip -d resources/
else
  echo "已存在，跳过"
fi

echo "== 2/4 python-build-standalone ($PLATFORM) =="
case "$PLATFORM" in
  macos-arm64) PBS_FILE="cpython-${PYVER}+${PBS_TAG}-aarch64-apple-darwin-install_only.tar.gz"; RT_DIR="runtime/python-mac" ;;
  macos-x64)   echo "[错误] Intel Mac 依赖尚未自动化，参考 README 手动处理"; exit 1 ;;
  *) echo "用法: $0 [macos-arm64]"; exit 1 ;;
esac
if [ ! -x "$RT_DIR/python/bin/python3" ]; then
  mkdir -p .downloads "$RT_DIR"
  [ -f ".downloads/$PBS_FILE" ] || curl -fL --retry 3 -o ".downloads/$PBS_FILE" "$PBS_BASE/$PBS_FILE"
  tar -xzf ".downloads/$PBS_FILE" -C "$RT_DIR"
else
  echo "已存在，跳过"
fi

echo "== 3/4 依赖安装 + 自检 =="
./scripts/build_mac_deps.sh

echo "== 4/4 ffmpeg/ffprobe (arm64 静态版) =="
mkdir -p runtime/ffmpeg-mac .downloads
if [ ! -x runtime/ffmpeg-mac/ffmpeg ]; then
  [ -f .downloads/ffmpeg9arm.zip ] || curl -fL --retry 3 -o .downloads/ffmpeg9arm.zip "https://www.osxexperts.net/ffmpeg9arm.zip"
  unzip -oq .downloads/ffmpeg9arm.zip -d runtime/ffmpeg-mac/ && rm -rf runtime/ffmpeg-mac/__MACOSX
  chmod +x runtime/ffmpeg-mac/ffmpeg
fi
if [ ! -x runtime/ffmpeg-mac/ffprobe ]; then
  [ -f .downloads/ffprobe9arm.zip ] || curl -fL --retry 3 -o .downloads/ffprobe9arm.zip "https://www.osxexperts.net/ffprobe9arm.zip"
  unzip -oq .downloads/ffprobe9arm.zip -d runtime/ffmpeg-mac/ && rm -rf runtime/ffmpeg-mac/__MACOSX
  chmod +x runtime/ffmpeg-mac/ffprobe
fi

echo ""
echo "完成。可继续: ./scripts/bundle_mac.sh 或 installer/macos/build_dmg.sh"

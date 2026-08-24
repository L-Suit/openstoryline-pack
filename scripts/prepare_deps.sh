#!/bin/bash
# ============================================================
# prepare_deps.sh — 在新机器上重新准备运行时依赖
#
# 一般情况下不需要运行本脚本：openstoryline-pack 目录里已经
# 预装好了 Windows / macOS 两套 Python 运行时和依赖，直接打包即可。
#
# 仅当你需要在某台机器上从头重建时使用，例如：
#   ./prepare_deps.sh macos-arm64    # Apple Silicon
#   ./prepare_deps.sh macos-x64      # Intel Mac
# ============================================================
set -e
cd "$(dirname "$0")/.."

PLATFORM="${1:-macos-arm64}"
PYVER="3.11.9"
PBS_TAG="20240415"
PBS_BASE="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}"

case "$PLATFORM" in
  macos-arm64) PBS_FILE="cpython-${PYVER}+${PBS_TAG}-aarch64-apple-darwin-install_only.tar.gz"
               RT_DIR="runtime/python-mac"
               PIP_PLATFORMS="--platform macosx_11_0_arm64 --platform macosx_12_0_arm64 --platform macosx_13_0_arm64 --platform macosx_14_0_arm64 --platform macosx_15_0_arm64 --platform macosx_10_9_universal2" ;;
  macos-x64)   PBS_FILE="cpython-${PYVER}+${PBS_TAG}-x86_64-apple-darwin-install_only.tar.gz"
               RT_DIR="runtime/python-mac-x64"
               PIP_PLATFORMS="--platform macosx_11_0_x86_64 --platform macosx_10_9_x86_64 --platform macosx_10_9_universal2" ;;
  *) echo "用法: $0 [macos-arm64|macos-x64]"; exit 1 ;;
esac

echo "=== 1/3 下载 python-build-standalone ==="
mkdir -p .downloads "$RT_DIR"
[ -f ".downloads/$PBS_FILE" ] || curl -fL --retry 3 -o ".downloads/$PBS_FILE" "$PBS_BASE/$PBS_FILE"
rm -rf "$RT_DIR/python"
tar -xzf ".downloads/$PBS_FILE" -C "$RT_DIR"

echo "=== 2/3 安装项目依赖（pip --platform 交叉安装，仅 wheel） ==="
rm -rf "$RT_DIR/python/lib/python3.11/site-packages"
python3 -m pip install --target "$RT_DIR/python/lib/python3.11/site-packages" \
  $PIP_PLATFORMS \
  --python-version 3.11 --implementation cp --abi cp311 --abi none \
  --only-binary=:all: \
  -r source/requirements.txt

echo "=== 3/3 完成 ==="
echo "运行时位置: $RT_DIR/python"
echo "提示: macOS 还需要 runtime/ffmpeg-mac/ 下的 ffmpeg、ffprobe 静态二进制"
echo "      (evermeet.cx 下载，注意其为 x86_64 版；Apple Silicon 建议用 brew install ffmpeg 后拷贝)"

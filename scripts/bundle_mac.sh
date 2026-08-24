#!/bin/bash
# ============================================================
# bundle_mac.sh — 生成 macOS 打包材料包（在构建机上执行）
# 产物: ../openstoryline-mac-bundle.tar.gz
# 用户把 tar 包拷到自己的 Mac 上，解压后执行：
#   cd openstoryline-pack/installer/macos
#   ./build_dmg.sh        # 可选先 brew install create-dmg
# 即可得到 build/macos/OpenStoryline-1.0.0-macOS.dmg
# ============================================================
set -e
PACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PACK_DIR"

# 自检关键文件
for f in runtime/python-mac/python/bin/python3 \
         runtime/ffmpeg-mac/ffmpeg \
         launcher/launcher.sh \
         installer/macos/build_dmg.sh \
         assets/icon.icns; do
  [ -e "$f" ] || { echo "[错误] 缺少 $f"; exit 1; }
done
[ -n "$(ls -A resources 2>/dev/null)" ] || { echo "[错误] resources/ 为空"; exit 1; }

mkdir -p build/macos   # 保证 dmg 输出目录存在

OUT="$PACK_DIR/../openstoryline-mac-bundle.tar.gz"
echo "打包中（约 2GB，可能需要几分钟）..."
cd "$(dirname "$PACK_DIR")"
tar -czf "$OUT" \
    --exclude='openstoryline-pack/.downloads' \
    --exclude='openstoryline-pack/.tmp_icon' \
    --exclude='openstoryline-pack/runtime/python-win' \
    --exclude='openstoryline-pack/runtime/ffmpeg-win' \
    --exclude='openstoryline-pack/installer/windows' \
    --exclude='openstoryline-pack/launcher/start.bat' \
    --exclude='openstoryline-pack/build/windows' \
    --exclude='openstoryline-pack/source/.git' \
    --exclude='*.pyc' \
    --exclude='openstoryline-mac-bundle.tar.gz' \
    --exclude='openstoryline-pack/openstoryline-mac-bundle.tar.gz' \
    openstoryline-pack

ls -lh "$OUT"
echo ""
echo "完成。拷到 Mac 后："
echo "  tar xzf openstoryline-mac-bundle.tar.gz"
echo "  cd openstoryline-pack/installer/macos && ./build_dmg.sh"

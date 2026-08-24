#!/bin/bash
# ============================================================
# OpenStoryline macOS 打包脚本
# 用法: cd installer/macos && ./build_dmg.sh
# 前置: runtime/python-mac/（含解压好的 python-build-standalone）、
#       runtime/ffmpeg-mac/（ffmpeg、ffprobe）、source/、resources/
# ============================================================
set -e

APP_NAME="OpenStoryline"
VERSION="1.0.0"
BUILD_DIR="../../build/macos"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="$APP_NAME-$VERSION-macOS.dmg"

cd "$(dirname "$0")"

echo "=== 构建 $APP_NAME.app ==="

# 清理旧产物
rm -rf "$APP_DIR" "$BUILD_DIR/$DMG_NAME"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

# 复制 Info.plist
cp ./Info.plist "$APP_DIR/Contents/"

# 复制启动器
cp ../../launcher/launcher.sh "$APP_DIR/Contents/MacOS/launcher"
chmod +x "$APP_DIR/Contents/MacOS/launcher"

# 复制图标（若存在）
if [ -f ../../assets/icon.icns ]; then
  cp ../../assets/icon.icns "$APP_DIR/Contents/Resources/"
else
  echo "[警告] assets/icon.icns 不存在，应用将使用默认图标"
fi

# 复制 Python 运行时
echo "复制 Python 运行时..."
if [ ! -d ../../runtime/python-mac/python ]; then
  echo "[错误] runtime/python-mac/python 不存在，请先解压 python-build-standalone" >&2
  exit 1
fi
mkdir -p "$APP_DIR/Contents/Resources/runtime"
cp -R ../../runtime/python-mac/python "$APP_DIR/Contents/Resources/runtime/python"

# 复制 FFmpeg / ffprobe
echo "复制 FFmpeg..."
mkdir -p "$APP_DIR/Contents/Resources/runtime/ffmpeg"
cp ../../runtime/ffmpeg-mac/ffmpeg "$APP_DIR/Contents/Resources/runtime/ffmpeg/"
[ -f ../../runtime/ffmpeg-mac/ffprobe ] && cp ../../runtime/ffmpeg-mac/ffprobe "$APP_DIR/Contents/Resources/runtime/ffmpeg/"
chmod +x "$APP_DIR/Contents/Resources/runtime/ffmpeg/"*

# 复制项目源码（排除 .git）
echo "复制项目源码..."
rsync -a --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='resource' --exclude='.storyline/models' \
  ../../source/ "$APP_DIR/Contents/Resources/app/"

# 复制静态资源到 app/resource（config.toml 相对路径基于 config.toml 所在目录解析）
echo "复制静态资源..."
if [ -d ../../resources ] && [ -n "$(ls -A ../../resources 2>/dev/null)" ]; then
  cp -R ../../resources/ "$APP_DIR/Contents/Resources/app/resource/"
else
  echo "[警告] resources/ 为空，app 内将缺少字体/BGM 等资源"
fi

# 创建输出目录（模型在首次启动时由 launcher 下载）
mkdir -p "$APP_DIR/Contents/Resources/app/outputs/media"

# 去除扩展属性（减少 Gatekeeper 问题）
xattr -cr "$APP_DIR"

echo "=== 创建 DMG ==="

# 方式一：使用 create-dmg（推荐，更美观）
if command -v create-dmg &> /dev/null; then
  create-dmg \
    --volname "$APP_NAME $VERSION" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "$APP_NAME.app" 175 200 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 425 200 \
    "$BUILD_DIR/$DMG_NAME" \
    "$APP_DIR" || {
      # create-dmg 失败时回退到 hdiutil
      echo "[警告] create-dmg 失败，回退到 hdiutil"
      hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$APP_DIR" -ov -format UDZO "$BUILD_DIR/temp.dmg"
      mv "$BUILD_DIR/temp.dmg" "$BUILD_DIR/$DMG_NAME"
    }
else
  # 方式二：使用 hdiutil（macOS 自带），staging 目录里附加 Applications 快捷方式
  STAGE="$BUILD_DIR/dmg_stage"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp -R "$APP_DIR" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$BUILD_DIR/temp.dmg"
  mv "$BUILD_DIR/temp.dmg" "$BUILD_DIR/$DMG_NAME"
  rm -rf "$STAGE"
fi

echo "=== 完成 ==="
echo "产物: $BUILD_DIR/$DMG_NAME"
echo ""
echo "注意：未签名应用首次打开需右键→打开，或执行："
echo "  xattr -cr /Applications/$APP_NAME.app"

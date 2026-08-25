#!/bin/bash
# ============================================================
# build_win_deps.sh — 一键重建 Windows (win_amd64 / py3.11) 依赖环境
# 用法: ./scripts/build_win_deps.sh        # 在 Linux 构建机上跑（交叉安装纯 wheel）
# 流程: python-build-standalone -> dry-run 出清单 -> curl 下载 -> 离线安装 -> 自检
# 坑已内建: torch 走 PyTorch CPU 源(+cpu 无 cuda 依赖)、langgraph-prebuilt 固定 1.0.8、
#           下载走 fetch_wheels.py 断点续传、全新安装不用 --upgrade
# ============================================================
set -e
cd "$(dirname "$0")/.."

W=.downloads/wheels-win
RT=runtime/python-win
T=$RT/Lib/site-packages
ALIYUN="https://mirrors.aliyun.com/pypi/simple/"
PYVER="3.11.9"
PBS_TAG="20240415"
PBS_FILE="cpython-${PYVER}+${PBS_TAG}-x86_64-pc-windows-msvc-install_only.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_FILE}"

PF=(--platform win_amd64 --python-version 3.11 --implementation cp --abi cp311 --abi none --only-binary=:all:)

echo "== [1/5] python-build-standalone (win64) =="
if [ ! -x "$RT/python.exe" ]; then
  mkdir -p .downloads "$RT"
  [ -f ".downloads/$PBS_FILE" ] || curl -fL --retry 3 -o ".downloads/$PBS_FILE" "$PBS_URL"
  rm -rf /tmp/pbs-win && mkdir -p /tmp/pbs-win
  tar -xzf ".downloads/$PBS_FILE" -C /tmp/pbs-win
  cp -R /tmp/pbs-win/python/. "$RT/"
else
  echo "已存在，跳过"
fi

echo "== [2/5] 生成 wheel 清单 (dry-run) =="
python3 -m pip install --dry-run --target "$T" "${PF[@]}" --timeout 60 --retries 5 \
  -i "$ALIYUN" --extra-index-url https://download.pytorch.org/whl/cpu \
  --report /tmp/win_report.json -r requirements-win.txt > /dev/null 2>&1

echo "== [3/5] curl 下载 wheels =="
python3 scripts/fetch_wheels.py /tmp/win_report.json "$W" --exclude torch

echo "== [4/5] 离线安装 =="
rm -rf "$T" && mkdir -p "$T"
python3 -m pip install --target "$T" "${PF[@]}" --no-index --find-links "$W" \
  -r requirements-win.txt 2>&1 | tail -1

echo "== [5/5] 自检 =="
python3 - "$T" <<'EOF'
import os, sys
T = sys.argv[1]
pe = elf = 0
for root, dirs, files in os.walk(T):
    for f in files:
        if f.endswith(('.pyd', '.dll')):
            with open(os.path.join(root, f), 'rb') as fh:
                m = fh.read(2)
            if m == b'MZ': pe += 1
            elif m == b'\x7fE': elf += 1
checks = ['torch', 'fastapi', 'uvicorn', 'langchain', 'langgraph/_internal', 'filelock',
          'sentence_transformers', 'transformers', 'faiss', 'av', 'moviepy']
bad = [c for c in checks if not os.path.exists(os.path.join(T, c))]
print(f'二进制: PE {pe} / ELF {elf} {"✓" if elf == 0 else "✘"}')
print(f'目录检查: {"全部存在 ✓" if not bad else "缺失 " + str(bad)}')
sys.exit(1 if (bad or elf) else 0)
EOF

echo ""
echo "完成。编译安装包: xvfb-run -a wine 'C:\\InnoSetup7\\ISCC.exe' 'Z:<本目录绝对路径>\\installer\\windows\\setup.iss'"

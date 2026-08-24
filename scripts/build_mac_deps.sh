#!/bin/bash
# ============================================================
# build_mac_deps.sh — 一键重建 macOS(arm64 / py3.11) 依赖环境
# 用法: ./scripts/build_mac_deps.sh
# 流程: dry-run 出 wheel 清单 -> curl 断点下载(阿里云镜像) -> 三遍离线安装 -> 自检
# 所有已知坑已内建:
#   - torch 的 cuda marker 陷阱: torch 系全部 --no-deps 直装
#   - langgraph 命名空间包被 --upgrade 冲掉: 每次从空目录全新安装, 不用 --upgrade
#   - filelock/safetensors 漏装: pass3 显式包含
#   - langgraph-prebuilt 固定 1.0.8 (requirements-mac-pass1.txt 内)
#   - pip 长连接易断: 下载走 scripts/fetch_wheels.py (curl 续传)
# ============================================================
set -e
cd "$(dirname "$0")/.."

W=.downloads/wheels-mac
T=runtime/python-mac/python/lib/python3.11/site-packages
ALIYUN="https://mirrors.aliyun.com/pypi/simple/"
TORCH_VERSION=2.11.0

PF=(--platform macosx_11_0_arm64 --platform macosx_12_0_arm64 --platform macosx_13_0_arm64 \
    --platform macosx_14_0_arm64 --platform macosx_15_0_arm64 --platform macosx_10_9_universal2 \
    --python-version 3.11 --implementation cp --abi cp311 --abi none --only-binary=:all:)

mkdir -p "$W"

echo "== [1/5] 生成 pass1 wheel 清单 (dry-run, 只解析不下载) =="
python3 -m pip install --dry-run --target "$T" "${PF[@]}" --timeout 60 --retries 5 \
  -i "$ALIYUN" --report /tmp/mac_pass1_report.json -r requirements-mac-pass1.txt > /dev/null 2>&1

echo "== [2/5] curl 下载 pass1 wheels =="
python3 scripts/fetch_wheels.py /tmp/mac_pass1_report.json "$W" --exclude torch

echo "== [3/5] 下载 torch 系 wheels (--no-deps) =="
python3 -m pip download -d "$W" --no-deps "${PF[@]}" --timeout 120 --retries 5 -i "$ALIYUN" \
  "torch==$TORCH_VERSION" transnetv2_pytorch==1.0.5 sentence-transformers==5.2.2 \
  langchain-huggingface==1.2.0 "transformers==4.57.6" tokenizers==0.22.2 \
  huggingface_hub==0.36.2 hf-xet filelock safetensors 2>&1 | tail -1

echo "== [4/5] 全新安装(三遍, 不用 --upgrade) =="
rm -rf "$T" && mkdir -p "$T"
python3 -m pip install --target "$T" "${PF[@]}" --no-index --find-links "$W" \
  -r requirements-mac-pass1.txt 2>&1 | tail -1
python3 -m pip install --target "$T" "${PF[@]}" --no-index --find-links "$W" --no-deps \
  "torch==$TORCH_VERSION" transnetv2_pytorch==1.0.5 2>&1 | tail -1
python3 -m pip install --target "$T" "${PF[@]}" --no-index --find-links "$W" --no-deps \
  transformers==4.57.6 tokenizers==0.22.2 huggingface_hub==0.36.2 hf-xet filelock safetensors \
  sentence-transformers==5.2.2 langchain-huggingface==1.2.0 2>&1 | tail -1

echo "== [5/5] 自检 =="
python3 - "$T" <<'EOF'
import os, sys
T = sys.argv[1]
checks = ['langgraph/_internal', 'langgraph/graph', 'langgraph/checkpoint', 'langgraph/prebuilt',
          'langgraph_sdk', 'filelock', 'safetensors', 'torch', 'sentence_transformers',
          'transformers', 'huggingface_hub', 'tokenizers', 'faiss', 'av', 'uvloop', 'mcp',
          'langchain', 'langchain_core', 'fastapi', 'uvicorn', 'moviepy', 'librosa']
bad = [c for c in checks if not os.path.exists(os.path.join(T, c))]
elf = macho = 0
for root, dirs, files in os.walk(T):
    for f in files:
        if f.endswith(('.so', '.dylib')):
            with open(os.path.join(root, f), 'rb') as fh:
                m = fh.read(4)
            if m == b'\x7fELF': elf += 1
            elif m in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'): macho += 1
print(f'目录检查: {"全部存在 ✓" if not bad else "缺失 " + str(bad)}')
print(f'二进制: Mach-O {macho} / ELF {elf} {"✓" if elf == 0 else "✘ 有 Linux 二进制混入!"}')
sys.exit(1 if (bad or elf) else 0)
EOF

echo ""
echo "完成。接下来: ./scripts/bundle_mac.sh 或 installer/macos/build_dmg.sh"

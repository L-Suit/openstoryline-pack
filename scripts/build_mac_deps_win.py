#!/usr/bin/env python3
"""
build_mac_deps_win.py — 在 Windows 上交叉构建 macOS arm64 依赖环境
改编自 build_mac_deps.sh，适配 Windows 执行环境
"""
import os
import sys
import subprocess
import shutil

ROOT = r"D:\Pycharm-project\openstoryline-pack"
PYTHON = r"C:\Users\李世豪\FireRed-OpenStoryline\.venv\Scripts\python.exe"
PIP = [PYTHON, "-m", "pip"]
T = os.path.join(ROOT, "runtime", "python-mac", "python", "lib", "python3.11", "site-packages")
W = os.path.join(ROOT, ".downloads", "wheels-mac")
ALIYUN = "https://mirrors.aliyun.com/pypi/simple/"
TORCH_VERSION = "2.11.0"
PROXY = "http://127.0.0.1:7897"

PF = [
    "--platform", "macosx_11_0_arm64",
    "--platform", "macosx_12_0_arm64",
    "--platform", "macosx_13_0_arm64",
    "--platform", "macosx_14_0_arm64",
    "--platform", "macosx_15_0_arm64",
    "--platform", "macosx_10_9_universal2",
    "--python-version", "3.11",
    "--implementation", "cp",
    "--abi", "cp311",
    "--abi", "none",
    "--only-binary=:all:",
]

PROXY_ENV = {**os.environ, "http_proxy": PROXY, "https_proxy": PROXY, "HTTP_PROXY": PROXY, "HTTPS_PROXY": PROXY}


def run(cmd, env=None, **kwargs):
    """Run a command, print first line of output, and check return code."""
    print(f"  > {' '.join(cmd[:6])}{'...' if len(cmd) > 6 else ''}")
    result = subprocess.run(cmd, capture_output=True, text=True, env=env or os.environ, **kwargs)
    if result.stdout:
        lines = result.stdout.strip().split('\n')
        for line in lines[-3:]:
            print(f"    {line}")
    if result.returncode != 0:
        print(f"  [ERROR] return code {result.returncode}")
        if result.stderr:
            for line in result.stderr.strip().split('\n')[-5:]:
                print(f"    stderr: {line}")
        return False
    return True


def main():
    os.chdir(ROOT)
    os.makedirs(W, exist_ok=True)

    print("=" * 60)
    print("OpenStoryline macOS arm64 依赖构建 (Windows 交叉编译)")
    print("=" * 60)

    # Step 1: pip dry-run 出 wheel 清单
    print("\n== [1/5] 生成 pass1 wheel 清单 (dry-run, 只解析不下载) ==")
    report_file = os.path.join(ROOT, ".downloads", "mac_pass1_report.json")
    cmd = PIP + ["install", "--dry-run", "--target", T] + PF + [
        "--timeout", "60", "--retries", "5",
        "-i", ALIYUN,
        "--report", report_file,
        "-r", "requirements-mac-pass1.txt"
    ]
    if not run(cmd, env=PROXY_ENV):
        print("dry-run 失败，请检查网络后重试")
        return 1
    print("  [OK] wheel 清单已生成")

    # Step 2: curl 下载 pass1 wheels (排除 torch)
    print("\n== [2/5] curl 下载 pass1 wheels ==")
    cmd = [PYTHON, "scripts/fetch_wheels.py", report_file, W, "--exclude", "torch"]
    if not run(cmd, env=PROXY_ENV):
        print("下载 pass1 wheels 失败")
        return 1

    # Step 3: 下载 torch 系 wheels (--no-deps)
    print("\n== [3/5] 下载 torch 系 wheels (--no-deps) ==")
    torch_pkgs = [
        f"torch=={TORCH_VERSION}",
        "transnetv2_pytorch==1.0.5",
        "sentence-transformers==5.2.2",
        "langchain-huggingface==1.2.0",
        "transformers==4.57.6",
        "tokenizers==0.22.2",
        "huggingface_hub==0.36.2",
        "hf-xet", "filelock", "safetensors",
    ]
    cmd = PIP + ["download", "-d", W, "--no-deps"] + PF + [
        "--timeout", "120", "--retries", "5",
        "-i", ALIYUN
    ] + torch_pkgs
    if not run(cmd, env=PROXY_ENV):
        print("下载 torch 系 wheels 失败")
        return 1

    # Step 4: 全新安装(三遍, 不用 --upgrade)
    print("\n== [4/5] 全新安装(三遍, 不用 --upgrade) ==")

    # 清空 site-packages
    if os.path.exists(T):
        shutil.rmtree(T)
    os.makedirs(T, exist_ok=True)

    # Pass 1: 安装 requirements-mac-pass1.txt
    print("  Pass 1: requirements-mac-pass1.txt")
    cmd = PIP + ["install", "--target", T] + PF + [
        "--no-index", "--find-links", W,
        "-r", "requirements-mac-pass1.txt"
    ]
    if not run(cmd):
        print("Pass 1 安装失败")
        return 1

    # Pass 2: 安装 torch + transnetv2 (--no-deps)
    print("  Pass 2: torch + transnetv2")
    cmd = PIP + ["install", "--target", T] + PF + [
        "--no-index", "--find-links", W, "--no-deps",
        f"torch=={TORCH_VERSION}", "transnetv2_pytorch==1.0.5"
    ]
    if not run(cmd):
        print("Pass 2 安装失败")
        return 1

    # Pass 3: 安装 transformers/sentence-transformers 等 (--no-deps)
    print("  Pass 3: transformers + sentence-transformers + ...")
    cmd = PIP + ["install", "--target", T] + PF + [
        "--no-index", "--find-links", W, "--no-deps",
        "transformers==4.57.6", "tokenizers==0.22.2",
        "huggingface_hub==0.36.2", "hf-xet",
        "filelock", "safetensors",
        "sentence-transformers==5.2.2", "langchain-huggingface==1.2.0"
    ]
    if not run(cmd):
        print("Pass 3 安装失败")
        return 1

    # Step 5: 自检
    print("\n== [5/5] 自检 ==")
    checks = [
        'langgraph/_internal', 'langgraph/graph', 'langgraph/checkpoint', 'langgraph/prebuilt',
        'langgraph_sdk', 'filelock', 'safetensors', 'torch', 'sentence_transformers',
        'transformers', 'huggingface_hub', 'tokenizers', 'faiss', 'av', 'uvloop', 'mcp',
        'langchain', 'langchain_core', 'fastapi', 'uvicorn', 'moviepy', 'librosa'
    ]
    bad = [c for c in checks if not os.path.exists(os.path.join(T, c))]
    if bad:
        print(f"  [缺失] {bad}")
    else:
        print("  目录检查: 全部存在 OK")

    # Check for ELF binaries (should be Mach-O only)
    elf_count = 0
    macho_count = 0
    for dirpath, dirnames, filenames in os.walk(T):
        for f in filenames:
            if f.endswith(('.so', '.dylib')):
                fpath = os.path.join(dirpath, f)
                try:
                    with open(fpath, 'rb') as fh:
                        magic = fh.read(4)
                    if magic == b'\x7fELF':
                        elf_count += 1
                    elif magic in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'):
                        macho_count += 1
                except:
                    pass

    print(f"  二进制: Mach-O {macho_count} / ELF {elf_count}")
    if elf_count > 0:
        print("  [ERROR] 有 Linux 二进制混入!")
        return 1

    print("\n" + "=" * 60)
    print("构建完成!")
    print("=" * 60)
    return 0


if __name__ == '__main__':
    sys.exit(main())

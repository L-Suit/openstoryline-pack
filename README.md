# OpenStoryline 桌面安装包封装（openstoryline-pack）

> `source/` 为上游 [FireRed-OpenStoryline](https://github.com/FireRedTeam/FireRed-OpenStoryline) 的**随仓快照**（含打包裁剪修改），快照基点 commit: `c9e94521` (2026-07-31)。如需跟进上游更新：手动 diff/merge 上游新代码到 `source/`。

将 [FireRed-OpenStoryline](https://github.com/FireRedTeam/FireRed-OpenStoryline)（AI 视频剪辑 Agent）封装为 Windows / macOS 桌面安装包。方案见上一级目录《方案说明-OpenStoryline安装包封装.md》。

## 目录结构

```
openstoryline-pack/
├── build/                    ← 安装包产物输出
│   ├── windows/
│   └── macos/
├── source/                   ← 原项目源码（已精简 ASR）
├── runtime/                  ← 内嵌运行时
│   ├── python-win/           ← python-build-standalone 3.11.9 (win64) + 已装依赖
│   ├── python-mac/           ← python-build-standalone 3.11.9 (arm64) + 已装依赖
│   ├── ffmpeg-win/           ← ffmpeg.exe / ffprobe.exe
│   └── ffmpeg-mac/           ← ffmpeg / ffprobe
├── resources/                ← resource.zip 解压产物（bgms/fonts/script_templates/tts）
├── installer/
│   ├── windows/setup.iss     ← Inno Setup 脚本
│   └── macos/                ← build_dmg.sh + Info.plist
├── launcher/
│   ├── start.bat             ← Windows 启动器
│   └── launcher.sh           ← macOS 启动器（.app/Contents/MacOS/launcher）
├── assets/                   ← icon.ico / icon.icns
└── scripts/
    ├── prepare_deps.sh       ← 在新机器上重建运行时（一般用不到）
    └── verify.sh             ← 打包前自检
```

## 与方案文档的差异（重要）

实际实现中发现并修正了文档中的几处问题：

1. **端口**：原项目 `run.sh` 默认 Web 端口是 **7860**（文档写的 8005 不存在于原项目）。启动器统一使用 7860。
2. **双进程**：服务由两个进程组成 —— `python -m open_storyline.mcp.server`（MCP，端口 8001）+ `uvicorn agent_fastapi:app`（Web，7860）。启动器负责同时拉起并在退出时清理。
3. **资源路径**：`config.toml` 中所有相对路径基于 **config.toml 所在目录** 解析（见 `src/open_storyline/config.py`）。因此资源打进 `app/resource/`（与源码同级），而不是文档中的顶层 `resources/`，这样 **config.toml 零改动**。打包目录里的 `resources/` 只是暂存区。
4. **模型位置**：模型下载到 `app/.storyline/models/`（transnetv2 权重 + all-MiniLM-L6-v2），与 `config.toml` 的 `transnet_weights` 路径一致。文档中的 `STORYLINE_RESOURCE/STORYLINE_MODELS` 环境变量项目并不读取，已去掉。
5. **av==16.1.0 要求 macOS 14+**：其 arm64 wheel 标签为 `macosx_14_0_arm64`，故 `Info.plist` 的 `LSMinimumSystemVersion` 设为 14.0。
6. **Windows 可写目录**：安装到 Program Files 时，通过 Inno Setup `[Dirs] Permissions: users-modify` 授予 `app\.storyline`、`app\outputs` 写权限，保证首次启动模型下载与视频输出可用。
7. **torch 保留**：torch 被镜头分割（transnetv2）与句向量（sentence-transformers）使用，非 ASR 专属，不能删；只删了 `funasr` + `torchaudio`。Windows 版 torch 使用 PyTorch 官方 CPU 源（`torch+cpu`）以减小体积。
8. **config.toml 已移除 `LocalASRNode`** 注册（无 funasr 依赖，调用会 ImportError，第一版直接不暴露该节点）。
9. **langgraph-prebuilt 必须固定 1.0.8**：prebuilt 1.0.10/1.0.9 引用了 langgraph 1.1+ 才有的 `langgraph.runtime.ExecutionInfo`，而 langchain==1.2.4 约束 `langgraph<1.1.0`，导致 `ImportError: cannot import name 'ExecutionInfo'`。已在 requirements 中固定 `langgraph-prebuilt==1.0.8`（此坑为上游最新发布引入，本地验证时发现）。
10. **MCP server 启动时会校验资源文件**：`ScriptTemplateRecomendation` 节点实例化时读取 `resource/script_templates/meta.json`，split_shots 注册时校验 transnet 权重。因此 resource/ 和 .storyline/models 缺失时 MCP 进程会直接退出——打包布局必须保证二者就位（本方案已满足；启动器的模型下载逻辑也因此放在启动服务之前）。
11. **交叉安装依赖（重要经验）**：在 Linux 上用 `pip --platform` 给 Win/Mac 装依赖时，torch 的 METADATA 带 `cuda-bindings; platform_system == "Linux"` 依赖，pip 按宿主机求值 marker 导致解析失败/回退到 torch 2.1.0。解决办法：
   - Windows：加 `--extra-index-url https://download.pytorch.org/whl/cpu`，解析出无 cuda 依赖的 `torch+cpu`，一遍装完（见 `requirements-win.txt`，其中 uvicorn[standard] 拆开了，去掉仅非 Windows 的 uvloop）。
   - macOS：分两遍离线安装（见 `requirements-mac-pass1.txt` / `requirements-mac-pass2.txt`）：pass1 装除 torch 系之外的全部 wheel；pass2 用 `--no-deps` 装 torch/transnetv2/sentence-transformers/langchain-huggingface 等，其真实依赖（sympy、networkx、jinja2、setuptools<82、transformers==4.57.6、tokenizers==0.22.2、huggingface_hub==0.36.2 等）已在 pass1 显式包含。
   - PyPI 官方 CDN 在部分网络下极慢且易断，改用 `https://mirrors.aliyun.com/pypi/simple/` 可提速数十倍；`scripts/fetch_wheels.py` 可按 pip --report 清单断点续传下载 wheel。

## 打包方法

### 重建 macOS 依赖环境（依赖有变更时）

```bash
./scripts/build_mac_deps.sh   # 一键: 出清单 -> curl 下载 -> 三遍离线安装 -> 自检
./scripts/bundle_mac.sh       # 重新打材料包
```
该脚本内建了全部已知坑的规避（torch cuda marker、langgraph 命名空间、langgraph-prebuilt 版本、漏装 wheel），新产物保证安装后可直接启动。

### macOS（在 Mac 上执行）

```bash
# 前置（可选，产出更美观的 dmg）：
brew install create-dmg

cd openstoryline-pack
./scripts/verify.sh macos          # 自检
cd installer/macos && ./build_dmg.sh
# 产物: build/macos/OpenStoryline-1.0.0-macOS.dmg
```

注意：
- 本目录中 `runtime/python-mac` 的依赖是在 Linux 上用 `pip --platform` 交叉安装的纯 wheel，理论上与 Mac 本机安装等价；首次在 Mac 上构建如遇导入问题，可运行 `../scripts/prepare_deps.sh macos-arm64` 在本机重建。
- `runtime/ffmpeg-mac/` 的 ffmpeg/ffprobe 为 osxexperts.net 的 **arm64 原生**静态版（ffmpeg 9.x）。如需 Intel Mac 版本，换用 evermeet.cx 的 x86_64 静态版或 `brew install ffmpeg`。
- 未签名应用：用户需「右键 → 打开」，或 `xattr -cr /Applications/OpenStoryline.app`。

### Windows

**方式 A（推荐，本构建机已完成）**：Linux + wine + Inno Setup 7（64 位）直接编译：
```bash
sudo apt-get install -y wine wine32:i386 xvfb   # wine32 供安装器使用
xvfb-run -a wine innosetup-7.1.0-x64.exe /VERYSILENT /DIR='C:\InnoSetup7'
xvfb-run -a wine 'C:\InnoSetup7\ISCC.exe' 'Z:\.../installer\windows\setup.iss'
```
> 注意：Inno Setup 6.x 是 32 位，压缩 2GB+ 素材会 Out of memory，必须用 7.x 64 位版。

**方式 B（Windows 机器）**：安装 [Inno Setup 7](https://jrsoftware.org/isdl.php)，运行 `iscc installer\windows\setup.iss`。

产物: `build\windows\OpenStoryline-Setup-1.0.0-win64.exe`

### 干净环境测试清单（Step 10）

在无 Python / 无 FFmpeg 的机器上：
1. 安装安装包（Windows 双击 exe；macOS 拖入 Applications 后 `xattr -cr /Applications/OpenStoryline.app`）
2. 双击启动，确认首次自动下载模型（约 106MB）并完成
3. 浏览器自动打开 `http://127.0.0.1:7860`，UI 正常
4. 在 UI 填写 config.toml 对应的 LLM/VLM key 后，跑一个简单视频流程
5. 关闭启动窗口 / 退出应用，确认进程全部退出（Web 7860、MCP 8001 端口释放）
6. 卸载后确认安装目录清理干净（models/outputs 按卸载策略清理）

## 用户首次使用说明

- 首次启动会自动下载约 106MB 模型文件（transnetv2 权重 + 句向量模型），需要联网。
- 使用前需在 `app/config.toml` 填写 LLM/VLM 的 `api_key`、`base_url`、`model`。
- 浏览器自动打开 `http://127.0.0.1:7860`；关闭启动窗口 / 退出应用即停止服务。

#!/usr/bin/env python3
"""OpenStoryline Windows GUI launcher (tray + native window, no console).

Run:
    <root>\\runtime\\python\\pythonw.exe <root>\\launcher\\app_tray.py

Debug:
    Run the same file with python.exe to see logs in a console, or use
    --selftest to check the environment without starting services or GUI.
"""
from __future__ import annotations

import contextlib
import ctypes
import logging
import os
import subprocess
import sys
import threading
import time
import urllib.request
import webbrowser
import zipfile
from logging.handlers import RotatingFileHandler
from pathlib import Path

# Under pythonw, sys.stdout/stderr are None; guard against libraries that print.
if sys.stdout is None:
    sys.stdout = open(os.devnull, "w", encoding="utf-8")
if sys.stderr is None:
    sys.stderr = open(os.devnull, "w", encoding="utf-8")

SELFTEST = "--selftest" in sys.argv

ROOT = Path(__file__).resolve().parent.parent
APP_DIR = ROOT / "app"
RUNTIME_PY_DIR = ROOT / "runtime" / "python"
PYTHONW = RUNTIME_PY_DIR / "pythonw.exe"
FFMPEG_DIR = ROOT / "runtime" / "ffmpeg"
CONFIG_FILE = APP_DIR / "config.toml"
MODELS_DIR = APP_DIR / ".storyline" / "models"
MODELS_MARKER = MODELS_DIR / ".downloaded"
LOG_DIR = APP_DIR / ".storyline" / "logs"
ICON_FILE = ROOT / "assets" / "icon.ico"
SCRIPT_TEMPLATE_META = APP_DIR / "resource" / "script_templates" / "meta.json"
BGM_META = APP_DIR / "resource" / "bgms" / "meta.json"
FONT_INFO = APP_DIR / "resource" / "fonts" / "font_info.json"
TTS_PROVIDERS = APP_DIR / "resource" / "tts" / "tts_providers.json"

APP_URL = "http://127.0.0.1:7860"
WEB_PORT = 7860
MODELS_URL = "https://image-url-2-feature-1251524319.cos.ap-shanghai.myqcloud.com/openstoryline/models.zip"

CREATE_NO_WINDOW = 0x08000000
MB_ICONERROR = 0x10
MB_ICONINFORMATION = 0x40
MB_TOPMOST = 0x40000
MB_SETFOREGROUND = 0x00010000

log = logging.getLogger("openstoryline.launcher")


def msg_box(text: str, icon: int = MB_ICONERROR) -> None:
    if SELFTEST:
        print(f"[msgbox:{'error' if icon == MB_ICONERROR else 'info'}] {text}")
        return
    ctypes.windll.user32.MessageBoxW(
        0, text, "OpenStoryline", icon | MB_TOPMOST | MB_SETFOREGROUND
    )


def acquire_single_instance() -> tuple[bool, int]:
    error_already_exists = 183
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.CreateMutexW(None, False, "OpenStoryline.SingleInstance.Mutex")
    if not handle:
        return False, 0
    if kernel32.GetLastError() == error_already_exists:
        return False, handle
    return True, handle


def activate_running_window() -> bool:
    user32 = ctypes.windll.user32
    hwnd = user32.FindWindowW(None, "OpenStoryline")
    if not hwnd:
        return False
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    else:
        user32.ShowWindow(hwnd, 5)  # SW_SHOW
    user32.SetForegroundWindow(hwnd)
    return True


def setup_logging() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    handler = RotatingFileHandler(
        LOG_DIR / "app.log", maxBytes=1_000_000, backupCount=2, encoding="utf-8"
    )
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s: %(message)s",
        handlers=[handler],
    )


def open_service_log(name: str):
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    path = LOG_DIR / name
    with contextlib.suppress(OSError):
        if path.exists() and path.stat().st_size > 5_000_000:
            old = path.with_suffix(path.suffix + ".old")
            old.unlink(missing_ok=True)
            path.rename(old)
    return open(path, "ab", buffering=0)


def read_log_tail(path: Path, limit: int = 1500) -> str:
    try:
        return path.read_bytes()[-limit:].decode("utf-8", errors="replace").strip()
    except OSError:
        return ""


def build_child_env() -> dict[str, str]:
    env = os.environ.copy()
    prepend = [str(RUNTIME_PY_DIR), str(RUNTIME_PY_DIR / "Scripts"), str(FFMPEG_DIR)]
    env["PATH"] = os.pathsep.join(prepend + [env.get("PATH", "")])
    env["PYTHONHOME"] = str(RUNTIME_PY_DIR)
    env["PYTHONPATH"] = str(APP_DIR / "src")
    env["OPENSTORYLINE_CONFIG"] = str(CONFIG_FILE)
    env["PYTHONIOENCODING"] = "utf-8"
    return env


def has_webview2() -> bool:
    import winreg

    webview2_key = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    subpaths = (
        rf"SOFTWARE\Microsoft\EdgeUpdate\Clients\{webview2_key}",
        rf"SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{webview2_key}",
    )
    for hive in (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER):
        for sub in subpaths:
            try:
                with winreg.OpenKey(hive, sub) as key:
                    if str(winreg.QueryValueEx(key, "pv")[0]):
                        return True
            except OSError:
                continue
    return False


def _import_ok(name: str) -> bool:
    try:
        __import__(name)
        return True
    except Exception:
        return False


def check_environment() -> str:
    missing = []
    if not PYTHONW.exists():
        missing.append(str(PYTHONW))
    if not CONFIG_FILE.exists():
        missing.append(str(CONFIG_FILE))
    if not (FFMPEG_DIR / "ffmpeg.exe").exists():
        missing.append(str(FFMPEG_DIR / "ffmpeg.exe"))
    for resource_file in (SCRIPT_TEMPLATE_META, BGM_META, FONT_INFO, TTS_PROVIDERS):
        if not resource_file.exists():
            missing.append(str(resource_file))
    if missing:
        return "以下文件缺失，安装可能不完整：\n\n" + "\n".join(missing)
    return ""


def _find_model_weights() -> Path | None:
    with contextlib.suppress(OSError):
        for path in MODELS_DIR.rglob("transnetv2-pytorch-weights.pth"):
            return path
    return None


def _flatten_single_dir(base: Path) -> None:
    import shutil

    entries = list(base.iterdir())
    dirs = [e for e in entries if e.is_dir()]
    files = [e for e in entries if e.is_file()]
    if len(dirs) == 1 and not files:
        only = dirs[0]
        for child in only.iterdir():
            shutil.move(str(child), str(base / child.name))
        only.rmdir()


def _download_models(state: dict) -> None:
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    zip_path = MODELS_DIR / "models.zip"
    try:
        state.update(phase="download", done=0, total=0)
        request = urllib.request.Request(
            MODELS_URL, headers={"User-Agent": "OpenStoryline/1.0"}
        )
        with urllib.request.urlopen(request, timeout=60) as resp, open(zip_path, "wb") as f:
            state["total"] = int(resp.headers.get("Content-Length") or 0)
            while True:
                chunk = resp.read(512 * 1024)
                if not chunk:
                    break
                f.write(chunk)
                state["done"] += len(chunk)

        state.update(phase="extract", done=0, total=0)
        with zipfile.ZipFile(zip_path) as zf:
            members = [m for m in zf.infolist() if not m.is_dir()]
            state["total"] = len(members)
            for index, member in enumerate(members, 1):
                zf.extract(member, MODELS_DIR)
                state["done"] = index
        _flatten_single_dir(MODELS_DIR)
        if not _find_model_weights():
            raise RuntimeError("解压后未找到 transnetv2-pytorch-weights.pth，模型包可能已变更")
        MODELS_MARKER.write_text("ok", encoding="utf-8")
        state["phase"] = "done"
    finally:
        with contextlib.suppress(OSError):
            zip_path.unlink(missing_ok=True)


def run_model_download_dialog() -> None:
    import tkinter as tk
    from tkinter import ttk

    state = {"phase": "prepare", "done": 0, "total": 0, "error": None}

    root = tk.Tk()
    root.title("OpenStoryline")
    root.resizable(False, False)
    root.attributes("-topmost", True)
    width, height = 430, 150
    x = max(0, (root.winfo_screenwidth() - width) // 2)
    y = max(0, (root.winfo_screenheight() - height) // 3)
    root.geometry(f"{width}x{height}+{x}+{y}")

    frame = ttk.Frame(root, padding=16)
    frame.pack(fill="both", expand=True)
    status_var = tk.StringVar(value="准备下载模型文件…")
    ttk.Label(frame, textvariable=status_var).pack(anchor="w")
    bar = ttk.Progressbar(frame, length=390, mode="determinate", maximum=100)
    bar.pack(fill="x", pady=(8, 4))
    ttk.Label(
        frame,
        text="首次启动需要下载约 106 MB 模型，完成后将自动进入主界面。",
        foreground="#666666",
    ).pack(anchor="w")

    def worker() -> None:
        try:
            _download_models(state)
        except Exception as exc:
            log.exception("模型下载失败")
            state["error"] = f"模型下载失败：{exc}"

    threading.Thread(target=worker, daemon=True).start()

    def poll() -> None:
        phase = state["phase"]
        if phase == "download":
            if state["total"]:
                bar["value"] = state["done"] / state["total"] * 100
                status_var.set(
                    f"正在下载模型文件… {state['done'] / 1048576:.0f}"
                    f"/{state['total'] / 1048576:.0f} MB"
                )
            else:
                status_var.set("正在下载模型文件…")
        elif phase == "extract":
            if state["total"]:
                bar["value"] = state["done"] / state["total"] * 100
            status_var.set(f"正在解压模型文件… {state['done']}/{state['total']}")
        if state["error"] or state["phase"] == "done":
            root.destroy()
        else:
            root.after(120, poll)

    poll()
    root.mainloop()
    if state["error"]:
        raise RuntimeError(state["error"])


class ServiceManager:
    def __init__(self, env: dict[str, str]) -> None:
        self.env = env
        self.procs: dict[str, subprocess.Popen] = {}
        self._log_files = []

    def start(self) -> None:
        mcp_log = open_service_log("mcp.log")
        web_log = open_service_log("web.log")
        self._log_files = [mcp_log, web_log]
        self.procs["mcp"] = subprocess.Popen(
            [str(PYTHONW), "-m", "open_storyline.mcp.server"],
            cwd=str(APP_DIR),
            env=self.env,
            stdout=mcp_log,
            stderr=subprocess.STDOUT,
            creationflags=CREATE_NO_WINDOW,
        )
        self.procs["web"] = subprocess.Popen(
            [
                str(PYTHONW), "-m", "uvicorn", "agent_fastapi:app",
                "--host", "127.0.0.1", "--port", str(WEB_PORT),
            ],
            cwd=str(APP_DIR),
            env=self.env,
            stdout=web_log,
            stderr=subprocess.STDOUT,
            creationflags=CREATE_NO_WINDOW,
        )
        log.info(
            "服务已启动: mcp pid=%s, web pid=%s",
            self.procs["mcp"].pid, self.procs["web"].pid,
        )

    def alive(self, name: str) -> bool:
        proc = self.procs.get(name)
        return proc is not None and proc.poll() is None

    def stop(self) -> None:
        for proc in self.procs.values():
            if proc.poll() is None:
                proc.terminate()
        deadline = time.time() + 5
        for name, proc in list(self.procs.items()):
            try:
                proc.wait(timeout=max(0.1, deadline - time.time()))
            except subprocess.TimeoutExpired:
                proc.kill()
                with contextlib.suppress(Exception):
                    proc.wait(timeout=3)
            log.info("服务已停止: %s", name)
        self.procs.clear()
        for f in self._log_files:
            with contextlib.suppress(OSError):
                f.close()
        self._log_files = []


def _open_path(path: Path) -> None:
    try:
        os.startfile(str(path))  # noqa: S606
    except OSError as exc:
        msg_box(f"无法打开：{path}\n\n{exc}")


def make_tray_image():
    from PIL import Image

    try:
        image = Image.open(ICON_FILE)
        ico_sizes = getattr(getattr(image, "ico", None), "sizes", None)
        if ico_sizes:
            image.size = max(ico_sizes())
        image.load()
        return image
    except Exception:
        log.warning("加载托盘图标失败，使用纯色兜底图标")
        return Image.new("RGBA", (64, 64), (200, 60, 60, 255))


class App:
    def __init__(self) -> None:
        self.env: dict[str, str] | None = None
        self.services: ServiceManager | None = None
        self.tray = None
        self.window = None
        self.quitting = False
        self.shutdown_event = threading.Event()

    def open_main(self, icon=None, item=None) -> None:
        if self.window is not None:
            try:
                self.window.show()
                return
            except Exception:
                log.exception("窗口激活失败，回退到浏览器")
        webbrowser.open(APP_URL)

    def open_config(self, icon=None, item=None) -> None:
        _open_path(CONFIG_FILE)

    def open_logs(self, icon=None, item=None) -> None:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        _open_path(LOG_DIR)

    def quit_app(self, icon=None, item=None) -> None:
        self.quitting = True
        self.shutdown_event.set()
        if self.window is not None:
            with contextlib.suppress(Exception):
                self.window.destroy()

    def build_tray(self) -> None:
        import pystray

        menu = pystray.Menu(
            pystray.MenuItem("打开 OpenStoryline", self.open_main, default=True),
            pystray.MenuItem("打开配置文件", self.open_config),
            pystray.MenuItem("打开日志文件夹", self.open_logs),
            pystray.MenuItem("退出", self.quit_app),
        )
        self.tray = pystray.Icon("OpenStoryline", make_tray_image(), "OpenStoryline", menu)
        self.tray.run_detached()

    def _on_closing(self):
        if self.quitting:
            return None
        with contextlib.suppress(Exception):
            self.window.hide()
        return False

    def run_window(self) -> str:
        import webview

        gui = "edgechromium" if has_webview2() else None
        self.window = webview.create_window(
            "OpenStoryline", APP_URL, width=1280, height=860, min_size=(960, 640)
        )
        closing_event = getattr(self.window.events, "closing", None)
        if closing_event is not None:
            closing_event += self._on_closing
        try:
            webview.start(gui=gui)
            return "closed"
        except Exception:
            log.exception("WebView 窗口启动失败，回退到浏览器")
            self.window = None
            return "webview_failed"


def wait_web_ready(timeout: float, services: ServiceManager) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not services.alive("web") or not services.alive("mcp"):
            return False
        try:
            with urllib.request.urlopen(APP_URL, timeout=2):
                return True
        except Exception:
            time.sleep(1)
    return False


def run_selftest() -> int:
    print("== OpenStoryline launcher selftest ==")
    checks = [
        ("pythonw.exe", PYTHONW.exists()),
        ("config.toml", CONFIG_FILE.exists()),
        ("ffmpeg.exe", (FFMPEG_DIR / "ffmpeg.exe").exists()),
        ("resource metadata", all(
            path.exists()
            for path in (SCRIPT_TEMPLATE_META, BGM_META, FONT_INFO, TTS_PROVIDERS)
        )),
        ("icon.ico", ICON_FILE.exists()),
        ("pystray importable", _import_ok("pystray")),
        ("webview importable", _import_ok("webview")),
        ("PIL importable", _import_ok("PIL")),
        ("tkinter importable", _import_ok("tkinter")),
    ]
    failed = 0
    for name, ok in checks:
        print(f"  [{'OK' if ok else 'FAIL'}] {name}")
        failed += 0 if ok else 1
    print(f"  [{'OK' if has_webview2() else 'SKIP'}] WebView2 runtime")
    print(f"  log dir: {LOG_DIR}")
    print("== selftest %s ==" % ("PASSED" if failed == 0 else f"FAILED ({failed})"))
    return 0 if failed == 0 else 1


def main() -> int:
    app: App | None = None
    mutex = 0
    try:
        acquired, mutex = acquire_single_instance()
        if not acquired:
            if not activate_running_window():
                msg_box("OpenStoryline 已在运行中，请查看系统托盘。", MB_ICONINFORMATION)
            return 0

        setup_logging()
        log.info("===== OpenStoryline 启动 (pid=%s) =====", os.getpid())

        problems = check_environment()
        if problems:
            msg_box(problems)
            return 1

        app = App()
        if SELFTEST:
            return run_selftest()

        if MODELS_MARKER.exists() and not _find_model_weights():
            log.warning("模型标记存在但权重文件缺失，将重新下载")
            MODELS_MARKER.unlink(missing_ok=True)
        if not MODELS_MARKER.exists():
            try:
                run_model_download_dialog()
            except Exception as exc:
                log.exception("模型下载流程失败")
                msg_box(f"{exc}\n\n请检查网络后重试；若反复失败，请查看日志：{LOG_DIR}")
                return 1
            log.info("模型下载完成")

        (APP_DIR / "outputs" / "media").mkdir(parents=True, exist_ok=True)
        app.env = build_child_env()
        app.services = ServiceManager(app.env)
        app.services.start()

        if not wait_web_ready(60.0, app.services):
            app.services.stop()
            web_tail = read_log_tail(LOG_DIR / "web.log")
            mcp_tail = read_log_tail(LOG_DIR / "mcp.log")
            detail = "\n\n".join(
                f"{name} 末尾日志：\n{tail}"
                for name, tail in (("web.log", web_tail), ("mcp.log", mcp_tail))
                if tail
            ) or f"请查看日志目录：{LOG_DIR}"
            msg_box("服务启动失败（等待超时或进程提前退出）。\n\n" + detail)
            return 1
        log.info("Web 服务就绪: %s", APP_URL)

        app.build_tray()
        with contextlib.suppress(Exception):
            app.tray.notify("OpenStoryline 已启动", "可通过托盘菜单打开主界面或退出")

        mode = app.run_window() if has_webview2() else "no_webview"
        if mode != "closed":
            webbrowser.open(APP_URL)
            with contextlib.suppress(Exception):
                app.tray.notify("已在浏览器中打开", "未检测到 WebView2，主界面通过浏览器访问")
            while not app.shutdown_event.wait(1.0):
                if not app.services.alive("web"):
                    log.warning("Web 服务意外退出")
                    break
        return 0
    finally:
        if app is not None:
            if app.services is not None:
                app.services.stop()
            if app.tray is not None:
                with contextlib.suppress(Exception):
                    app.tray.stop()
        if mutex:
            ctypes.windll.kernel32.CloseHandle(mutex)
        log.info("===== OpenStoryline 退出 =====")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)

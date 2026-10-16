#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Mac 多账号快捷方式生成器（全程点选）

选软件 → 选账号方案 → 为每个账号选数据目录（默认最空闲磁盘）→ 确认 → 自动生成
"""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import textwrap
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence

HOME = Path.home()
DESKTOP = HOME / "Desktop"
APPS_DIR = HOME / "Applications"
DOCUMENTS = HOME / "Documents"


@dataclass
class ToolSpec:
    id: str
    name: str
    description: str
    detect: Callable[[], Optional[Path]]
    make_launcher: Callable[[str, Path, Path], str]
    prepare_dirs: Callable[[Path], Path]


@dataclass
class Choice:
    label: str
    value: object


@dataclass
class AccountPlan:
    profile: str          # 规范目录名，如 account1 / work
    display: str          # 界面展示名
    data_dir: Path        # 该账号最终数据目录


# ---------- 目录命名规范 ----------
# 工具 id：小写英文
# 账号 id：小写英文/数字/连字符，如 account1、work、personal
# 最终路径：{root}/AppAccounts/{tool_id}/{profile}/

PROFILE_PRESETS: List[Choice] = [
    Choice("两个账号：account1 + account2（推荐）", [
        ("account1", "account1"),
        ("account2", "account2"),
    ]),
    Choice("两个账号：工作 + 个人", [
        ("work", "工作"),
        ("personal", "个人"),
    ]),
    Choice("三个账号：account1～account3", [
        ("account1", "account1"),
        ("account2", "account2"),
        ("account3", "account3"),
    ]),
    Choice("四个账号：account1～account4", [
        ("account1", "account1"),
        ("account2", "account2"),
        ("account3", "account3"),
        ("account4", "account4"),
    ]),
    Choice("只要一个账号：account1", [("account1", "account1")]),
]


def normalize_id(raw: str) -> str:
    """规范目录/标识名：小写、仅 a-z 0-9 与连字符。"""
    s = raw.strip().lower().replace("_", "-").replace(" ", "-")
    s = re.sub(r"[^a-z0-9-]+", "-", s)
    s = re.sub(r"-{2,}", "-", s).strip("-")
    return s or "account"


def _title_case(name: str) -> str:
    if not name:
        return name
    return name[0].upper() + name[1:]


# ---------- 最空闲磁盘 ----------

def _mounts_with_free() -> List[tuple]:
    """返回 [(mount_path, free_bytes, total_bytes), ...]，本地磁盘优先。"""
    results = []
    seen = set()

    # 根分区
    try:
        st = os.statvfs("/")
        free = st.f_bavail * st.f_frsize
        total = st.f_blocks * st.f_frsize
        results.append((Path("/"), free, total))
        seen.add("/")
    except OSError:
        pass

    volumes = Path("/Volumes")
    if volumes.is_dir():
        for item in volumes.iterdir():
            try:
                if item.name.startswith("."):
                    continue
                # 跳过常见网络/只读/备份卷名启发式
                lower = item.name.lower()
                if lower in {"com.apple.timemachine.localsnapshots"}:
                    continue
                resolved = item.resolve()
                key = str(resolved)
                if key in seen:
                    continue
                st = os.statvfs(item)
                # 只读或几乎不可写的跳过
                if st.f_bavail <= 0:
                    continue
                free = st.f_bavail * st.f_frsize
                total = st.f_blocks * st.f_frsize
                # 排除极小虚拟卷
                if total < 1 * 1024 ** 3:
                    continue
                results.append((item, free, total))
                seen.add(key)
            except OSError:
                continue

    results.sort(key=lambda x: x[1], reverse=True)
    return results


def format_size(n: int) -> str:
    for unit, div in (("TB", 1024 ** 4), ("GB", 1024 ** 3), ("MB", 1024 ** 2)):
        if n >= div:
            return f"{n / div:.1f}{unit}"
    return f"{n}B"


def freest_appaccounts_root() -> Path:
    """最充裕磁盘下的规范根目录：.../AppAccounts"""
    mounts = _mounts_with_free()
    if not mounts:
        return HOME / "AppAccounts"
    mount, free, _ = mounts[0]
    if mount == Path("/"):
        # 系统盘：放用户家目录下，避免写到根目录
        return HOME / "AppAccounts"
    return mount / "AppAccounts"


def default_account_dir(root: Path, tool_id: str, profile: str) -> Path:
    """规范路径：{root}/{tool_id}/{profile}"""
    return root / normalize_id(tool_id) / normalize_id(profile)


# ---------- 应用检测 ----------

def _find_bundle_executable(app: Path) -> Optional[Path]:
    plist = app / "Contents" / "Info.plist"
    exe_name = "Electron"
    if plist.exists():
        try:
            with plist.open("rb") as f:
                info = plistlib.load(f)
            exe_name = info.get("CFBundleExecutable") or exe_name
        except Exception:
            pass
    candidate = app / "Contents" / "MacOS" / exe_name
    if candidate.exists():
        return candidate
    electron = app / "Contents" / "MacOS" / "Electron"
    if electron.exists():
        return electron
    macos = app / "Contents" / "MacOS"
    if macos.is_dir():
        for p in macos.iterdir():
            if p.is_file() and os.access(p, os.X_OK):
                return p
    return None


def detect_workbuddy() -> Optional[Path]:
    for root in (Path("/Applications"), HOME / "Applications"):
        exe = _find_bundle_executable(root / "WorkBuddy.app")
        if exe:
            return exe
    return None


def detect_cursor() -> Optional[Path]:
    for root in (Path("/Applications"), HOME / "Applications"):
        exe = _find_bundle_executable(root / "Cursor.app")
        if exe:
            return exe
    which = shutil.which("cursor")
    return Path(which) if which else None


def detect_vscode() -> Optional[Path]:
    for name in ("Visual Studio Code.app", "Code.app"):
        for root in (Path("/Applications"), HOME / "Applications"):
            exe = _find_bundle_executable(root / name)
            if exe:
                return exe
    which = shutil.which("code")
    return Path(which) if which else None


def detect_chrome() -> Optional[Path]:
    for name in ("Google Chrome.app", "Chromium.app"):
        for root in (Path("/Applications"), HOME / "Applications"):
            exe = _find_bundle_executable(root / name)
            if exe:
                return exe
    return None


def prepare_workbuddy_dirs(account_dir: Path) -> Path:
    (account_dir / "app").mkdir(parents=True, exist_ok=True)
    (account_dir / "auth").mkdir(parents=True, exist_ok=True)
    runtime = account_dir / "runtime-home" / "Library" / "Application Support" / "CodeBuddyExtension" / "Data" / "Public" / "auth"
    runtime.mkdir(parents=True, exist_ok=True)
    # 桌面等快捷入口
    real_home = Path.home()
    rh = account_dir / "runtime-home"
    rh.mkdir(parents=True, exist_ok=True)
    for name in ("Desktop", "Downloads", "Documents", "Pictures", "Movies", "Music"):
        src = real_home / name
        dst = rh / name
        if src.exists() and not dst.exists():
            try:
                dst.symlink_to(src)
            except OSError:
                pass
    return account_dir


def prepare_cursor_dirs(account_dir: Path) -> Path:
    account_dir.mkdir(parents=True, exist_ok=True)
    (account_dir / "extensions").mkdir(parents=True, exist_ok=True)
    return account_dir


def prepare_vscode_dirs(account_dir: Path) -> Path:
    return prepare_cursor_dirs(account_dir)


def prepare_chrome_dirs(account_dir: Path) -> Path:
    account_dir.mkdir(parents=True, exist_ok=True)
    return account_dir


def launcher_workbuddy(profile: str, account_dir: Path, exe: Path) -> str:
    """WorkBuddy 登录态在固定的 CodeBuddyExtension 目录，必须隔开 HOME 才能多账号并行。"""
    electron_dir = account_dir / "app"
    runtime_home = account_dir / "runtime-home"
    real_home = Path.home()
    return textwrap.dedent(
        f"""\
        #!/bin/bash
        set -euo pipefail
        ACCOUNT_DIR="{account_dir}"
        ELECTRON_DIR="{electron_dir}"
        RUNTIME_HOME="{runtime_home}"
        REAL_HOME="{real_home}"
        EXE="{exe}"

        mkdir -p "$ELECTRON_DIR" \
                 "$RUNTIME_HOME/Library/Application Support/CodeBuddyExtension/Data/Public/auth" \
                 "$ACCOUNT_DIR/auth"

        # 方便选文件：桌面/下载/文稿仍指向真实用户目录
        for d in Desktop Downloads Documents Pictures Movies Music; do
          if [[ -e "$REAL_HOME/$d" && ! -e "$RUNTIME_HOME/$d" ]]; then
            ln -sfn "$REAL_HOME/$d" "$RUNTIME_HOME/$d"
          fi
        done

        # 关键隔离登录态（否则多窗口共用同一 workbuddy-desktop.info）
        export HOME="$RUNTIME_HOME"
        export WORKBUDDY_CONFIG_DIR="$ACCOUNT_DIR"
        export CODEBUDDY_CONFIG_DIR="$ACCOUNT_DIR"
        export WORKBUDDY_USER_DATA_DIR="$ELECTRON_DIR"
        unset ELECTRON_RUN_AS_NODE

        exec "$EXE" \
          --user-data-dir="$ELECTRON_DIR" \
          --new-window \
          "$@"
        """
    )


def launcher_cursor(profile: str, account_dir: Path, exe: Path) -> str:
    return textwrap.dedent(
        f"""\
        #!/bin/bash
        set -euo pipefail
        exec "{exe}" \\
          --user-data-dir="{account_dir}" \\
          --extensions-dir="{account_dir}/extensions" \\
          "$@"
        """
    )


def launcher_vscode(profile: str, account_dir: Path, exe: Path) -> str:
    return launcher_cursor(profile, account_dir, exe)


def launcher_chrome(profile: str, account_dir: Path, exe: Path) -> str:
    return textwrap.dedent(
        f"""\
        #!/bin/bash
        set -euo pipefail
        exec "{exe}" \\
          --user-data-dir="{account_dir}" \\
          --no-first-run \\
          --no-default-browser-check \\
          "$@"
        """
    )


TOOLS: Dict[str, ToolSpec] = {
    "workbuddy": ToolSpec(
        id="workbuddy",
        name="WorkBuddy",
        description="腾讯龙虾, HOME隔离多账号",
        detect=detect_workbuddy,
        make_launcher=launcher_workbuddy,
        prepare_dirs=prepare_workbuddy_dirs,
    ),
    "cursor": ToolSpec(
        id="cursor",
        name="Cursor",
        description="Cursor, 独立 user-data",
        detect=detect_cursor,
        make_launcher=launcher_cursor,
        prepare_dirs=prepare_cursor_dirs,
    ),
    "vscode": ToolSpec(
        id="vscode",
        name="VS Code",
        description="VS Code, 独立配置",
        detect=detect_vscode,
        make_launcher=launcher_vscode,
        prepare_dirs=prepare_vscode_dirs,
    ),
    "chrome": ToolSpec(
        id="chrome",
        name="Chrome",
        description="Chrome, 独立用户数据",
        detect=detect_chrome,
        make_launcher=launcher_chrome,
        prepare_dirs=prepare_chrome_dirs,
    ),
}




def _find_bundle_app_exe(app: Path) -> Optional[Path]:
    return _find_bundle_executable(app)


def launcher_electron_generic(profile: str, account_dir: Path, exe: Path) -> str:
    return textwrap.dedent(
        f"""\
        #!/bin/bash
        set -euo pipefail
        exec "{exe}" \\
          --user-data-dir="{account_dir}" \\
          --new-window \\
          "$@"
        """
    )


def prepare_electron_dirs(account_dir: Path) -> Path:
    account_dir.mkdir(parents=True, exist_ok=True)
    return account_dir


def detect_qoder() -> Optional[Path]:
    for root in (Path("/Applications"), HOME / "Applications"):
        for name in ("Qoder.app",):
            exe = _find_bundle_executable(root / name)
            if exe:
                return exe
        if root.is_dir():
            for app in root.glob("Qoder.app"):
                exe = _find_bundle_executable(app)
                if exe:
                    return exe
    return None


def detect_qoderwork() -> Optional[Path]:
    for root in (Path("/Applications"), HOME / "Applications"):
        for name in ("QoderWork.app", "Qoder Work.app", "QoderWork Desktop.app"):
            exe = _find_bundle_executable(root / name)
            if exe:
                return exe
    # fallback: any app starting with QoderWork
    for root in (Path("/Applications"), HOME / "Applications"):
        if not root.is_dir():
            continue
        for app in root.glob("QoderWork*.app"):
            exe = _find_bundle_executable(app)
            if exe:
                return exe
    return None


def detect_grok() -> Optional[Path]:
    for root in (Path("/Applications"), HOME / "Applications"):
        for name in ("Grok.app", "Grok Bot.app", "GrokBot.app"):
            exe = _find_bundle_executable(root / name)
            if exe:
                return exe
        if root.is_dir():
            for app in root.glob("Grok*.app"):
                exe = _find_bundle_executable(app)
                if exe:
                    return exe
    return None


# Extra built-ins
TOOLS["qoder"] = ToolSpec(
    id="qoder",
    name="Qoder",
    description="Qoder, 独立 user-data",
    detect=detect_qoder,
    make_launcher=launcher_electron_generic,
    prepare_dirs=prepare_electron_dirs,
)
TOOLS["qoderwork"] = ToolSpec(
    id="qoderwork",
    name="QoderWork",
    description="QoderWork, 独立 user-data",
    detect=detect_qoderwork,
    make_launcher=launcher_electron_generic,
    prepare_dirs=prepare_electron_dirs,
)
TOOLS["grok"] = ToolSpec(
    id="grok",
    name="Grok Bot",
    description="Grok Bot, 独立 user-data",
    detect=detect_grok,
    make_launcher=launcher_electron_generic,
    prepare_dirs=prepare_electron_dirs,
)


# Recommended presets: special isolation (match Win [推荐])
PRESET_META = {
    "workbuddy": {"mode": "workbuddy", "mode_tag": "HOME隔离", "desc": "腾讯龙虾, HOME隔离多账号"},
    "cursor": {"mode": "electron", "mode_tag": "user-data", "desc": "Cursor, 独立 user-data"},
    "vscode": {"mode": "electron", "mode_tag": "user-data", "desc": "VS Code, 独立配置"},
    "chrome": {"mode": "chrome", "mode_tag": "Chrome配置", "desc": "Chrome, 独立用户数据"},
    "qoder": {"mode": "electron", "mode_tag": "user-data", "desc": "Qoder, 独立 user-data"},
    "qoderwork": {"mode": "electron", "mode_tag": "user-data", "desc": "QoderWork, 独立 user-data"},
    "grok": {"mode": "electron", "mode_tag": "user-data", "desc": "Grok Bot, 独立 user-data"},
}

_SKIP_APP_NAMES = {
    "safari", "mail", "maps", "photos", "music", "tv", "podcasts", "news",
    "stocks", "voice memos", "home", "clock", "calculator", "calendar",
    "contacts", "notes", "reminders", "books", "app store", "system settings",
    "system preferences", "finder", "preview", "textedit", "terminal",
    "utilities", "garageband", "imovie", "keynote", "pages", "numbers",
    "quicktime player", "dictionary", "chess", "font book", "image capture",
    "migration assistant", "screenshot", "tips", "siri", "mission control",
    "launchpad", "automator", "script editor", "activity monitor", "console",
    "disk utility", "grapher", "airdrop", "time machine", "boot camp assistant",
    "多账号快捷方式", "若打不开请先打开我",
}


@dataclass
class AppEntry:
    """One installed app row for the picker (mirrors Win Get-InstalledApps)."""
    id: str
    name: str
    tool: ToolSpec
    mode: str          # workbuddy | electron | chrome | generic
    mode_tag: str      # HOME隔离 / user-data / Chrome配置 / 通用
    desc: str
    is_preset: bool
    app_path: Path

    def list_label(self) -> str:
        tag = "[推荐] " if self.is_preset else ""
        return f"{tag}{self.name}  —  {self.mode_tag}  ·  {self.desc}"


def list_application_bundles() -> List[Path]:
    """Fast scan: only /Applications and ~/Applications top-level .app."""
    found: List[Path] = []
    seen = set()
    for root in (Path("/Applications"), HOME / "Applications"):
        if not root.is_dir():
            continue
        try:
            for app in sorted(root.iterdir()):
                if not app.name.endswith(".app"):
                    continue
                key = app.name.lower()
                if key in seen:
                    continue
                base = app.stem.lower()
                if base in _SKIP_APP_NAMES:
                    continue
                if base.startswith("workbuddy-") or base.startswith("cursor-"):
                    continue
                if "mac-account" in base or base.startswith("多账号"):
                    continue
                seen.add(key)
                found.append(app)
        except OSError:
            continue
    return found


def _guess_electron(app: Path) -> bool:
    """Heuristic: Electron apps usually ship app.asar / Electron Framework."""
    try:
        res = app / "Contents" / "Resources"
        if (res / "app.asar").exists() or (res / "electron.asar").exists():
            return True
        fw = app / "Contents" / "Frameworks"
        if fw.is_dir():
            for p in fw.iterdir():
                if "Electron" in p.name:
                    return True
        # Info.plist Electron hint
        plist = app / "Contents" / "Info.plist"
        if plist.exists():
            with plist.open("rb") as f:
                info = plistlib.load(f)
            exe = str(info.get("CFBundleExecutable") or "")
            if exe.lower() in {"electron", "helper"}:
                return True
    except Exception:
        pass
    return False


def _match_preset_tool(name: str, app: Path) -> Optional[ToolSpec]:
    n = name.lower().strip()
    # Exact / prefix matches for known tools
    mapping = [
        (("workbuddy", "codebuddy"), "workbuddy"),
        (("qoderwork", "qoder work"), "qoderwork"),
        (("qoder",), "qoder"),
        (("cursor",), "cursor"),
        (("visual studio code", "vs code"), "vscode"),
        (("google chrome", "chrome", "chromium"), "chrome"),
        (("grok bot", "grokbot", "grok"), "grok"),
    ]
    for names, tid in mapping:
        for dn in names:
            if n == dn or n.startswith(dn + " "):
                # avoid qoder matching qoderwork already handled first
                if tid == "qoder" and "qoderwork" in n.replace(" ", ""):
                    continue
                if tid == "vscode" and n in {"codebuddy", "workbuddy"}:
                    continue
                if tid in TOOLS:
                    return TOOLS[tid]
    # path-based
    low = str(app).lower()
    if "workbuddy" in low or "codebuddy" in low:
        return TOOLS.get("workbuddy")
    if "qoderwork" in low:
        return TOOLS.get("qoderwork")
    if "/qoder.app" in low or low.endswith("qoder.app"):
        return TOOLS.get("qoder")
    if "cursor.app" in low:
        return TOOLS.get("cursor")
    if "visual studio code" in low or low.endswith("/code.app"):
        return TOOLS.get("vscode")
    if "google chrome" in low or "chromium.app" in low:
        return TOOLS.get("chrome")
    if "grok" in low:
        return TOOLS.get("grok")
    return None


def tool_from_app_bundle(app: Path) -> Optional[ToolSpec]:
    exe = _find_bundle_executable(app)
    if not exe:
        return None
    name = app.stem
    preset = _match_preset_tool(name, app)
    if preset:
        # Prefer the installed bundle's detect via lambda
        return ToolSpec(
            id=preset.id,
            name=preset.name,
            description=preset.description,
            detect=lambda p=app: _find_bundle_executable(p),
            make_launcher=preset.make_launcher,
            prepare_dirs=preset.prepare_dirs,
        )
    tid = normalize_id(name)
    if _guess_electron(app):
        return ToolSpec(
            id=tid,
            name=name,
            description="疑似 Electron, 使用 --user-data-dir 隔离",
            detect=lambda p=app: _find_bundle_executable(p),
            make_launcher=launcher_electron_generic,
            prepare_dirs=prepare_electron_dirs,
        )
    return ToolSpec(
        id=tid,
        name=name,
        description="通用启动 (尝试独立数据目录)",
        detect=lambda p=app: _find_bundle_executable(p),
        make_launcher=launcher_electron_generic,
        prepare_dirs=prepare_electron_dirs,
    )


def scan_installed_apps() -> List[AppEntry]:
    """Build Win-style app list: presets first, then other Applications."""
    entries: List[AppEntry] = []
    used_ids = set()
    used_names = set()

    # 1) Known tools that are installed (force [推荐] even if path varies)
    for tid, tool in TOOLS.items():
        exe = tool.detect()
        if not exe:
            continue
        meta = PRESET_META.get(tid, {
            "mode": "electron", "mode_tag": "user-data", "desc": tool.description,
        })
        # Find .app path if possible
        app_path = Path("/Applications") / f"{tool.name}.app"
        for parent in exe.parents:
            if parent.suffix == ".app":
                app_path = parent
                break
        entries.append(AppEntry(
            id=tid,
            name=tool.name,
            tool=ToolSpec(
                id=tool.id,
                name=tool.name,
                description=meta["desc"],
                detect=tool.detect,
                make_launcher=tool.make_launcher,
                prepare_dirs=tool.prepare_dirs,
            ),
            mode=meta["mode"],
            mode_tag=meta["mode_tag"],
            desc=meta["desc"],
            is_preset=True,
            app_path=app_path,
        ))
        used_ids.add(tid)
        used_names.add(tool.name.lower())

    # 2) Other apps from Applications folders
    for app in list_application_bundles():
        stem = app.stem
        if stem.lower() in used_names:
            continue
        preset_tool = _match_preset_tool(stem, app)
        if preset_tool and preset_tool.id in used_ids:
            continue
        tool = tool_from_app_bundle(app)
        if not tool:
            continue
        if tool.id in used_ids or tool.name.lower() in used_names:
            continue
        is_preset = tool.id in PRESET_META
        if is_preset:
            meta = PRESET_META[tool.id]
            mode, mode_tag, desc = meta["mode"], meta["mode_tag"], meta["desc"]
            display_name = TOOLS[tool.id].name
        elif _guess_electron(app):
            mode, mode_tag = "electron", "user-data"
            desc = "疑似 Electron, 使用 --user-data-dir 隔离"
            display_name = stem
        else:
            mode, mode_tag = "generic", "通用"
            desc = "通用启动 (尝试独立数据目录)"
            display_name = stem
        entries.append(AppEntry(
            id=tool.id,
            name=display_name,
            tool=tool,
            mode=mode,
            mode_tag=mode_tag,
            desc=desc,
            is_preset=is_preset,
            app_path=app,
        ))
        used_ids.add(tool.id)
        used_names.add(display_name.lower())
        used_names.add(stem.lower())

    entries.sort(key=lambda e: (not e.is_preset, e.name.lower()))
    return entries


def installed_app_choices() -> List[Choice]:
    """Legacy Choice list for non-Tk flows."""
    items: List[Choice] = []
    for e in scan_installed_apps():
        items.append(Choice(e.list_label(), e.tool))
    return items



def clear_quarantine(path: Path) -> None:
    try:
        subprocess.run(
            ["xattr", "-dr", "com.apple.quarantine", str(path)],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


def write_executable(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    clear_quarantine(path)


def copy_icon(tool: ToolSpec, exe: Path, dest_icns: Path) -> bool:
    app = None
    for parent in exe.parents:
        if parent.suffix == ".app":
            app = parent
            break
    if not app:
        return False
    resources = app / "Contents" / "Resources"
    if not resources.is_dir():
        return False
    for name in (
        "WorkBuddy.icns",
        "Cursor.icns",
        "Code.icns",
        "app.icns",
        "electron.icns",
        "icon.icns",
    ):
        src = resources / name
        if src.exists():
            shutil.copy2(src, dest_icns)
            return True
    for src in resources.glob("*.icns"):
        shutil.copy2(src, dest_icns)
        return True
    return False


def create_app_bundle(
    tool: ToolSpec,
    profile: str,
    display: str,
    account_dir: Path,
    exe: Path,
    apps_dir: Path,
) -> Path:
    title = display if display else _title_case(profile)
    # .app 名尽量简洁：WorkBuddy-account1.app
    app_path = apps_dir / f"{tool.name}-{profile}.app"
    macos = app_path / "Contents" / "MacOS"
    resources = app_path / "Contents" / "Resources"
    macos.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)

    script_name = f"{tool.id}-{profile}"
    write_executable(macos / script_name, tool.make_launcher(profile, account_dir, exe))

    icns = resources / "AppIcon.icns"
    has_icon = copy_icon(tool, exe, icns)
    info = {
        "CFBundleName": f"{tool.name} {title}",
        "CFBundleDisplayName": f"{tool.name} {title}",
        "CFBundleIdentifier": f"local.mac-account.{tool.id}.{profile}",
        "CFBundleExecutable": script_name,
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1.0",
        "CFBundleShortVersionString": "1.0",
        "LSMinimumSystemVersion": "12.0",
        "NSHighResolutionCapable": True,
    }
    if has_icon:
        info["CFBundleIconFile"] = "AppIcon"
    with (app_path / "Contents" / "Info.plist").open("wb") as f:
        plistlib.dump(info, f)
    clear_quarantine(app_path)
    return app_path


def create_from_plans(
    tool: ToolSpec,
    plans: Sequence[AccountPlan],
    desktop: Path,
    apps_dir: Path,
) -> List[dict]:
    exe = tool.detect()
    if not exe:
        raise RuntimeError(
            f"本机还没安装 {tool.name}。\n请先装到「应用程序」文件夹，再重新运行本工具。"
        )

    apps_dir.mkdir(parents=True, exist_ok=True)
    desktop.mkdir(parents=True, exist_ok=True)
    results = []
    for plan in plans:
        account_dir = plan.data_dir
        tool.prepare_dirs(account_dir)
        # 仅生成 .app：桌面 + ~/Applications（双击无 Terminal）
        app = create_app_bundle(tool, plan.profile, plan.display, account_dir, exe, apps_dir)
        desk_app = create_app_bundle(tool, plan.profile, plan.display, account_dir, exe, desktop)
        results.append(
            {
                "profile": plan.profile,
                "display": plan.display,
                "data_dir": str(account_dir),
                "app": str(app),
                "desktop_app": str(desk_app),
                "exe": str(exe),
            }
        )
    return results



# ---------- Tk 已禁用（用户 Mac 深色模式黑屏）；仅用 osascript ----------

def _tk_available() -> bool:
    """Never use Tk on darwin — black screen on user's Mac."""
    return False


def run_tk_wizard() -> bool:
    """Disabled permanently. Always return False so callers use osascript."""
    return False


# ---------- 选择 UI（仅 osascript，不用 Tk） ----------

def _escape_applescript(text: str) -> str:
    """Escape for AppleScript string literals; newlines become return concat."""
    s = text.replace("\\", "\\\\").replace('"', '\\"')
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    if "\n" not in s:
        return s
    parts = s.split("\n")
    return '" & return & "'.join(parts)


def gui_available() -> bool:
    return sys.platform == "darwin" and shutil.which("osascript") is not None


def gui_ask_text(prompt: str, title: str = "多账号快捷方式", default: str = "") -> Optional[str]:
    """display dialog with text field. Empty string is OK (means all). None = cancel."""
    script = (
        'try\n'
        f'  set theResult to display dialog "{_escape_applescript(prompt)}" '
        f'with title "{_escape_applescript(title)}" '
        f'default answer "{_escape_applescript(default)}" '
        'buttons {"取消", "下一步"} default button "下一步" cancel button "取消"\n'
        '  return text returned of theResult\n'
        'on error\n'
        '  return "___CANCEL___"\n'
        'end try\n'
    )
    res = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, check=False)
    out = (res.stdout or "").rstrip("\n")
    if out == "___CANCEL___" or (res.returncode != 0 and not out):
        return None
    if out == "___CANCEL___":
        return None
    return out


def gui_choose(prompt: str, choices: Sequence[Choice], title: str = "多账号快捷方式") -> Optional[Choice]:
    if not choices:
        return None
    labels = [c.label.split("\n")[0] for c in choices]
    items = ", ".join(f'"{_escape_applescript(x)}"' for x in labels)
    script = (
        'try\n'
        f'  set theChoice to choose from list {{{items}}} '
        f'with prompt "{_escape_applescript(prompt)}" '
        f'with title "{_escape_applescript(title)}" '
        'OK button name "下一步" cancel button name "取消"\n'
        '  if theChoice is false then\n'
        '    return "CANCEL"\n'
        '  end if\n'
        '  return item 1 of theChoice\n'
        'on error\n'
        '  return "CANCEL"\n'
        'end try\n'
    )
    res = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, check=False)
    picked = (res.stdout or "").strip()
    if not picked or picked == "CANCEL":
        return None
    for c in choices:
        if c.label.split("\n")[0] == picked or c.label == picked:
            return c
    for c in choices:
        if picked in c.label:
            return c
    return None


def gui_choose_folder(prompt: str) -> Optional[Path]:
    script = (
        'try\n'
        f'  set theFolder to choose folder with prompt "{_escape_applescript(prompt)}"\n'
        '  return POSIX path of theFolder\n'
        'on error\n'
        '  return "CANCEL"\n'
        'end try\n'
    )
    res = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, check=False)
    picked = (res.stdout or "").strip()
    if not picked or picked == "CANCEL":
        return None
    return Path(picked.rstrip("/"))


def gui_confirm(message: str, title: str = "确认创建") -> bool:
    script = (
        'try\n'
        f'  display dialog "{_escape_applescript(message)}" '
        f'with title "{_escape_applescript(title)}" '
        'buttons {"取消", "开始创建"} default button "开始创建" cancel button "取消"\n'
        '  return "OK"\n'
        'on error\n'
        '  return "CANCEL"\n'
        'end try\n'
    )
    res = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, check=False)
    return (res.stdout or "").strip() == "OK"


def gui_alert(message: str, title: str = "多账号快捷方式") -> None:
    script = (
        f'display dialog "{_escape_applescript(message)}" '
        f'with title "{_escape_applescript(title)}" buttons {{"好"}} default button "好"'
    )
    subprocess.run(["osascript", "-e", script], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def gui_notify(title: str, message: str) -> None:
    script = (
        f'display notification "{_escape_applescript(message)}" '
        f'with title "{_escape_applescript(title)}"'
    )
    subprocess.run(["osascript", "-e", script], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def terminal_choose(prompt: str, choices: Sequence[Choice]) -> Optional[Choice]:
    print()
    print(prompt)
    for i, c in enumerate(choices, 1):
        print(f"  {i}) {c.label.split(chr(10))[0]}")
    print("  0) 取消")
    while True:
        raw = input("请按数字选择，然后回车: ").strip()
        if raw == "0":
            return None
        if raw.isdigit() and 1 <= int(raw) <= len(choices):
            return choices[int(raw) - 1]
        print("请只输入列表里的数字。")


def terminal_confirm(message: str, title: str = "确认创建") -> bool:
    print()
    print(message)
    picked = terminal_choose("确认吗？", [Choice("开始创建", True), Choice("取消", False)])
    return bool(picked and picked.value is True)


def tool_choices(installed_only: bool = False) -> List[Choice]:
    items: List[Choice] = []
    for tool in TOOLS.values():
        found = tool.detect()
        if installed_only and not found:
            continue
        mark = "已安装" if found else "未安装"
        items.append(Choice(f"{tool.name}（{mark}）— {tool.description}", tool))
    return items


def print_tools() -> None:
    print("可配置的工具：")
    for i, tool in enumerate(TOOLS.values(), 1):
        found = tool.detect()
        status = "已安装" if found else "未检测到安装"
        print(f"  {i}) {tool.name:<12} {tool.description}  [{status}]")
    print()
    root = freest_appaccounts_root()
    mounts = _mounts_with_free()
    if mounts:
        m, free, _ = mounts[0]
        print(f"当前最空闲磁盘：{m}（剩余 {format_size(free)}）")
        print(f"默认数据根目录：{root}")
        print()


def root_location_choices() -> List[Choice]:
    default_root = freest_appaccounts_root()
    mounts = _mounts_with_free()
    free_label = ""
    if mounts:
        m, free, _ = mounts[0]
        free_label = f"，剩余 {format_size(free)}"
        if m == Path("/"):
            place = "系统盘 · 用户家目录"
        else:
            place = f"磁盘 {m.name}"
    else:
        place = "用户家目录"

    choices = [
        Choice(f"默认：最空闲磁盘（{place}{free_label}）", default_root),
        Choice("家目录/AppAccounts", HOME / "AppAccounts"),
        Choice("桌面/AppAccounts", DESKTOP / "AppAccounts"),
        Choice("文稿/AppAccounts", DOCUMENTS / "AppAccounts"),
        Choice("我自己选一个文件夹…", "__pick__"),
    ]
    extra = 0
    for mount, free, _ in mounts:
        if mount == Path("/"):
            continue
        if mount / "AppAccounts" == default_root:
            continue
        choices.insert(
            1 + extra,
            Choice(
                f"磁盘 {mount.name}/AppAccounts（剩余 {format_size(free)}）",
                mount / "AppAccounts",
            ),
        )
        extra += 1
        if extra >= 3:
            break
    return choices


def shortcut_list_label(entry: "AppEntry") -> str:
    """Compact label for osascript choose from list (with [推荐])."""
    tag = "[推荐] " if entry.is_preset else ""
    return f"{tag}{entry.name}  ({entry.mode_tag})"


def filter_app_entries(entries: List["AppEntry"], keyword: str) -> List["AppEntry"]:
    kw = (keyword or "").strip().lower()
    if not kw:
        return entries
    out = []
    for e in entries:
        blob = f"{e.name} {e.id} {e.desc} {e.mode_tag} {e.app_path}".lower()
        if kw in blob:
            out.append(e)
    return out


def summarize(tool: ToolSpec, plans: Sequence[AccountPlan]) -> str:
    lines = [f"将为【{tool.name}】创建 {len(plans)} 个账号快捷方式：", ""]
    for p in plans:
        lines.append(f"• {p.display}（{p.profile}）")
        lines.append(f"  {p.data_dir}")
    lines.append("")
    lines.append("将生成：桌面 .app +「应用程序」里的 .app（双击不会打开终端）")
    return "\n".join(lines)


def finish_message(tool: ToolSpec, results: List[dict]) -> str:
    lines = [f"已创建 {len(results)} 个 {tool.name} 快捷方式：", ""]
    for item in results:
        lines.append(f"• {item.get('display') or item['profile']}")
        lines.append(f"  数据：{item['data_dir']}")
        desk = item.get("desktop_app") or item.get("app")
        lines.append(f"  桌面：{Path(desk).name}")
        lines.append(f"  应用：{Path(item['app']).name}")
    lines.append("")
    lines.append("去桌面双击即可打开；也可把应用程序里的图标拖进程序坞。")
    if tool.id == "workbuddy":
        lines.append("")
        lines.append("重要：请完全退出原来的 WorkBuddy 后，只用新快捷方式打开。")
        lines.append("每个窗口第一次要分别登录；登录态已按账号隔离，不会再串号。")
        lines.append("不要点「应用程序」里原来的 WorkBuddy 图标。")
    return "\n".join(lines)


def run_osascript_wizard() -> None:
    """Full native dialog flow — never uses Tk."""
    if not gui_available():
        print("当前环境没有 osascript，改用数字菜单。")
        run_wizard(use_gui=False)
        return

    try:
        entries = scan_installed_apps()
    except Exception as e:
        gui_alert(f"扫描本机应用失败：{e}")
        return
    if not entries:
        gui_alert("本机「应用程序」里没有检测到可用软件。请先安装后再试。")
        return

    keyword = gui_ask_text(
        f"已找到 {len(entries)} 个应用。\n\n"
        "可输入关键字筛选（如 WorkBuddy / Qoder / Cursor）。\n"
        "留空 = 显示全部，然后点「下一步」。",
        title="第1步 · 搜索应用（可留空）",
        default="",
    )
    if keyword is None:
        return
    filtered = filter_app_entries(entries, keyword)
    if not filtered:
        gui_alert(f"没有匹配「{keyword}」的应用，请再试一次。")
        return

    app_choices = [Choice(shortcut_list_label(e), e) for e in filtered]
    picked_app = gui_choose(
        "请选择要多开的软件（带 [推荐] 的支持更好隔离）：",
        app_choices,
        title="第1步 · 选择应用",
    )
    if not picked_app:
        return
    entry: AppEntry = picked_app.value  # type: ignore
    tool: ToolSpec = entry.tool

    if not tool.detect():
        gui_alert(f"还没安装 {tool.name}，请先装到「应用程序」后再试。")
        return

    picked_profiles = gui_choose(
        "请选择账号方案：",
        PROFILE_PRESETS,
        title="第2步 · 账号方案",
    )
    if not picked_profiles:
        return
    pairs: List[tuple] = list(picked_profiles.value)  # type: ignore
    pairs = [(normalize_id(pid), disp) for pid, disp in pairs]

    picked_root = gui_choose(
        "请选择数据存放位置：",
        root_location_choices(),
        title="第3步 · 数据位置",
    )
    if not picked_root:
        return
    if picked_root.value == "__pick__":
        folder = gui_choose_folder("请选择 AppAccounts 根目录（将在其中按 工具/账号 创建子目录）")
        if not folder:
            return
        root = folder if folder.name == "AppAccounts" else folder / "AppAccounts"
    else:
        root = Path(picked_root.value)  # type: ignore

    plans: List[AccountPlan] = []
    for profile, display in pairs:
        data_dir = default_account_dir(root, tool.id, profile)
        plans.append(AccountPlan(profile=profile, display=display, data_dir=data_dir))

    summary = summarize(tool, plans)
    if not gui_confirm(summary, title="第4步 · 确认创建"):
        return

    try:
        results = create_from_plans(tool, plans, DESKTOP, APPS_DIR)
    except Exception as e:
        gui_alert(str(e))
        return

    done = finish_message(tool, results)
    gui_alert(done, title="创建完成")
    gui_notify("多账号快捷方式", f"{tool.name} 已创建 {len(results)} 个快捷方式")
    try:
        subprocess.run(["open", str(DESKTOP)], check=False)
    except Exception:
        pass


def run_wizard(use_gui: Optional[bool] = None) -> None:
    """Legacy/terminal-capable wizard. GUI path delegates to osascript flow."""
    if use_gui is None:
        use_gui = gui_available()
    if use_gui:
        run_osascript_wizard()
        return

    choose = terminal_choose
    confirm = terminal_confirm

    try:
        entries = scan_installed_apps()
    except Exception:
        entries = []
    if entries:
        tools = [Choice(shortcut_list_label(e), e.tool) for e in entries]
    else:
        tools = tool_choices(installed_only=False)
        if not tools:
            print("没有可配置的工具。")
            return

    picked_tool = choose("请选择要配置的软件：", tools)
    if not picked_tool:
        return
    tool: ToolSpec = picked_tool.value  # type: ignore

    if not tool.detect():
        print(f"还没安装 {tool.name}，请先装到「应用程序」后再试。")
        return

    picked_profiles = choose("请选择账号方案：", PROFILE_PRESETS)
    if not picked_profiles:
        return
    pairs: List[tuple] = list(picked_profiles.value)  # type: ignore
    pairs = [(normalize_id(pid), disp) for pid, disp in pairs]

    picked_root = choose("先选默认数据位置：", root_location_choices())
    if not picked_root:
        return
    if picked_root.value == "__pick__":
        alt = terminal_choose(
            "选一个默认根目录：",
            [
                Choice(str(HOME / "AppAccounts"), HOME / "AppAccounts"),
                Choice(str(DESKTOP / "AppAccounts"), DESKTOP / "AppAccounts"),
                Choice(str(DOCUMENTS / "AppAccounts"), DOCUMENTS / "AppAccounts"),
            ],
        )
        if not alt:
            return
        root = Path(alt.value)  # type: ignore
    else:
        root = Path(picked_root.value)  # type: ignore

    plans: List[AccountPlan] = []
    for profile, display in pairs:
        data_dir = default_account_dir(root, tool.id, profile)
        plans.append(AccountPlan(profile=profile, display=display, data_dir=data_dir))

    summary = summarize(tool, plans)
    if not confirm(summary):
        print("已取消。")
        return

    try:
        results = create_from_plans(tool, plans, DESKTOP, APPS_DIR)
    except Exception as e:
        print(e)
        return
    print()
    print(finish_message(tool, results))


def interactive() -> None:
    # Never Tk — osascript only on Mac
    if gui_available():
        run_osascript_wizard()
        return
    print("=== Mac 多账号快捷方式（数字点选）===")
    print_tools()
    run_wizard(use_gui=False)


def cmd_list(_: argparse.Namespace) -> None:
    print_tools()


def cmd_create(args: argparse.Namespace) -> None:
    tool_key = args.tool.lower()
    if tool_key not in TOOLS:
        print(f"未知工具: {args.tool}")
        print("可用:", ", ".join(TOOLS.keys()))
        raise SystemExit(2)
    tool = TOOLS[tool_key]
    profiles = [normalize_id(p) for p in args.profiles.replace(",", " ").split() if p.strip()]
    if not profiles:
        profiles = ["account1", "account2"]
    root = Path(args.root).expanduser() if args.root else freest_appaccounts_root()
    plans = [
        AccountPlan(profile=p, display=p, data_dir=default_account_dir(root, tool.id, p))
        for p in profiles
    ]
    results = create_from_plans(
        tool,
        plans,
        Path(args.desktop).expanduser() if args.desktop else DESKTOP,
        Path(args.apps_dir).expanduser() if args.apps_dir else APPS_DIR,
    )
    print(finish_message(tool, results))


def cmd_gui(_: argparse.Namespace) -> None:
    """GUI entry used by 多账号快捷方式.app — osascript only, never Tk."""
    run_osascript_wizard()


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="mac-account",
        description="Mac 多账号快捷方式：全程点选，按账号自选数据目录",
    )
    sub = p.add_subparsers(dest="command")

    list_p = sub.add_parser("list", help="列出工具与最空闲磁盘")
    list_p.set_defaults(func=cmd_list)

    gui_p = sub.add_parser("gui", help="弹出系统选择窗口（推荐）")
    gui_p.set_defaults(func=cmd_gui)

    create_p = sub.add_parser("create", help="命令行直接创建")
    create_p.add_argument("tool", help="workbuddy / cursor / vscode / chrome")
    create_p.add_argument("-p", "--profiles", default="account1,account2")
    create_p.add_argument("--root", default="", help="数据根目录，默认最空闲磁盘/AppAccounts")
    create_p.add_argument("--desktop", default=str(DESKTOP))
    create_p.add_argument("--apps-dir", default=str(APPS_DIR))
    create_p.set_defaults(func=cmd_create)
    return p


def main(argv: Optional[Sequence[str]] = None) -> None:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        interactive()
        return
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "command", None):
        interactive()
        return
    args.func(args)


if __name__ == "__main__":
    main()

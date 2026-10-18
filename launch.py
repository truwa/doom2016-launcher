#!/usr/bin/env python3
from __future__ import annotations

"""Start a GOG copy of DOOM (2016) with Wine and the KosmicKrisp compat driver.

The game stays where the user put it. The Wine prefix lives under
~/Library/Application Support/DOOM 2016. The first launch downloads the latest
WineHQ macOS build from Gcenx and creates the prefix.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent
SUPPORT = Path.home() / "Library/Application Support/DOOM 2016"
UPSTREAM = ROOT / "dist/upstream"
WINE_DIST = UPSTREAM / "wine-extract/Wine Devel.app/Contents/Resources/wine"
WINE_RELEASE_API = "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/latest"
INSTALLED_WINE = SUPPORT / "wine"
KOSMIC_DIST = UPSTREAM / "kosmickrisp"
EXE_NAME = "DOOMx64vk.exe"


def installed_wine() -> Path | None:
    if (INSTALLED_WINE / "bin/wine").is_file() and (INSTALLED_WINE / "bin/wineserver").is_file():
        return INSTALLED_WINE
    return None


def resources_root() -> Path | None:
    chosen = os.environ.get("DOOM_RESOURCES")
    if chosen:
        return Path(chosen)
    candidate = ROOT.parent
    if (candidate / "vulkan/icd.d/kosmickrisp_icd.json").is_file():
        return candidate
    return None


def engine_parts():
    resources = resources_root()
    if resources is not None:
        icd = resources / "vulkan/icd.d/kosmickrisp_icd.json"
        frameworks = resources.parent / "Frameworks"
    else:
        icd = ROOT / "vulkan/kosmickrisp_icd.json"
        frameworks = KOSMIC_DIST
    kosmic = frameworks / "libvulkan_kosmickrisp.dylib"
    return icd, frameworks, kosmic


def resolve_engine():
    wine_root = installed_wine()
    if wine_root is None:
        resources = resources_root()
        if resources is not None and (resources / "wine/bin/wine").is_file():
            wine_root = resources / "wine"
        elif resources is None and (WINE_DIST / "bin/wine").is_file():
            wine_root = WINE_DIST
        else:
            wine_root = download_wine()
    icd, frameworks, kosmic = engine_parts()
    wine = wine_root / "bin/wine"
    missing = [path for path in (wine, wine_root / "bin/wineserver", icd, kosmic) if not path.is_file()]
    if missing:
        raise FileNotFoundError("Engine is incomplete: " + ", ".join(str(path) for path in missing))
    return wine_root, icd, frameworks, kosmic


def metal_hud_config_file() -> str | None:
    """The layout chosen with launchctl setenv MTL_HUD_CONFIG_FILE."""
    completed = subprocess.run(
        ["/bin/launchctl", "getenv", "MTL_HUD_CONFIG_FILE"],
        capture_output=True, text=True, check=False,
    )
    chosen = completed.stdout.strip() or os.environ.get("MTL_HUD_CONFIG_FILE", "").strip()
    if chosen and Path(chosen).is_file():
        return chosen
    return None


def wine_environment(prefix: Path, icd: Path, frameworks: Path, kosmic: Path, wine_root: Path,
                     metal_hud: bool = False, msync: bool = False) -> dict:
    environment = os.environ.copy()
    for inherited in ("WINEPREFIX", "WINEDEBUG", "WINEDLLOVERRIDES", "WINEDLLPATH",
                      "WINEMSYNC", "SikarugirAppWine11", "CX_FWD_COMPAT_GL_CTX"):
        environment.pop(inherited, None)
    environment["WINEPREFIX"] = str(prefix)
    environment["WINEBOOT_HIDE_DIALOG"] = "1"
    # Rosetta hides AVX unless asked. DOOM (2016) uses it.
    environment["ROSETTA_ADVERTISE_AVX"] = "1"
    if msync:
        environment["WINEMSYNC"] = "1"
    # Wine's built-in C++ runtime leaves DOOM jumping through a null pointer.
    # The Microsoft 2015–2022 x64 DLLs in the prefix have to win.
    environment["WINEDLLOVERRIDES"] = ",".join((
        "mscoree,mshtml=",
        "vcruntime140,vcruntime140_1,vcruntime140_threads=n",
        "msvcp140,msvcp140_1,msvcp140_2,msvcp140_atomic_wait,msvcp140_codecvt_ids=n",
        "concrt140,vcomp140,vcamp140,vccorlib140,mfc140u=n",
    ))
    spec = json.loads(icd.read_text(encoding="utf-8"))
    spec["ICD"]["library_path"] = str(kosmic)
    driver = SUPPORT / "kosmickrisp_icd.json"
    SUPPORT.mkdir(parents=True, exist_ok=True)
    driver.write_text(json.dumps(spec), encoding="utf-8")
    environment["VK_DRIVER_FILES"] = str(driver)
    environment["VK_ICD_FILENAMES"] = str(driver)
    environment["DYLD_FALLBACK_LIBRARY_PATH"] = ":".join((
        str(wine_root / "lib"), str(frameworks), "/usr/lib", "/usr/libexec", "/usr/lib/system"))
    environment["PATH"] = str(wine_root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin"
    environment.pop("MTL_HUD_ENABLED", None)
    environment.pop("METAL_HUD", None)
    environment.pop("MTL_HUD_CONFIG_FILE", None)
    if metal_hud:
        environment["MTL_HUD_ENABLED"] = "1"
        environment["METAL_HUD"] = "1"
        config = metal_hud_config_file()
        if config:
            environment["MTL_HUD_CONFIG_FILE"] = config
    return environment


def ensure_prefix(wine: Path, environment: dict) -> None:
    prefix = Path(environment["WINEPREFIX"])
    prefix.mkdir(parents=True, exist_ok=True)
    system32 = prefix / "drive_c/windows/system32"
    if not ((prefix / "system.reg").is_file() and system32.is_dir() and any(system32.iterdir())):
        subprocess.run([str(wine), "wineboot", "--init"], env=environment, check=True)
    ensure_microsoft_crt(wine, environment)


# Wine keeps these on raw HID. DOOM reads XInput, and the SDL mapping is what
# presents a pad as an XInput gamepad. Xbox pads already take that path.
SONY_GAMEPADS = (
    "054c/0ce6",  # DualSense
    "054c/0df2",  # DualSense Edge
    "054c/05c4",  # DualShock 4
    "054c/09cc",  # DualShock 4
    "054c/0ba0",  # DualShock 4 wireless adaptor
)


CRT_URL = "https://aka.ms/vs/17/release/vc_redist.x64.exe"


def microsoft_crt_present(prefix: Path) -> bool:
    system32 = prefix / "drive_c/windows/system32"
    runtime = system32 / "vcruntime140.dll"
    extra = system32 / "vcruntime140_1.dll"
    if not runtime.is_file() or not extra.is_file() or extra.stat().st_size < 20000:
        return False
    return b"Wine builtin DLL" not in runtime.read_bytes()


def ensure_microsoft_crt(wine: Path, environment: dict) -> None:
    """Install the Microsoft x64 C++ runtime into this prefix.

    Wine ships its own vcruntime140.dll. DOOM (2016) crashes a few seconds
    after launch when that builtin is used. The official redistributable is
    downloaded from Microsoft and is not part of the app.
    """
    prefix = Path(environment["WINEPREFIX"])
    if microsoft_crt_present(prefix):
        return
    cache = SUPPORT / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    redist = cache / "vc_redist.x64.exe"
    if not redist.is_file() or redist.stat().st_size < 1_000_000:
        request = urllib.request.Request(CRT_URL, headers={"User-Agent": "doom-2016-macos"})
        with urllib.request.urlopen(request, timeout=60) as response, redist.open("wb") as output:
            shutil.copyfileobj(response, output)
    quiet = environment.copy()
    quiet["WINEDEBUG"] = "-all"
    completed = subprocess.run(
        [str(wine), str(redist), "/install", "/quiet", "/norestart"],
        env=quiet, check=False, stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if completed.returncode not in (0, 1638, 3010):
        raise ValueError(f"The Microsoft C++ runtime installer exited {completed.returncode}")
    system32 = prefix / "drive_c/windows/system32"
    cache_root = prefix / "drive_c/ProgramData/Package Cache"
    copied = 0
    with tempfile.TemporaryDirectory(prefix="doom-crt-") as folder:
        extracted = Path(folder)
        for cab in cache_root.rglob("cab1.cab"):
            subprocess.run(["bsdtar", "-xf", str(cab), "-C", str(extracted)], check=False)
        for path in extracted.rglob("*.dll_amd64"):
            name = path.name[: -len("_amd64")]
            if name.lower() == "ucrtbase.dll":
                continue
            shutil.copyfile(path, system32 / name)
            copied += 1
    if copied == 0 or not microsoft_crt_present(prefix):
        raise FileNotFoundError("The Microsoft C++ runtime did not install")


def map_playstation_pads(wine: Path, environment: dict, mark=None) -> None:
    prefix = Path(environment["WINEPREFIX"])
    stamp = prefix / ".controller-mapping"
    expected = "\n".join(SONY_GAMEPADS) + "\n"
    if stamp.is_file() and stamp.read_text(encoding="utf-8") == expected:
        if mark is not None:
            mark("controllers already mapped")
        return
    started = time.monotonic()
    lines = ["Windows Registry Editor Version 5.00", ""]
    for device in SONY_GAMEPADS:
        lines.append(f"[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\winebus\\Devices\\{device}]")
        lines.append('"Hidraw"=dword:00000000')
        lines.append("")
    reg = prefix / "controller-mapping.reg"
    reg.write_text("\n".join(lines), encoding="utf-16")
    quiet = environment.copy()
    quiet["WINEDEBUG"] = "-all"
    completed = subprocess.run(
        [str(wine), "regedit", "/s", str(reg)],
        env=quiet, check=False, capture_output=True, text=True,
    )
    if completed.returncode == 0:
        stamp.write_text(expected, encoding="utf-8")
    elif mark is not None:
        detail = (completed.stderr or completed.stdout or "").strip()
        mark(f"controller mapping was not saved: {detail}")
    if mark is not None:
        mark(f"controllers mapped ({time.monotonic() - started:.2f}s)")


GOG_APP_ID = "1390579243"
GOGDL_VERSION = "v1.3.1"
GOGDL_FILES = {
    "arm64": ("gogdl_macos_arm64", "33a6d9b329c35f1caa7968009bf2f4f0a6f57cd00f749a4d2cb2204f3e794d2e"),
    "aarch64": ("gogdl_macos_arm64", "33a6d9b329c35f1caa7968009bf2f4f0a6f57cd00f749a4d2cb2204f3e794d2e"),
    "x86_64": ("gogdl_macos_x86_64", "9f78f5916141692704f9587e6519082abc2b12c5f8825548fe4d1dee1e46180c"),
}
GOG_PROGRESS = re.compile(r"= Progress:\s*([0-9.]+)")
GOG_ETA = re.compile(r"ETA:\s*([0-9:]+)")
GOG_DOWNLOADED = re.compile(r"= Downloaded:\s*([0-9.]+)\s*MiB")
GOG_SPEED = re.compile(r"Download\s+-\s*([0-9.]+)\s*MiB/s")


def ensure_gogdl() -> Path:
    name, digest = GOGDL_FILES.get(platform.machine(), GOGDL_FILES["arm64"])
    destination = SUPPORT / "bin" / name
    if destination.is_file() and hashlib.sha256(destination.read_bytes()).hexdigest() == digest:
        return destination
    print("status Downloading the GOG installer tool", flush=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    url = f"https://github.com/Heroic-Games-Launcher/heroic-gogdl/releases/download/{GOGDL_VERSION}/{name}"
    request = urllib.request.Request(url, headers={"User-Agent": "doom-2016-macos"})
    partial = destination.with_suffix(".partial")
    with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as output:
        shutil.copyfileobj(response, output)
    if hashlib.sha256(partial.read_bytes()).hexdigest() != digest:
        partial.unlink(missing_ok=True)
        raise ValueError("The GOG installer tool download did not match")
    partial.chmod(0o755)
    partial.replace(destination)
    return destination


def gog_auth(code: str) -> None:
    tool = ensure_gogdl()
    SUPPORT.mkdir(parents=True, exist_ok=True)
    auth = SUPPORT / "gog-auth.json"
    completed = subprocess.run(
        [str(tool), "--auth-config-path", str(auth), "auth", "--code", code],
        check=False, capture_output=True, text=True,
    )
    if completed.returncode != 0 or not auth.is_file():
        raise ValueError("GOG did not accept the sign-in")
    auth.chmod(0o600)
    print("status Signed in to GOG.", flush=True)


def gog_download(folder: Path) -> int:
    folder.mkdir(parents=True, exist_ok=True)
    auth = SUPPORT / "gog-auth.json"
    if not auth.is_file():
        raise FileNotFoundError("Sign in to GOG before installing the game")
    tool = ensure_gogdl()
    print("status Downloading DOOM (2016) from GOG", flush=True)
    command = [
        str(tool), "--auth-config-path", str(auth), "download", GOG_APP_ID,
        "--path", str(folder), "--platform", "windows", "--lang", "en-US", "--skip-dlcs",
    ]
    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True,
    )
    print(f"gog-pid {process.pid}", flush=True)

    def stop_download(_signum, _frame):
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            process.terminate()
        sys.exit(1)

    signal.signal(signal.SIGTERM, stop_download)
    reported = -1
    percent = 0.0
    downloaded = 0.0
    speed = 0.0
    eta = "-"
    assert process.stdout is not None
    for line in process.stdout:
        changed = False
        match = GOG_PROGRESS.search(line)
        if match:
            percent = float(match.group(1))
            found = GOG_ETA.search(line)
            if found:
                eta = found.group(1)
            changed = True
        found = GOG_DOWNLOADED.search(line)
        if found:
            downloaded = float(found.group(1))
            changed = True
        found = GOG_SPEED.search(line)
        if found:
            speed = float(found.group(1))
            changed = True
        if changed:
            print(f"gog-progress {percent:.2f} {downloaded:.2f} {speed:.2f} {eta}", flush=True)
            whole = int(percent)
            if whole != reported:
                reported = whole
                print(f"progress {whole}", flush=True)
            continue
        if "token" in line.lower():
            continue
        text = line.strip()
        if text:
            print(text, flush=True)
    return process.wait()


def fetch_latest_wine() -> tuple[str, str]:
    request = urllib.request.Request(WINE_RELEASE_API, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "doom-2016-macos",
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.load(response)
    tag = str(payload.get("tag_name") or "").strip().lstrip("vV")
    assets = payload.get("assets") or []
    match = next((asset for asset in assets
                  if str(asset.get("name") or "").startswith("wine-devel-")
                  and str(asset.get("name") or "").endswith("-osx64.tar.xz")), None)
    if match is None or not tag or not match.get("browser_download_url"):
        raise ValueError("The latest Wine release has no wine-devel macOS build")
    return tag, str(match["browser_download_url"])


def _wine_payload_skipped(relative: str) -> bool:
    path = relative.replace("\\", "/").strip("/")
    return (path == "share/wine/gecko" or path.startswith("share/wine/gecko/")
            or path == "share/wine/mono" or path.startswith("share/wine/mono/")
            or path.endswith("libMoltenVK.dylib")
            or path == "lib/wine/x86_64-unix/vulkan" or path.startswith("lib/wine/x86_64-unix/vulkan/"))


def _link_stays_inside(root: Path, link_path: Path, linkname: str) -> bool:
    if linkname.startswith("/"):
        return False
    normalized = os.path.normpath(str(link_path.parent / linkname))
    root_path = os.path.normpath(str(root))
    return normalized == root_path or normalized.startswith(root_path + os.sep)


def install_wine_archive(archive_path: Path, version: str, destination: Path | None = None) -> Path:
    destination = destination or INSTALLED_WINE
    staging = destination.with_name(destination.name + ".new")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    try:
        with tarfile.open(archive_path, "r:xz") as archive:
            root = ""
            for member in archive.getmembers():
                name = member.name.replace("\\", "/")
                if name.endswith("/bin/wine") or name.endswith("bin/wine"):
                    root = name[: -len("bin/wine")]
                    break
            if not root:
                raise ValueError("The Wine archive has no bin/wine")
            for member in archive.getmembers():
                name = member.name.replace("\\", "/")
                if not name.startswith(root):
                    continue
                relative = name[len(root):]
                if not relative or ".." in Path(relative).parts or _wine_payload_skipped(relative):
                    continue
                target = staging / relative
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.is_symlink() or target.exists():
                    target.unlink()
                if member.issym():
                    if _link_stays_inside(staging, target, member.linkname):
                        os.symlink(member.linkname, target)
                    continue
                if not member.isfile():
                    continue
                source = archive.extractfile(member)
                if source is None:
                    continue
                with source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
                os.chmod(target, member.mode & 0o777)
        if not (staging / "bin/wine").is_file() or not (staging / "bin/wineserver").is_file():
            raise ValueError("The Wine archive did not contain a usable build")
        previous = destination.with_name(destination.name + ".old")
        if previous.exists():
            shutil.rmtree(previous)
        if destination.exists():
            destination.rename(previous)
        staging.rename(destination)
        if previous.exists():
            shutil.rmtree(previous)
    except Exception:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
        raise
    (destination.parent / "WINE_VERSION").write_text(version.lstrip("vV") + "\n", encoding="utf-8")
    return destination


def wine_version_text() -> str:
    stamp = SUPPORT / "WINE_VERSION"
    if stamp.is_file():
        text = stamp.read_text(encoding="utf-8", errors="replace").strip()
        if text:
            return text
    return "unknown"


def download_wine(destination: Path | None = None) -> Path:
    tag, url = fetch_latest_wine()
    print(f"status Downloading Wine {tag}", flush=True)
    request = urllib.request.Request(url, headers={"User-Agent": "doom-2016-macos"})
    with tempfile.TemporaryDirectory(prefix="doom-wine-") as folder:
        archive = Path(folder) / f"wine-devel-{tag}-osx64.tar.xz"
        with urllib.request.urlopen(request, timeout=60) as response, archive.open("wb") as output:
            total = int(response.headers.get("Content-Length") or 0)
            received = 0
            reported = -1
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                output.write(chunk)
                received += len(chunk)
                if total:
                    percent = received * 100 // total
                    if percent != reported:
                        reported = percent
                        print(f"progress {percent}", flush=True)
        print("status Installing Wine", flush=True)
        installed = install_wine_archive(archive, tag, destination)
    print(f"installed wine {tag}", flush=True)
    return installed


def kill_wine() -> None:
    wine_root = installed_wine()
    if wine_root is None:
        resources = resources_root()
        if resources is not None and (resources / "wine/bin/wine").is_file():
            wine_root = resources / "wine"
        elif (WINE_DIST / "bin/wine").is_file():
            wine_root = WINE_DIST
    if wine_root is None:
        print("status Wine is not installed", flush=True)
        return
    environment = os.environ.copy()
    environment["WINEPREFIX"] = str(SUPPORT / "prefix")
    environment["PATH"] = str(wine_root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin"
    subprocess.run([str(wine_root / "bin/wineserver"), "-k"], env=environment, check=False)
    print("status Wine processes stopped", flush=True)


def setup_wine(force: bool = False) -> str:
    wine_root = None if force else installed_wine()
    if wine_root is None:
        wine_root = download_wine()
    version = wine_version_text()
    icd, frameworks, kosmic = engine_parts()
    prefix = SUPPORT / "prefix"
    environment = wine_environment(prefix, icd, frameworks, kosmic, wine_root)
    system32 = prefix / "drive_c/windows/system32"
    prefix_ready = (prefix / "system.reg").is_file() and system32.is_dir() and any(system32.iterdir())
    if not prefix_ready or not microsoft_crt_present(prefix):
        print("status Creating the Wine environment", flush=True)
    ensure_prefix(wine_root / "bin/wine", environment)
    print(f"ready {version}", flush=True)
    return version


def is_gog_doom(folder: Path) -> bool:
    if not (folder / EXE_NAME).is_file():
        return False
    return any(folder.glob("goggame-*.info"))


def locate_game(path: Path) -> Path:
    path = path.expanduser().resolve()
    candidates = [path]
    if path.is_dir():
        candidates.extend(child for child in path.iterdir() if child.is_dir())
        if path.parent != path:
            candidates.append(path.parent)
    for folder in candidates:
        if is_gog_doom(folder):
            return folder
    if (path / EXE_NAME).is_file() or any((child / EXE_NAME).is_file() for child in candidates if child.is_dir()):
        raise FileNotFoundError(f"{path} has DOOM files, but it is not a GOG install.")
    raise FileNotFoundError(f"No {EXE_NAME} in {path}")


DISPLAY_MODES = {"window": "0", "fullscreen": "1", "borderless": "2"}


def kill_prefix_wine(prefix: Path, wine_root: Path) -> None:
    """Stop Wine processes left behind after wineserver has already exited."""
    needles = (str(prefix), str(wine_root))
    listing = subprocess.run(
        ["ps", "-ax", "-o", "pid=,command="],
        capture_output=True, text=True, check=False,
    )
    for line in listing.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid_text, _, command = stripped.partition(" ")
        if "winedevice" not in command and "wineserver" not in command and not any(needle in command for needle in needles):
            continue
        try:
            pid = int(pid_text)
        except ValueError:
            continue
        if pid == os.getpid():
            continue
        probe = subprocess.run(
            ["lsof", "-a", "-p", str(pid), "-d", "cwd,txt", "-Fn"],
            capture_output=True, text=True, check=False,
        )
        if any(needle in probe.stdout for needle in needles):
            os.kill(pid, signal.SIGKILL)


def ensure_chroma_library(game: Path) -> bool:
    """DOOM calls into this library during startup. A missing file jumps to address 0."""
    dll = game / "CChromaEditorLibrary.dll"
    if dll.is_file():
        return False
    disabled = game / "CChromaEditorLibrary.dll.disabled"
    if disabled.is_file():
        disabled.replace(dll)
        return True
    return False


def is_problem(text: str) -> bool:
    folded = text.lower()
    if "exited" in folded:
        tail = folded.strip().split()[-1]
        try:
            return int(tail) != 0
        except ValueError:
            return True
    return any(needle in folded for needle in ("cannot", "failed", "not found", "error", "exception", "not saved"))


def launch(game: Path | None, display: str, metal_hud: bool, skip_intro: bool, dev_mode: bool,
           msync: bool, debug: bool = False, log_level: str = "normal",
           executable: Path | None = None) -> int:
    if log_level not in {"errors", "normal", "verbose"}:
        log_level = "normal"
    origin = time.monotonic()
    log_file = None
    if debug:
        SUPPORT.mkdir(parents=True, exist_ok=True)
        log_file = (SUPPORT / "launch.log").open("w", encoding="utf-8", buffering=1)
    seen: dict[str, int] = {}

    def emit(line: str, *, problem: bool = False) -> None:
        if log_level == "errors" and not problem:
            return
        if log_level == "normal" and not problem and not line.startswith("log "):
            return
        count = seen.get(line, 0) + 1
        seen[line] = count
        if count > 2 or (count == 2 and log_level != "verbose"):
            return
        shown = line if count == 1 else f"{line} (repeating)"
        print(shown, flush=True)
        if log_file is not None and count == 1:
            log_file.write(line + "\n")
            log_file.flush()

    def mark(label: str) -> None:
        emit(f"log {time.monotonic() - origin:7.2f}s {label}", problem=is_problem(label))

    other_game = executable is not None
    if other_game:
        exe = executable.expanduser().resolve()
        if not exe.is_file():
            raise FileNotFoundError(f"No executable at {exe}")
        cwd = exe.parent
        mark(f"executable {exe.name}")
    else:
        if game is None:
            raise FileNotFoundError("No game folder")
        game = locate_game(game)
        if ensure_chroma_library(game):
            mark("restored CChromaEditorLibrary.dll")
        elif not (game / "CChromaEditorLibrary.dll").is_file():
            mark("CChromaEditorLibrary.dll is missing")
        mark(f"game folder {game}")
        exe = game / EXE_NAME
        cwd = game
    wine_root, icd, frameworks, kosmic = resolve_engine()
    SUPPORT.mkdir(parents=True, exist_ok=True)
    prefix = SUPPORT / "prefix"
    environment = wine_environment(prefix, icd, frameworks, kosmic, wine_root, metal_hud, msync)
    environment["WINEDEBUG"] = "-all"
    if debug:
        mark(f"full log {SUPPORT / 'launch.log'}")
    wine = wine_root / "bin/wine"
    wineserver = wine_root / "bin/wineserver"

    def stop(_signum, _frame):
        subprocess.run([str(wineserver), "-k"], env=environment, check=False)
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    # wineserver keeps the sync mode it was started with, so replace it first.
    subprocess.run([str(wineserver), "-k"], env=environment, check=False)
    kill_prefix_wine(prefix, wine_root)
    mark("wineserver stopped")
    ensure_prefix(wine, environment)
    mark("prefix ready")
    map_playstation_pads(wine, environment, mark if log_level == "verbose" else None)
    if log_level != "verbose":
        mark("controllers mapped")
    if other_game:
        command = [str(wine), str(exe)]
    else:
        command = [str(wine), str(exe), "+set", "r_fullscreen", DISPLAY_MODES[display]]
        if skip_intro:
            command += ["+set", "com_skipIntroVideo", "1"]
        if dev_mode:
            command += ["+set", "devMode_enable", "1", "+set", "savegame_ignoreUnverified", "1"]
            # Dev mode prints engine warnings and waits for a key before the mission.
            command += ["+set", "com_hidePrintWarnings", "1", "+set", "com_skipKeyPressOnLoadScreens", "1"]
    if log_level == "verbose":
        emit(f"Engine: {wine_root}")
        emit(f"Game: {exe if other_game else game}")
        emit(f"KosmicKrisp: {kosmic}")
    game_environment = environment
    if debug:
        game_environment = environment.copy()
        game_environment["WINEDEBUG"] = "+timestamp,+pid,+tid,+all"
    mark(f"starting {exe.name}")
    # Leave the game on this process's own output. Capturing it through a pipe
    # fills the pipe and the game never opens its window.
    completed = subprocess.run(
        command, cwd=cwd, env=game_environment,
        stdout=log_file if debug else None,
        stderr=log_file if debug else None,
    )
    mark(f"{exe.name} exited {completed.returncode}")
    if log_file is not None:
        log_file.close()
    return completed.returncode


def check_engine() -> int:
    wine_root, icd, frameworks, kosmic = resolve_engine()
    SUPPORT.mkdir(parents=True, exist_ok=True)
    prefix = SUPPORT / "prefix"
    environment = wine_environment(prefix, icd, frameworks, kosmic, wine_root)
    ensure_prefix(wine_root / "bin/wine", environment)
    print(f"Engine: {wine_root}")
    print(f"KosmicKrisp: {kosmic}")
    print(f"Prefix: {prefix}")
    subprocess.run([str(wine_root / "bin/wine"), "--version"], env=environment, check=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, default=None,
                        help="GOG folder that contains DOOMx64vk.exe and goggame-*.info")
    parser.add_argument("--exe", type=Path, default=None,
                        help="Start this Windows executable with the same Wine and Vulkan setup")
    parser.add_argument("--display", default="window", choices=tuple(DISPLAY_MODES),
                        help="Start in a window, borderless, or exclusive full screen")
    parser.add_argument("--metal-hud", action="store_true", help="Show the Metal performance HUD")
    parser.add_argument("--skip-intro", action="store_true", help="Skip the introductory videos")
    parser.add_argument("--dev-mode", action="store_true",
                        help="Enable dev mode and load saves that fail verification")
    parser.add_argument("--msync", action="store_true", help="Use Wine msync for thread waiting")
    parser.add_argument("--log-level", default="normal", choices=("errors", "normal", "verbose"),
                        help="errors shows problems, normal adds launcher steps, verbose adds the game console")
    parser.add_argument("--debug", action="store_true",
                        help="Write a timestamped Wine trace to the launch log")
    parser.add_argument("--check", action="store_true", help="Create the Wine prefix and print the engine")
    parser.add_argument("--setup-wine", action="store_true",
                        help="Download Wine if needed and create the prefix")
    parser.add_argument("--update-wine", action="store_true",
                        help="Download the latest Wine again and keep the prefix")
    parser.add_argument("--kill-wine", action="store_true",
                        help="Stop the Wine processes for this launcher")
    parser.add_argument("--gog-auth", default=None, help="Exchange a GOG sign-in code")
    parser.add_argument("--gog-download", type=Path, default=None,
                        help="Install the owned GOG copy of DOOM (2016) into this folder")
    args = parser.parse_args()
    try:
        if args.kill_wine:
            kill_wine()
            return 0
        if args.gog_auth:
            gog_auth(args.gog_auth)
            return 0
        if args.gog_download is not None:
            return gog_download(args.gog_download)
        if args.setup_wine or args.update_wine:
            setup_wine(force=args.update_wine)
            return 0
        if args.check:
            return check_engine()
        if args.exe is not None:
            return launch(None, display=args.display, metal_hud=args.metal_hud,
                          skip_intro=False, dev_mode=False, msync=args.msync,
                          debug=args.debug, log_level=args.log_level, executable=args.exe)
        if args.game is None:
            parser.error("--game is required")
        return launch(args.game, display=args.display, metal_hud=args.metal_hud,
                      skip_intro=args.skip_intro, dev_mode=args.dev_mode, msync=args.msync,
                      debug=args.debug, log_level=args.log_level)
    except (FileNotFoundError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Cannot launch: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

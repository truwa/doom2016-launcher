#!/usr/bin/env python3
from __future__ import annotations

"""Start a GOG copy of DOOM (2016) with Wine and the KosmicKrisp compat driver.

The game stays where the user put it. The Wine prefix lives under
~/Library/Application Support/DOOM 2016. The first launch downloads the latest
WineHQ macOS build from Gcenx and creates the prefix.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
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


def wine_environment(prefix: Path, icd: Path, frameworks: Path, kosmic: Path, wine_root: Path,
                     metal_hud: bool = False) -> dict:
    environment = os.environ.copy()
    for inherited in ("WINEPREFIX", "WINEDEBUG", "WINEDLLOVERRIDES", "WINEDLLPATH",
                      "WINEMSYNC", "SikarugirAppWine11", "CX_FWD_COMPAT_GL_CTX"):
        environment.pop(inherited, None)
    environment["WINEPREFIX"] = str(prefix)
    environment["WINEBOOT_HIDE_DIALOG"] = "1"
    # Rosetta hides AVX unless asked. DOOM (2016) uses it.
    environment["ROSETTA_ADVERTISE_AVX"] = "1"
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
    if metal_hud:
        environment["MTL_HUD_ENABLED"] = "1"
        environment["METAL_HUD"] = "1"
    return environment


def ensure_prefix(wine: Path, environment: dict) -> None:
    prefix = Path(environment["WINEPREFIX"])
    prefix.mkdir(parents=True, exist_ok=True)
    system32 = prefix / "drive_c/windows/system32"
    if (prefix / "system.reg").is_file() and system32.is_dir() and any(system32.iterdir()):
        return
    subprocess.run([str(wine), "wineboot", "--init"], env=environment, check=True)


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
    if not ((prefix / "system.reg").is_file() and system32.is_dir() and any(system32.iterdir())):
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


def launch(game: Path, fullscreen: bool, metal_hud: bool, skip_intro: bool, dev_mode: bool) -> int:
    game = locate_game(game)
    wine_root, icd, frameworks, kosmic = resolve_engine()
    SUPPORT.mkdir(parents=True, exist_ok=True)
    prefix = SUPPORT / "prefix"
    environment = wine_environment(prefix, icd, frameworks, kosmic, wine_root, metal_hud)
    wine = wine_root / "bin/wine"
    wineserver = wine_root / "bin/wineserver"

    def stop(_signum, _frame):
        subprocess.run([str(wineserver), "-k"], env=environment, check=False)
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    ensure_prefix(wine, environment)
    exe = game / EXE_NAME
    command = [str(wine), str(exe), "+set", "r_fullscreen", "1" if fullscreen else "0"]
    if skip_intro:
        command += ["+set", "com_skipIntroVideo", "1"]
    if dev_mode:
        command += ["+set", "devMode_enable", "1", "+set", "savegame_ignoreUnverified", "1"]
    print(f"Engine: {wine_root}", flush=True)
    print(f"Game: {game}", flush=True)
    print(f"KosmicKrisp: {kosmic}", flush=True)
    completed = subprocess.run(command, cwd=game, env=environment)
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
    parser.add_argument("--display", default="window", choices=("window", "fullscreen"),
                        help="Start in a window or full screen")
    parser.add_argument("--metal-hud", action="store_true", help="Show the Metal performance HUD")
    parser.add_argument("--skip-intro", action="store_true", help="Skip the introductory videos")
    parser.add_argument("--dev-mode", action="store_true",
                        help="Enable dev mode and load saves that fail verification")
    parser.add_argument("--check", action="store_true", help="Create the Wine prefix and print the engine")
    parser.add_argument("--setup-wine", action="store_true",
                        help="Download Wine if needed and create the prefix")
    parser.add_argument("--update-wine", action="store_true",
                        help="Download the latest Wine again and keep the prefix")
    parser.add_argument("--kill-wine", action="store_true",
                        help="Stop the Wine processes for this launcher")
    args = parser.parse_args()
    try:
        if args.kill_wine:
            kill_wine()
            return 0
        if args.setup_wine or args.update_wine:
            setup_wine(force=args.update_wine)
            return 0
        if args.check:
            return check_engine()
        if args.game is None:
            parser.error("--game is required")
        return launch(args.game, fullscreen=args.display == "fullscreen", metal_hud=args.metal_hud,
                      skip_intro=args.skip_intro, dev_mode=args.dev_mode)
    except (FileNotFoundError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Cannot launch: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

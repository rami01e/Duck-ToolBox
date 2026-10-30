#!/usr/bin/env python3
"""Build the independent GPL engine with commit-pinned source references."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

SCRIPT_DIR = Path(__file__).resolve().parent
STANDALONE = (SCRIPT_DIR / "android").is_dir()
ROOT = SCRIPT_DIR if STANDALONE else SCRIPT_DIR.parent
ENGINE = ROOT if STANDALONE else ROOT / "components/play-integrity"
VENDOR = ENGINE / "vendor" if STANDALONE else ROOT / "target/play-integrity/vendor"
DEPENDENCIES = {
    "json": ("nlohmann/json", "55f93686c01528224f448c19128836e7df245f72"),
    "local_cxa_atexit_finalize_impl": (
        "5ec1cff/local_cxa_atexit_finalize_impl", "b269136606d6f230089fbf47a0b219f7f2ccef3c"
    ),
    # ByteHook replaces ShadowHook: its PLT hooking supports x86 and x86_64 in addition
    # to both ARM ABIs, which the inline-only ShadowHook does not.
    "bytehook": ("bytedance/bhook", "642257e470a3d80ebc3428ff1e3b2d195721b636"),
    "hiddenapibypass": ("LSPosed/AndroidHiddenApiBypass", "4efc64fcada7df15e7b5ba068e774343b760270d"),
}
# One Rust engine binary per supported device architecture; the installer picks the
# matching copy and installs it under the canonical `pif-engine` name.
ENGINE_TARGETS = {
    "aarch64-linux-android": "arm64",
    "x86_64-linux-android": "x86_64",
}


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def dependencies():
    VENDOR.mkdir(parents=True, exist_ok=True)
    for name, (repo, commit) in DEPENDENCIES.items():
        destination = VENDOR / name
        if (destination / ".revision").exists() and (destination / ".revision").read_text() == commit:
            continue
        archive = VENDOR / f"{name}-{commit}.tar.gz"
        if not archive.exists():
            with urllib.request.urlopen(f"https://codeload.github.com/{repo}/tar.gz/{commit}", timeout=60) as response:
                archive.write_bytes(response.read())
        if destination.exists():
            shutil.rmtree(destination)
        destination.mkdir()
        with tarfile.open(archive) as source:
            for member in source.getmembers():
                parts = Path(member.name).parts[1:]
                if not parts:
                    continue
                member.name = "/".join(parts)
                source.extract(member, destination, filter="data")
        (destination / ".revision").write_text(commit)


def source_revision():
    """The exact Git revision used for this engine build, not a moving branch."""
    if STANDALONE:
        return None
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host-only", action="store_true")
    parser.add_argument("--dependencies-only", action="store_true")
    parser.add_argument("--sdk", default=os.environ.get("ANDROID_HOME", str(Path.home() / "Library/Android/sdk")))
    args = parser.parse_args()
    dependencies()
    if args.dependencies_only:
        return
    env = {**os.environ, "PIF_VENDOR_DIR": str(VENDOR), "ANDROID_HOME": args.sdk}
    run("cargo", "build", "--locked", "--manifest-path", ENGINE / "Cargo.toml", "--target-dir", ROOT / "target/pif-engine", env=env)
    if args.host_only:
        return
    ndk = Path(args.sdk) / "ndk/30.0.16248370"
    if not ndk.is_dir():
        raise SystemExit(f"Install the pinned NDK first: sdkmanager 'ndk;{ndk.name}'")
    toolchains = list((ndk / "toolchains/llvm/prebuilt").glob("*/bin"))
    if not toolchains:
        raise SystemExit("NDK host toolchain missing")
    toolchain = toolchains[0]
    for target in ENGINE_TARGETS:
        linker = toolchain / (f"{target}26-clang.cmd" if os.name == "nt" else f"{target}26-clang")
        env.update({
            f"CARGO_TARGET_{target.upper().replace('-', '_')}_LINKER": str(linker),
            f"CC_{target.replace('-', '_')}": str(linker),
            f"AR_{target.replace('-', '_')}": str(toolchain / ("llvm-ar.exe" if os.name == "nt" else "llvm-ar")),
        })
        run("cargo", "build", "--locked", "--release", "--manifest-path", ENGINE / "Cargo.toml", "--target-dir", ROOT / "target/pif-engine", "--target", target, env=env)
    wrapper = ENGINE / "android/gradlew"
    gradle_command = [wrapper.with_suffix(".bat")] if os.name == "nt" else ["sh", wrapper]
    run(*gradle_command, "--no-daemon", "assembleRelease", cwd=wrapper.parent, env=env)
    payload = ROOT / "module/play-integrity"
    if payload.exists():
        shutil.rmtree(payload)
    payload.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ENGINE / "scripts", payload / "scripts", dirs_exist_ok=True)
    for target, arch in ENGINE_TARGETS.items():
        shutil.copy2(ROOT / f"target/pif-engine/{target}/release/pif-engine", payload / f"pif-engine-{arch}")
    dex = ENGINE / "android/app/build/intermediates/dex/release/minifyReleaseWithR8/classes.dex"
    shutil.copy2(dex, payload / "classes.dex")
    libraries = ENGINE / "android/app/build/intermediates/stripped_native_libs/release/stripReleaseDebugSymbols/out/lib"
    zygisk = ROOT / "module/zygisk"
    if zygisk.exists():
        shutil.rmtree(zygisk)
    zygisk.mkdir(exist_ok=True)
    for abi in ["arm64-v8a", "armeabi-v7a", "x86_64"]:
        shutil.copy2(libraries / abi / "libplayintegrityfix.so", zygisk / f"{abi}.so")
    notices = ROOT / "module/licenses/play-integrity"
    if notices.exists():
        shutil.rmtree(notices)
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ENGINE / "LICENSE", notices / "GPL-3.0.txt")
    for name in ["README.md", "RULES.md", "NOTICE", "UPSTREAM.json"]:
        shutil.copy2(ENGINE / name, notices / name)
    for name in DEPENDENCIES:
        for path in (VENDOR / name).rglob("*"):
            if path.is_file() and ("LICENSE" in path.name.upper() or path.name.upper()=="NOTICE"):
                destination=notices / name / path.relative_to(VENDOR / name)
                destination.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(path,destination)
    # Maven dependencies' license texts are kept with the source component.
    shutil.copytree(ENGINE / "licenses", notices, dirs_exist_ok=True)
    # Corresponding source lives in the exact published Git commit, not the module ZIP.
    commit = source_revision()
    if commit:
        source_url = f"https://github.com/eltavine/Duck-ToolBox/tree/{commit}/components/play-integrity"
        (notices / "SOURCE.txt").write_text(
            f"Corresponding Play Integrity GPLv3 source (Git commit {commit}):\n"
            f"{source_url}\n"
            "Build and dependency retrieval script:\n"
            f"https://github.com/eltavine/Duck-ToolBox/blob/{commit}/scripts/build-play-integrity.py\n"
            "This script retrieves pinned dependency sources. The engine's property\n"
            "interception uses ByteHook instead of ShadowHook for x86_64 compatibility.\n"
        )
    (notices.parent / "play-integrity-source.tar.gz").unlink(missing_ok=True)
    (ROOT / "module/webroot/licenses/play-integrity-source.tar.gz").unlink(missing_ok=True)
    artifacts = [*(p for p in payload.rglob("*") if p.is_file()), *zygisk.glob("*.so")]
    (payload / "build.json").write_text(json.dumps({
        "upstream_revision": json.loads((ENGINE / "UPSTREAM.json").read_text())["revision"],
        "source_commit": commit,
        "files": {p.relative_to(ROOT / "module").as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in artifacts},
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()

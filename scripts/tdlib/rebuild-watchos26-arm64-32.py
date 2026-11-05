#!/usr/bin/env python3
"""Isolated full TDLib arm64_32 build at watchOS 26.0; does not install."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import time

REPO = Path(__file__).resolve().parents[2]
ROOT = ORIGINAL = OPENSSL = LIBRARIES = None
PATCH = REPO / "native-patches/tdlib-token-invalidated.patch"
COMMIT = "89ebded9571b7bb589ec1bd05e585fffa4c580e2"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def inventory(root):
    return {str(p.relative_to(root)): sha(p) for p in sorted(root.rglob("*"))
            if p.is_file() and ".git" not in p.relative_to(root).parts}


def main():
    global ROOT, ORIGINAL, OPENSSL, LIBRARIES
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Read-only pinned arm64_32 TDLib source")
    parser.add_argument("--openssl", type=Path, required=True, help="Read-only arm64_32 OpenSSL build")
    parser.add_argument("--libraries", type=Path, required=True, help="Read-only current TDLib library directories")
    parser.add_argument("--output", type=Path, required=True, help="New isolated directory under /tmp")
    parser.add_argument("--jobs", type=int, default=6)
    args = parser.parse_args()
    assert 1 <= args.jobs <= 16
    ROOT, ORIGINAL, OPENSSL, LIBRARIES = args.output.resolve(), args.source.resolve(), args.openssl.resolve(), args.libraries.resolve()
    if not __debug__:
        raise RuntimeError("Do not disable verification assertions")
    assert str(ROOT).startswith("/private/tmp/") or str(ROOT).startswith("/tmp/")
    assert not ROOT.exists() and not args.output.is_symlink(), "Output must be new"
    for path in [ORIGINAL, OPENSSL, LIBRARIES, (LIBRARIES / "lib-device").resolve(), (LIBRARIES / "lib-simulator").resolve()]:
        assert ROOT != path and path not in ROOT.parents, "Output must be outside every input"
    ROOT.mkdir(parents=True)
    source, build, deps = ROOT / "source", ROOT / "build", ROOT / "openssl"
    assert not any(p.exists() for p in (source, build, deps)), "Build output must be new"
    assert run(["git", "-C", ORIGINAL, "rev-parse", "HEAD"]) == COMMIT
    assert not run(["git", "-C", ORIGINAL, "status", "--porcelain", "--untracked-files=no"])
    assert sha(ORIGINAL / "td/telegram/DeviceTokenManager.cpp") == "db57cd48ec6b778f34d90e6fc8c0f7a11af4bc49f066d6c1f652ca2b10e78538"
    before_source = inventory(ORIGINAL)
    before_openssl = inventory(OPENSSL)
    before_libraries = {group: inventory(LIBRARIES / group) for group in ("lib-device", "lib-simulator")}
    # Copy .git too so TDLib's embedded commit remains the same verified version.
    shutil.copytree(ORIGINAL, source, symlinks=False)
    shutil.copytree(OPENSSL, deps, symlinks=False)
    assert inventory(source) == before_source and inventory(deps) == before_openssl
    subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-p1", "-i", str(PATCH)], cwd=source, check=True)
    assert [p for p, value in inventory(source).items() if before_source.get(p) != value] == ["td/telegram/DeviceTokenManager.cpp"]
    sdk = run(["xcrun", "--sdk", "watchos", "--show-sdk-path"])
    cmake = shutil.which("cmake")
    flags = "-I" + str(deps / "include") + " -mwatchos-version-min=26.0"
    command = [cmake, "-S", str(source), "-B", str(build), "-G", "Unix Makefiles",
               "-DIOS_PLATFORM=WATCHOS", "-DIOS_ARCH=arm64_32", "-DIOS_DEPLOYMENT_TARGET=26.0",
               "-DCMAKE_IOS_SDK_ROOT=" + sdk, "-DCMAKE_TOOLCHAIN_FILE=" + str(source / "CMake/iOS.cmake"),
               "-DCMAKE_MAKE_PROGRAM=/usr/bin/make", "-DCMAKE_BUILD_TYPE=Release",
               "-DCMAKE_C_FLAGS=" + flags, "-DCMAKE_CXX_FLAGS=" + flags,
               "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON", "-DTD_ENABLE_LTO=OFF",
               "-DOPENSSL_FOUND=1", "-DOPENSSL_CRYPTO_LIBRARY=" + str(deps / "lib/libcrypto.a"),
               "-DOPENSSL_SSL_LIBRARY=" + str(deps / "lib/libssl.a"),
               "-DOPENSSL_INCLUDE_DIR=" + str(deps / "include"),
               "-DOPENSSL_LIBRARIES=" + str(deps / "lib/libcrypto.a") + ";" + str(deps / "lib/libssl.a"),
               "-DCMAKE_INSTALL_PREFIX=" + str(ROOT / "unused-install")]
    manifest = {"source_commit": COMMIT, "original_source_files": before_source,
                "openssl_files": before_openssl, "baseline_libraries": before_libraries,
                "patch_sha256": sha(PATCH), "configure_command": command, "jobs": args.jobs,
                "baseline_library_root": str(LIBRARIES), "recipe_sha256": sha(Path(__file__)),
                "compiler": run(["xcrun", "clang++", "--version"]), "started": time.time()}
    (ROOT / "inputs.json").write_text(json.dumps(manifest, indent=2) + "\n")
    with (ROOT / "configure.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    assert result.returncode == 0, "Configure failed: inspect configure.log"
    commands = json.loads((build / "compile_commands.json").read_text())
    assert commands and all("-arch arm64_32" in item["command"] for item in commands)
    assert all("-mwatchos-version-min=26.0" in item["command"] for item in commands)
    assert all(str(ORIGINAL) not in item["command"] and str(OPENSSL) not in item["command"] for item in commands)
    manifest["compile_commands_count"] = len(commands)
    manifest["build_command"] = [cmake, "--build", str(build), "--target", "tdjson_static", "--parallel", str(args.jobs)]
    print("Configured: %d commands, all arm64_32/watchOS26.0; source and dependencies copied." % len(commands), flush=True)
    with (ROOT / "build.log").open("w") as log:
        result = subprocess.run(manifest["build_command"], stdout=log, stderr=subprocess.STDOUT,
                                env=dict(os.environ, ZERO_AR_DATE="1"))
    manifest["build_exit_code"] = result.returncode
    manifest["elapsed_seconds"] = time.time() - manifest["started"]
    (ROOT / "build-result.json").write_text(json.dumps(manifest, indent=2) + "\n")
    assert result.returncode == 0, "Build failed: inspect build.log"
    assert inventory(ORIGINAL) == before_source, "Original source changed"
    assert inventory(OPENSSL) == before_openssl, "Original dependencies changed"
    assert {group: inventory(LIBRARIES / group) for group in before_libraries} == before_libraries, "Project libraries changed"
    print("Full arm64_32 native build succeeded in %.1fs; all inputs unchanged; no installation." % manifest["elapsed_seconds"], flush=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Rebuild one pinned TDLib translation unit into NEW copied watch archives only.

Reads existing sources/build flags/archive members, writes only --output. Does
not install, swap project symlinks, run CMake, launch an app, or access any DB.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess

REPO = Path(__file__).resolve().parents[2]
SOURCE_SHA256 = "db57cd48ec6b778f34d90e6fc8c0f7a11af4bc49f066d6c1f652ca2b10e78538"
MEMBER = "DeviceTokenManager.cpp.o"


def run(command, **kwargs):
    return subprocess.check_output([str(value) for value in command], **kwargs)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    return digest(path.read_bytes())


def members(path):
    return run(["xcrun", "ar", "-t", path], text=True).splitlines()


def member_data(path, name):
    return run(["xcrun", "ar", "-p", path, name])


def archive_payloads(path):
    """Read BSD archive members once, excluding the rebuilt symbol index."""
    raw = path.read_bytes()
    assert raw.startswith(b"!<arch>\n"), "Expected a thin Unix archive"
    offset = 8
    result = {}
    while offset < len(raw):
        header = raw[offset:offset + 60]
        assert len(header) == 60 and header[58:] == b"\x60\n", "Invalid ar member"
        name = header[:16].decode("ascii").strip()
        size = int(header[48:58].strip())
        data = raw[offset + 60:offset + 60 + size]
        assert len(data) == size
        if name.startswith("#1/"):
            name_size = int(name[3:])
            name = data[:name_size].rstrip(b"\0").decode("utf-8")
            data = data[name_size:]
        else:
            name = name.rstrip("/")
        assert name and name not in result, "Unsupported or duplicate ar member"
        result[name] = data
        offset += 60 + size + size % 2
    return {name: data for name, data in result.items() if not name.startswith("__.SYMDEF")}


def matches_archived_object(member, object_bytes):
    # Apple's archive writer can include up to seven newline alignment bytes.
    padding = len(member) - len(object_bytes)
    return member == object_bytes or (0 < padding < 8 and member == object_bytes + b"\n" * padding)


def canonical_object(data):
    """Compare code/data, relocation targets and exported bindings after ld -r.

    The pinned device arm64 archive was historically relinked: local names and
    symbol indices changed. Resolve local targets to their section/address;
    ignore only N_PEXT on locals and N_WEAK_REF on already-defined symbols.
    Undefined/weak definitions and every actual relocation remain checked.
    """
    assert struct.unpack_from("<I", data)[0] == 0xfeedfacf, "Expected 64-bit Mach-O object"
    offset = 32
    sections, symbol_table = [], None
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, offset)
        if command == 2:
            symbol_table = struct.unpack_from("<4I", data, offset + 8)
        if command == 0x19:
            for index in range(struct.unpack_from("<I", data, offset + 64)[0]):
                sections.append(struct.unpack_from("<16s16sQQ8I", data, offset + 72 + index * 80))
        offset += size
    assert symbol_table
    symoff, count, stroff, string_size = symbol_table
    symbols = []
    for index in range(count):
        strx, kind, section, description, value = struct.unpack_from("<IBBHQ", data, symoff + index * 16)
        start = stroff + strx
        name = data[start:data.index(b"\0", start, stroff + string_size)].decode()
        # ld -r resolves references to definitions within this same object.
        if kind & 0x0e == 0x0e:
            description &= ~0x40
        symbols.append((name, kind, section, description, value))
    result = {"sections": [], "external_symbols": sorted(symbol for symbol in symbols if symbol[1] & 1)}
    for section in sections:
        name = section[1].rstrip(b"\0").decode() + "," + section[0].rstrip(b"\0").decode()
        address, length, file_offset, alignment, reloff, relocation_count, flags = section[2:9]
        relocations = []
        for index in range(relocation_count):
            relative_address, bits = struct.unpack_from("<II", data, reloff + index * 8)
            symbol_index, external = bits & 0xffffff, (bits >> 27) & 1
            if external:
                symbol = symbols[symbol_index]
                target = ("external", symbol[0]) if symbol[1] & 1 else ("local", symbol[1] & ~0x10, symbol[2], symbol[4])
            else:
                target = ("number", symbol_index)
            relocations.append((relative_address, (bits >> 24) & 1, (bits >> 25) & 3, external, (bits >> 28) & 15, target))
        result["sections"].append((name, address, length, alignment, flags, digest(data[file_offset:file_offset + length]), sorted(relocations)))
    return result


def object_version(path):
    text = run(["xcrun", "otool", "-l", path], text=True)
    match = re.search(r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (\d+)\s+minos ([\d.]+)\s+sdk ([\d.]+)", text)
    assert match, "Missing object build-version metadata"
    return {"platform": int(match[1]), "minimum_os": match[2], "sdk": match[3]}


def flags_from_build(build, sdk, version):
    text = (build / "CMakeFiles/tdcore.dir/flags.make").read_text()
    result = []
    for key in ("CXX_DEFINES", "CXX_INCLUDES", "CXX_FLAGS"):
        match = re.search(r"^" + key + r" = (.*)$", text, re.M)
        assert match, "Missing " + key
        result.extend(shlex.split(match[1]))
    index = result.index("-isysroot")
    result[index + 1] = sdk
    result = [flag for flag in result if not flag.startswith(("-mwatchos-version-min=", "-mwatchos-simulator-version-min="))]
    minimum_flag = "-mwatchos-simulator-version-min=" if version["platform"] == 9 else "-mwatchos-version-min="
    result.append(minimum_flag + version["minimum_os"])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-arm64", type=Path, required=True)
    parser.add_argument("--source-arm64-32", type=Path, required=True)
    parser.add_argument("--build-device-arm64", type=Path, required=True)
    parser.add_argument("--build-device-arm64-32", type=Path, required=True)
    parser.add_argument("--build-simulator", type=Path, required=True)
    parser.add_argument("--libraries", type=Path, required=True, help="Read-only baseline TDLib directory (may contain symlinks)")
    parser.add_argument("--output", type=Path, required=True, help="New isolated output directory; never project TDLib")
    args = parser.parse_args()
    output = args.output.absolute()
    assert not output.exists() and not output.is_symlink(), "Output must not exist"
    read_roots = [args.source_arm64, args.source_arm64_32, args.build_device_arm64, args.build_device_arm64_32,
                  args.build_simulator, args.libraries, args.libraries / "lib-device", args.libraries / "lib-simulator"]
    for root in read_roots:
        resolved = root.resolve()
        assert output.resolve() != resolved and resolved not in output.resolve().parents, "Output must be outside every input tree"
    assert (REPO / "TDLib").resolve() not in output.resolve().parents, "Never write through project TDLib symlinks"
    patch = REPO / "native-patches/tdlib-token-invalidated.patch"
    source_info = {}
    for name, root, expected_commit in (
        ("arm64", args.source_arm64, "af0cb1d30a1e5cb1a10cd83b48998ca9ea9ce249"),
        ("arm64_32", args.source_arm64_32, "89ebded9571b7bb589ec1bd05e585fffa4c580e2"),
    ):
        source = root / "td/telegram/DeviceTokenManager.cpp"
        commit = run(["git", "-C", root, "rev-parse", "HEAD"], text=True).strip()
        assert commit == expected_commit and file_digest(source) == SOURCE_SHA256, "Source revision drift"
        status = run(["git", "-C", root, "status", "--porcelain", "--untracked-files=no"], text=True)
        assert not status.strip(), "Tracked native source changes require separate review"
        source_info[name] = {"root": str(root.resolve()), "commit": commit, "source_sha256": file_digest(source)}
    baseline = {}
    for name in ("lib-device", "lib-simulator"):
        directory = args.libraries / name
        baseline[name] = {path.name: file_digest(path) for path in sorted(directory.glob("*.a"))}
        assert "libtdcore.a" in baseline[name], "Missing core archive"
    output.mkdir(parents=True)
    source = output / "source/td/telegram/DeviceTokenManager.cpp"
    source.parent.mkdir(parents=True)
    shutil.copy2(args.source_arm64 / "td/telegram/DeviceTokenManager.cpp", source)
    subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-p1", "-i", str(patch)], cwd=output / "source", check=True)
    compiler = run(["xcrun", "--find", "clang++"], text=True).strip()
    manifest = {"source": source_info, "patch_sha256": file_digest(patch), "patched_source_sha256": file_digest(source),
                "compiler": run([compiler, "--version"], text=True), "baseline_archives": baseline, "slices": {}}
    specs = [
        ("simulator-arm64", "arm64", "watchsimulator", args.build_simulator, "lib-simulator"),
        ("device-arm64", "arm64", "watchos", args.build_device_arm64, "lib-device"),
        ("device-arm64_32", "arm64_32", "watchos", args.build_device_arm64_32, "lib-device"),
    ]
    for name, arch, sdk_name, build, group in specs:
        staging = output / name
        staging.mkdir()
        original = args.libraries / group / "libtdcore.a"
        thin = staging / "libtdcore.a"
        if group == "lib-device":
            run(["xcrun", "lipo", original, "-thin", arch, "-output", thin])
        else:
            shutil.copy2(original, thin)
        archive_members = members(thin)
        assert archive_members.count(MEMBER) == 1, "Expected exactly one target object"
        assert len(archive_members) == len(set(archive_members)), "Duplicate archive members require explicit review"
        old_object = build / "CMakeFiles/tdcore.dir/td/telegram" / MEMBER
        old_bytes = member_data(thin, MEMBER)
        build_bytes = old_object.read_bytes()
        assert matches_archived_object(member_data(build / "libtdcore.a", MEMBER), build_bytes), "Build archive/object mismatch"
        identity = "exact object with archive alignment"
        if not matches_archived_object(old_bytes, build_bytes):
            # This exact historical device member was relinked, never accept
            # arbitrary mismatches merely because a few sections happen to match.
            assert name == "device-arm64" and digest(old_bytes) == "9126d0b3a135c8c2cb631a4bb5f380066e716776af8bb01c03b968dc8ac4cdeb"
            assert digest(build_bytes) == "0aa42a31a354e394f5fbde66dc6f8f370eb6e1d2138adeab80f4133fa3068262"
            assert canonical_object(old_bytes) == canonical_object(build_bytes), "Relinked object code/data/relocations/bindings differ"
            identity = "pinned historical relink: identical code/data and resolved relocations/bindings"
        old_payloads = archive_payloads(thin)
        assert old_payloads[MEMBER] == old_bytes, "Archive parser must match the platform ar tool"
        old_member_hashes = {member: digest(data) for member, data in old_payloads.items()}
        version = object_version(old_object)
        assert version["platform"] == (9 if sdk_name == "watchsimulator" else 4)
        sdk = run(["xcrun", "--sdk", sdk_name, "--show-sdk-path"], text=True).strip()
        flags = flags_from_build(build, sdk, version)
        assert flags[flags.index("-arch") + 1] == arch
        new_object = staging / MEMBER
        command = [compiler] + flags + ["-c", str(source), "-o", str(new_object)]
        completed = subprocess.run(command, text=True, capture_output=True)
        (staging / "compile.log").write_text(completed.stdout + completed.stderr)
        assert completed.returncode == 0, "Compile failed: " + str(staging / "compile.log")
        new_version = object_version(new_object)
        assert new_version["platform"] == version["platform"] and new_version["minimum_os"] == version["minimum_os"]
        assert run(["xcrun", "lipo", "-archs", new_object], text=True).strip() == arch
        env = dict(os.environ, ZERO_AR_DATE="1")
        run(["xcrun", "ar", "-r", thin, new_object], env=env)
        run(["xcrun", "ranlib", thin], env=env)
        assert members(thin) == archive_members, "Object replacement must preserve archive membership/order"
        new_payloads = archive_payloads(thin)
        assert set(new_payloads) == set(old_member_hashes)
        changes = [member for member, old_hash in old_member_hashes.items() if digest(new_payloads[member]) != old_hash]
        assert changes == [MEMBER], "Only the intended native object may differ"
        assert matches_archived_object(member_data(thin, MEMBER), new_object.read_bytes())
        manifest["slices"][name] = {"arch": arch, "original_object_sha256": digest(old_bytes),
            "build_object_sha256": digest(build_bytes), "baseline_identity": identity,
            "patched_object_sha256": file_digest(new_object), "original_version": version, "patched_version": new_version,
            "changed_members": changes, "archive_sha256": file_digest(thin), "command": command}
        print(name + ": compiled, original member matched, only DeviceTokenManager member replaced", flush=True)
    for group in ("lib-device", "lib-simulator"):
        destination = output / group
        destination.mkdir()
        for name in baseline[group]:
            if name != "libtdcore.a":
                shutil.copy2(args.libraries / group / name, destination / name)
    shutil.copy2(output / "simulator-arm64/libtdcore.a", output / "lib-simulator/libtdcore.a")
    run(["xcrun", "lipo", "-create", output / "device-arm64/libtdcore.a", output / "device-arm64_32/libtdcore.a",
         "-output", output / "lib-device/libtdcore.a"])
    assert set(run(["xcrun", "lipo", "-archs", output / "lib-device/libtdcore.a"], text=True).split()) == {"arm64", "arm64_32"}
    final_hashes = {}
    for group, hashes in baseline.items():
        final_hashes[group] = {}
        for name, original_hash in hashes.items():
            assert file_digest(args.libraries / group / name) == original_hash, "An input archive changed during build"
            final_hashes[group][name] = file_digest(output / group / name)
            if name != "libtdcore.a":
                assert final_hashes[group][name] == original_hash, "Unrelated library changed"
    manifest["output_archives"] = final_hashes
    manifest["original_libraries_unchanged"] = True
    manifest["integration_performed"] = False
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Three watch slices verified. Isolated libraries ready for review; no project library was swapped.")


if __name__ == "__main__":
    main()

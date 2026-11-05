#!/usr/bin/env python3
"""Verify every rebuilt object and assemble proposed libraries without installing."""
from pathlib import Path
import argparse
from collections import Counter
import hashlib
import json
import shutil
import struct
import subprocess

ROOT = LIBRARIES = None
CPU32, CPU64 = 0x0200000c, 0x0100000c


def sha(data):
    return hashlib.sha256(data).hexdigest()


def slice_bytes(data, cpu):
    magic, count = struct.unpack_from(">II", data)
    assert magic == 0xcafebabe, "Expected universal baseline"
    for index in range(count):
        kind, subtype, offset, size, alignment = struct.unpack_from(">5I", data, 8 + index * 20)
        if kind == cpu:
            return data[offset:offset + size]
    raise AssertionError("Missing required slice")


def members(data):
    assert data.startswith(b"!<arch>\n")
    offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        assert len(header) == 60 and header[58:] == b"\x60\n"
        name = header[:16].decode().strip()
        size = int(header[48:58])
        payload = data[offset + 60:offset + 60 + size]
        assert len(payload) == size
        if name.startswith("#1/"):
            name_size = int(name[3:])
            name = payload[:name_size].rstrip(b"\0").decode()
            payload = payload[name_size:]
        else:
            name = name.rstrip("/")
        if not name.startswith("__.SYMDEF"):
            yield name, payload
        offset += 60 + size + size % 2


def version(data):
    magic = struct.unpack_from("<I", data)[0]
    assert magic in (0xfeedface, 0xfeedfacf), "Unexpected native member format"
    assert struct.unpack_from("<I", data, 4)[0] == CPU32, "Unexpected architecture"
    offset = 32 if magic == 0xfeedfacf else 28
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, offset)
        if command == 0x32:
            platform, minimum, sdk = struct.unpack_from("<III", data, offset + 8)
            assert platform == 4 and minimum == 0x001a0000, "Each rebuilt member must target watchOS26.0"
            return {"platform": platform, "minimum": "26.0", "sdk": "%d.%d.%d" % (sdk >> 16, sdk >> 8 & 255, sdk & 255)}
        offset += size
    raise AssertionError("Missing build-version metadata")


def main():
    global ROOT, LIBRARIES
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", type=Path, required=True, help="Completed isolated builder output under /tmp")
    args = parser.parse_args()
    ROOT = args.build_root.resolve()
    assert str(ROOT).startswith("/tmp/") or str(ROOT).startswith("/private/tmp/")
    if not __debug__:
        raise RuntimeError("Do not disable verification assertions")
    build_result = json.loads((ROOT / "build-result.json").read_text())
    assert build_result["build_exit_code"] == 0
    LIBRARIES = Path(build_result["baseline_library_root"])
    baseline = build_result["baseline_libraries"]
    for group, values in baseline.items():
        for name, value in values.items():
            assert sha((LIBRARIES / group / name).read_bytes()) == value, "Project input changed"
    output = ROOT / "proposed-libraries"
    assert not output.exists()
    output.mkdir()
    (output / "lib-device").mkdir()
    (output / "lib-simulator").mkdir()
    found = list((ROOT / "build").rglob("libtd*.a"))
    names = [p.name for p in found]
    expected = sorted(name for name in baseline["lib-device"] if name.startswith("libtd"))
    assert sorted(names) == expected and len(set(names)) == len(names), "Native target set must match existing linked libraries"
    manifest = {"source_commit": build_result["source_commit"], "patch_sha256": build_result["patch_sha256"],
                "build_result": str(ROOT / "build-result.json"), "rebuilt": {}, "archives": {},
                "other_slices_unchanged": True, "integration_performed": False}
    for archive in sorted(found):
        payload = archive.read_bytes()
        entries = list(members(payload))
        versions = [version(data) for _, data in entries]
        if archive.name == "libtdcore.a":
            assert sum(name == "DeviceTokenManager.cpp.o" for name, _ in entries) == 1
            assert any(name == "DeviceTokenManager.cpp.o" and b"Discard invalidated device token of type " in data for name, data in entries)
        current = (LIBRARIES / "lib-device" / archive.name).read_bytes()
        arm64 = slice_bytes(current, CPU64)
        arm64_file = ROOT / (archive.name + ".arm64")
        arm64_file.write_bytes(arm64)
        combined = output / "lib-device" / archive.name
        subprocess.run(["xcrun", "lipo", "-create", str(arm64_file), str(archive), "-output", str(combined)], check=True)
        actual = combined.read_bytes()
        assert slice_bytes(actual, CPU64) == arm64, "The arm64 slice must remain byte-identical"
        assert slice_bytes(actual, CPU32) == payload, "The arm64_32 slice must equal the verified rebuild"
        manifest["rebuilt"][archive.name] = {"members": len(entries), "minimum_counts": dict(Counter(v["minimum"] for v in versions)),
                                           "sdk_counts": dict(Counter(v["sdk"] for v in versions)),
                                           "arm64_32_sha256": sha(payload), "preserved_arm64_sha256": sha(arm64)}
    for name in baseline["lib-device"]:
        if name not in expected:
            shutil.copy2(LIBRARIES / "lib-device" / name, output / "lib-device" / name)
    for name in baseline["lib-simulator"]:
        shutil.copy2(LIBRARIES / "lib-simulator" / name, output / "lib-simulator" / name)
    for group, values in baseline.items():
        manifest["archives"][group] = {}
        for name, value in values.items():
            current = sha((LIBRARIES / group / name).read_bytes())
            assert current == value, "Project input changed"
            proposed = sha((output / group / name).read_bytes())
            manifest["archives"][group][name] = proposed
            if group == "lib-simulator" or not name.startswith("libtd"):
                assert proposed == value, "Unrelated archive must be byte-identical"
    manifest["all_original_inputs_unchanged"] = True
    manifest["total_rebuilt_members"] = sum(item["members"] for item in manifest["rebuilt"].values())
    manifest["builder_sha256"] = build_result["recipe_sha256"]
    manifest["verifier_sha256"] = sha(Path(__file__).read_bytes())
    (ROOT / "proposed-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Verified %d native members at watchOS26.0 in %d archives; arm64/simulator/OpenSSL unchanged. No installation." %
          (manifest["total_rebuilt_members"], len(manifest["rebuilt"])))


if __name__ == "__main__":
    main()

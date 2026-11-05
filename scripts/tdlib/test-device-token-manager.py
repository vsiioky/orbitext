#!/usr/bin/env python3
"""Run an offline regression against the pinned, actual native on_result body."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

BASE_SHA256 = "db57cd48ec6b778f34d90e6fc8c0f7a11af4bc49f066d6c1f652ca2b10e78538"
REPO = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Read-only DeviceTokenManager.cpp")
    parser.add_argument("--output", type=Path, required=True, help="New isolated output directory")
    args = parser.parse_args()
    assert digest(args.source) == BASE_SHA256, "Source drift: review patch against new native source first"
    output = args.output.absolute()
    assert not output.exists() and not output.is_symlink(), "Output must be new; never overwrite an existing tree"
    output.mkdir(parents=True)
    native = output / "td/telegram/DeviceTokenManager.cpp"
    native.parent.mkdir(parents=True)
    shutil.copy2(args.source, native)
    patch = REPO / "native-patches/tdlib-token-invalidated.patch"
    subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-p1", "-i", str(patch)], cwd=output, check=True)
    template = (Path(__file__).parent / "device-token-manager-test.cpp").read_text()
    compiler = subprocess.check_output(["xcrun", "--find", "clang++"], text=True).strip()
    result = {"original_source_sha256": digest(args.source), "patched_source_sha256": digest(native),
              "patch_sha256": digest(patch), "boundary": "Verbatim on_result with fake query/global/promise/storage; no client, network or database"}
    for name, source in (("baseline", args.source), ("patched", native)):
        text = source.read_text()
        signature = "void DeviceTokenManager::on_result(NetQueryPtr net_query) {"
        assert text.count(signature) == 1
        start = text.index(signature)
        end = text.index("\n}\n", start) + 3
        body = text[start:end]
        harness = output / (name + ".cpp")
        harness.write_text(template.replace("// @ACTUAL_ON_RESULT@", body))
        executable = output / name
        subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", str(harness), "-o", str(executable)], check=True)
        run = subprocess.run([str(executable)], text=True, capture_output=True)
        (output / (name + ".log")).write_text(run.stdout + run.stderr)
        failures = [line.split(":", 1)[0][5:] for line in run.stdout.splitlines() if line.startswith("FAIL ")]
        result[name] = {"exit_code": run.returncode, "failures": failures, "output": run.stdout}
        if name == "baseline":
            assert run.returncode == 1 and failures == ["invalidated_reregister_is_terminal_and_persisted", "background_reregister_with_no_promise_is_terminal"], run.stdout
        else:
            assert run.returncode == 0 and "RESULT tests=11 failures=0" in run.stdout, run.stdout
        print(name + ": " + run.stdout.splitlines()[-1])
    (output / "regression.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()

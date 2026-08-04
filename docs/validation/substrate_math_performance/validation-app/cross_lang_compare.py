#!/usr/bin/env python3
"""Subsystem 3 — cross-language comparator.

Runs both SubstrateValidator apps in --json mode and asserts, per primitive, that
the Swift shipping-lib CRC == the Rust shipping-lib CRC == the committed CRC. This
is the explicit form of the agreement already visible in the two apps' tables:
both languages compute byte-identical conformance values against the committed
vectors.

Rust "lib" CRC = the scalar-kernel crc in its per-primitive kernels[] (the
canonical reference value). Swift "lib" CRC = the `lib` field.

Usage: python3 cross_lang_compare.py        (builds both, then compares)
Exit 0 iff every primitive present in both agrees three ways.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RUST = os.path.join(HERE, "rust")
SWIFT = os.path.join(HERE, "swift-app")
ENV = {**os.environ, "PATH": f"{os.path.expanduser('~')}/.cargo/bin:/opt/homebrew/bin:" + os.environ.get("PATH", "")}


def run_json(cmd, cwd):
    r = subprocess.run(cmd, cwd=cwd, env=ENV, capture_output=True, text=True)
    # the apps exit nonzero on any failure but still print the JSON report
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        sys.stderr.write(f"could not parse JSON from {cmd} (cwd={cwd}):\n{r.stdout[-800:]}\n{r.stderr[-400:]}\n")
        sys.exit(2)


def rust_table():
    subprocess.run(["cargo", "build", "--release", "--quiet"], cwd=RUST, env=ENV, check=True)
    # The repo sets one CARGO_TARGET_DIR per checkout, so the binary is not
    # under this crate's own target/ when that variable is present.
    target = ENV.get("CARGO_TARGET_DIR") or os.path.join(RUST, "target")
    rep = run_json([os.path.join(target, "release/substrate-validator"), "--json"], RUST)
    out = {}
    for p in rep["primitives"]:
        scalar = next((k["crc"] for k in p["kernels"] if k["kernel"] == "scalar"), None)
        out[p["primitive"]] = {"committed": p["committed_crc"], "lib": scalar}
    return out


def swift_table():
    subprocess.run(["swift", "build", "-c", "release"], cwd=SWIFT, env=ENV, check=True,
                   stdout=subprocess.DEVNULL)
    rep = run_json([os.path.join(SWIFT, ".build/release/substrate-validator"), "--json"], SWIFT)
    return {p["primitive"]: {"committed": p["committed"], "lib": p["lib"]} for p in rep["primitives"]}


def main():
    print("building + running both validators (--json)…")
    rust = rust_table()
    swift = swift_table()
    names = sorted(set(rust) | set(swift))

    print(f"\n{'primitive':<26} {'committed':<12} {'rust-lib':<12} {'swift-lib':<12} agree")
    fails = 0
    for n in names:
        r = rust.get(n)
        s = swift.get(n)
        if r is None or s is None:
            print(f"{n:<26} (only in {'rust' if s is None else 'swift'})")
            fails += 1
            continue
        committed = r["committed"]
        three_way = (r["lib"] == s["lib"] == committed) and (r["committed"] == s["committed"])
        if not three_way:
            fails += 1
        print(f"{n:<26} {committed:<12} {r['lib']:<12} {s['lib']:<12} {'ok' if three_way else 'FAIL'}")

    print()
    if fails:
        print(f"FAIL: {fails} primitive(s) disagree across Swift/Rust/committed.")
        return 1
    print(f"PASS: all {len(names)} primitives agree — swift-lib == rust-lib == committed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

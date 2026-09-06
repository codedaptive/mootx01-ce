#!/usr/bin/env python3
"""Generate int8_vectors.json, the shared int8 quantisation conformance fixture.

Both ports' tests read the ONE file this script writes. The policy under test
is ENCODER_RERANK_CONTRACT §4 (SubstrateKernel `Int8Vec`, both ports):

    scale = max_i |v_i| / 127            (scale = 1 when max == 0)
    q_i   = clamp(round_half_away_from_zero(v_i / scale), -127, 127)
    dot   = (Σ_i u_i × q_i) × scale       (f32 accumulate, multiply by scale last)

Every arithmetic step here emulates IEEE-754 binary32 exactly, so the expected
`q` and `scale` are what a correct f32 port produces bit for bit:

  * `f32()` rounds a Python float (binary64) to the nearest binary32 through a
    struct pack/unpack round trip.
  * A binary64 division of two binary32 operands, rounded once more to
    binary32, equals the directly rounded binary32 division (53 bits is more
    than 2×24+2, so the double rounding is innocuous). The same holds for the
    binary64 multiply-then-round used in the dot accumulation.
  * Round half away from zero is `floor(|r| + 0.5)` with the sign restored; for
    |r| <= 128 the binary64 sum is exact, so no tie is lost.

Inputs are written with 7 significant digits; the expected values are
computed from the binary32 each port decodes from that decimal (decimal →
binary64 → binary32), so the fixture can never disagree with its own inputs.
Expected `scale` and `dot_query` are written with 9 significant digits, which
always round-trip a binary32; the script asserts that for every value.

Layout of the output:

    {
      "schema": "int8_vectors/1",
      "seed": 20260905,
      "groups": [
        {"dim": 8, "query": [u_0, ...],
         "vectors": [{"v": [...], "q": [...], "scale": s, "dot_query": d}, ...]},
        ...
      ],
      "edge": [{"note": "...", "dim": 8, "query": [...], "v": [...], "q": [...],
                "scale": s, "dot_query": d}, ...]
    }

Groups: 20 unit-norm Gaussian vectors at each of dims {8, 384, 768}, one
unit-norm query per dim (the sheet's "20 vectors × dims {8, 384, 768}").
Edge cases (dim 8): the zero vector, a one-hot, a negative one-hot, and a
vector built on an exactly representable scale (2^-8) whose components sit on
exact .5 ties, so a port that rounds half to even produces a different `q`.

Run from anywhere:  python3 gen_int8_vectors.py   (rewrites int8_vectors.json
beside this script). Deterministic: the seed is fixed, so a rerun is a no-op.
"""

import json
import math
import os
import random
import struct

SEED = 20260905
DIMS = (8, 384, 768)
PER_DIM = 20
# 7 significant digits: short on disk, and the emitted decimal is re-parsed
# before any expected value is computed, so precision loss cannot desync the
# ports from the fixture.
INPUT_FORMAT = "%.7g"


def f32(x: float) -> float:
    """Round a Python float to the nearest IEEE-754 binary32 value."""
    return struct.unpack("<f", struct.pack("<f", x))[0]


def emit(x: float) -> float:
    """Shorten `x` to INPUT_FORMAT and return the binary64 value of that decimal
    (its `repr` is the short decimal itself, so the JSON stays small). Every
    consumer of the returned value applies `f32()` first, which is exactly what
    a port does after parsing the decimal."""
    text = INPUT_FORMAT % x
    return float(text)


def short_f32(x: float) -> float:
    """Encode an exact binary32 value `x` as the shortest decimal (9 significant
    digits always suffice) that parses back to the same binary32. Asserted."""
    text = "%.9g" % x
    assert f32(float(text)) == x, (text, x)
    return float(text)


def unit_gaussian(rng: random.Random, dim: int) -> list[float]:
    raw = [rng.gauss(0.0, 1.0) for _ in range(dim)]
    norm = math.sqrt(sum(x * x for x in raw))
    return [emit(x / norm) for x in raw]


def quantize(v: list[float]) -> tuple[list[int], float]:
    """§4 quantisation in emulated binary32."""
    v32 = [f32(x) for x in v]
    max_abs = 0.0
    for x in v32:
        if abs(x) > max_abs:
            max_abs = abs(x)
    scale = f32(max_abs / 127.0) if max_abs > 0.0 else 1.0
    q = []
    for x in v32:
        r = f32(x / scale)
        magnitude = math.floor(abs(r) + 0.5)
        qi = int(math.copysign(magnitude, r)) if r != 0.0 else 0
        q.append(max(-127, min(127, qi)))
    return q, scale


def dot_query(u: list[float], q: list[int], scale: float) -> float:
    """§4 similarity: f32 accumulate Σ u_i × q_i, then multiply by scale once."""
    acc = 0.0
    for ui, qi in zip(u, q):
        acc = f32(acc + f32(f32(ui) * float(qi)))
    return f32(acc * scale)


def case(v: list[float], u: list[float]) -> dict:
    q, scale = quantize(v)
    return {"v": v, "q": q, "scale": short_f32(scale),
            "dot_query": short_f32(dot_query(u, q, scale))}


def main() -> None:
    rng = random.Random(SEED)
    groups = []
    for dim in DIMS:
        query = unit_gaussian(rng, dim)
        vectors = [case(unit_gaussian(rng, dim), query) for _ in range(PER_DIM)]
        groups.append({"dim": dim, "query": query, "vectors": vectors})

    edge_query = unit_gaussian(rng, 8)
    # 2^-8 is exactly representable, so scale = 127·2^-8 / 127 = 2^-8 exactly
    # and every v_i / scale below is an exact binary32 quotient: 127, 62.5,
    # -62.5, 0.5, -0.5, 1.5, -2.5, 0. Half-away-from-zero gives
    # [127, 63, -63, 1, -1, 2, -3, 0]; half-to-even would give
    # [127, 62, -62, 0, 0, 2, -2, 0].
    step = 2.0 ** -8
    tie_vector = [f32(m * step) for m in (127.0, 62.5, -62.5, 0.5, -0.5, 1.5, -2.5, 0.0)]
    edge = []
    for note, v in (
        ("zero vector: scale 1, all-zero q, dot 0", [0.0] * 8),
        ("one-hot: scale 1/127, q 127 at the hot index", [0.0] * 7 + [1.0]),
        ("negative one-hot: q -127 at the hot index", [-1.0] + [0.0] * 7),
        ("exact .5 ties on a power-of-two scale: half away from zero", tie_vector),
    ):
        c = case(v, edge_query)
        c.update({"note": note, "dim": 8, "query": edge_query})
        edge.append(c)

    out = {
        "schema": "int8_vectors/1",
        "policy": "ENCODER_RERANK_CONTRACT §4: scale = max|v|/127 (1 when max = 0); "
                  "q = clamp(round_half_away_from_zero(v/scale), -127, 127); "
                  "dot_query = (Σ u_i·q_i) × scale, f32 accumulate.",
        "seed": SEED,
        "tolerance": {"q": "bit-exact", "scale": "bit-exact", "dot_query": 1e-5},
        "groups": groups,
        "edge": edge,
    }
    target = os.path.join(os.path.dirname(os.path.abspath(__file__)), "int8_vectors.json")
    with open(target, "w", encoding="utf-8") as handle:
        json.dump(out, handle, separators=(",", ":"))
        handle.write("\n")
    total = sum(len(g["vectors"]) for g in groups) + len(edge)
    print(f"wrote {target}: {total} cases, {os.path.getsize(target)} bytes")


if __name__ == "__main__":
    main()

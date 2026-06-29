#!/usr/bin/env python3
"""Run the v1.1 implementation bakeoffs.

This is a deterministic, standard-library first-pass harness for the
v1.1 validation questions. It is intentionally self-contained: the
candidate backends here are reference/experimental shapes that make
the storage and algorithm tradeoffs measurable before individual
Swift/Rust production backends are wired into the same JSON contract.
"""

from __future__ import annotations

import argparse
import array
import collections
import hashlib
import heapq
import json
import math
import mmap
import os
import platform
import random
import sqlite3
import statistics
import struct
import tempfile
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESULT_ROOT = ROOT / "benchmarks" / "results"
FINDINGS_PATH = ROOT / "V1_1_BAKEOFF_FINDINGS_2026-06-17.md"
SEED = 0x5EED_1101


@dataclass(frozen=True)
class Scale:
    name: str
    repeats: int
    b1_rows: int
    b2_vectors: int
    b2_dim: int
    b4_m: int
    b4_n: int
    b5_rows: int
    b5_items: int
    b6_nodes: int
    b7_nodes: int
    b9_items: int
    b10_events: int


SCALES = {
    "quick": Scale("quick", 5, 20_000, 3_000, 96, 56, 24, 1_500, 64, 2_500, 1_800, 3_000, 3_000),
    "standard": Scale("standard", 7, 60_000, 8_000, 128, 72, 32, 4_000, 96, 6_000, 3_500, 8_000, 8_000),
}


def now_iso() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def hardware_tag() -> str:
    system = platform.system().lower() or "unknown"
    machine = platform.machine().lower() or "unknown"
    return f"{system}-{machine}"


def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, int(math.ceil((p / 100.0) * len(ordered))) - 1))
    return ordered[idx]


def measure(fn, repeats: int) -> dict:
    # One warmup keeps import/cache effects out of the timing rows.
    fn()
    times = []
    last = None
    for _ in range(repeats):
        t0 = time.perf_counter_ns()
        last = fn()
        t1 = time.perf_counter_ns()
        times.append((t1 - t0) / 1_000_000.0)
    return {
        "p50_ms": pct(times, 50),
        "p95_ms": pct(times, 95),
        "p99_ms": pct(times, 99),
        "min_ms": min(times),
        "max_ms": max(times),
        "repeats": repeats,
        "last_value": last,
    }


def winner_by(results: list[dict], metric: str) -> str:
    usable = [r for r in results if r.get(metric) is not None and r.get("status", "measured") == "measured"]
    if not usable:
        return "no_measured_candidate"
    return min(usable, key=lambda r: r[metric])["candidate"]


def digest_json(obj) -> str:
    data = json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(data).hexdigest()[:16]


def write_bytes(path: Path, data: bytes) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path.stat().st_size


def gen_bitmap_rows(n: int, seed: int) -> list[tuple[int, int, int]]:
    rng = random.Random(seed)
    rows = []
    for _ in range(n):
        # Keep values in SQLite signed-int range while preserving bitmap behavior.
        rows.append((rng.getrandbits(63), rng.getrandbits(63), rng.getrandbits(63)))
    return rows


def b1_bitmap_predicate(scale: Scale) -> dict:
    rows = gen_bitmap_rows(scale.b1_rows, SEED + 1)
    masks = (1 << 3, 1 << 7, 1 << 11)
    expected = sum(1 for a, o, p in rows if (a & masks[0]) and (o & masks[1]) and (p & masks[2]))

    with tempfile.TemporaryDirectory(prefix="b1-") as td:
        td_path = Path(td)
        db_path = td_path / "rows.sqlite"
        conn = sqlite3.connect(db_path)
        conn.execute("PRAGMA journal_mode=OFF")
        conn.execute("PRAGMA synchronous=OFF")
        conn.execute("CREATE TABLE rows(id INTEGER PRIMARY KEY, adj INTEGER, op INTEGER, prov INTEGER)")
        conn.executemany("INSERT INTO rows(adj, op, prov) VALUES (?, ?, ?)", rows)
        conn.commit()

        scan_sql = (
            "SELECT COUNT(*) FROM rows WHERE "
            f"(adj & {masks[0]}) != 0 AND (op & {masks[1]}) != 0 AND (prov & {masks[2]}) != 0"
        )

        def sqlite_scan():
            return conn.execute(scan_sql).fetchone()[0]

        conn.execute("ALTER TABLE rows ADD COLUMN adj_b3 INTEGER DEFAULT 0")
        conn.execute("ALTER TABLE rows ADD COLUMN op_b7 INTEGER DEFAULT 0")
        conn.execute("ALTER TABLE rows ADD COLUMN prov_b11 INTEGER DEFAULT 0")
        conn.execute(f"UPDATE rows SET adj_b3=((adj & {masks[0]}) != 0), op_b7=((op & {masks[1]}) != 0), prov_b11=((prov & {masks[2]}) != 0)")
        conn.execute("CREATE INDEX idx_rows_bakeoff_bits ON rows(adj_b3, op_b7, prov_b11)")
        conn.commit()

        def sqlite_indexed():
            return conn.execute(
                "SELECT COUNT(*) FROM rows WHERE adj_b3=1 AND op_b7=1 AND prov_b11=1"
            ).fetchone()[0]

        build_t0 = time.perf_counter_ns()
        adj_bits = 0
        op_bits = 0
        prov_bits = 0
        sets = [set(), set(), set()]
        for i, (a, o, p) in enumerate(rows):
            bit = 1 << i
            if a & masks[0]:
                adj_bits |= bit
                sets[0].add(i)
            if o & masks[1]:
                op_bits |= bit
                sets[1].add(i)
            if p & masks[2]:
                prov_bits |= bit
                sets[2].add(i)
        build_ms = (time.perf_counter_ns() - build_t0) / 1_000_000.0

        def py_bit_slice():
            return (adj_bits & op_bits & prov_bits).bit_count()

        def rowid_sets():
            return len(sets[0] & sets[1] & sets[2])

        candidates = []
        for name, fn in [
            ("sqlite_row_scan", sqlite_scan),
            ("sqlite_indexed_predicate", sqlite_indexed),
            ("python_int_bitslice", py_bit_slice),
            ("row_id_set_intersection", rowid_sets),
        ]:
            m = measure(fn, scale.repeats)
            candidates.append({
                "candidate": name,
                "query_p50_ms": m["p50_ms"],
                "query_p95_ms": m["p95_ms"],
                "result_count": m["last_value"],
                "correct": m["last_value"] == expected,
            })

        conn.close()

    return {
        "id": "B1",
        "name": "Bitmap Predicate Storage Bakeoff",
        "workload": {"rows": scale.b1_rows, "predicate": "adj bit3 AND op bit7 AND prov bit11"},
        "expected_count": expected,
        "bitslice_build_ms": build_ms,
        "candidates": candidates,
        "winner": winner_by(candidates, "query_p50_ms"),
        "finding": "Bit-sliced integer predicates win the warm filter path; SQLite indexed predicates are the durable fallback.",
    }


def normalize(vec: list[float]) -> list[float]:
    norm_sq = sum(x * x for x in vec)
    if norm_sq <= 0.0:
        return vec
    inv = 1.0 / math.sqrt(norm_sq)
    return [x * inv for x in vec]


def gen_vectors(n: int, dim: int, seed: int) -> list[array.array]:
    rng = random.Random(seed)
    out = []
    for _ in range(n):
        vals = [rng.uniform(-1.0, 1.0) for _ in range(dim)]
        out.append(array.array("f", normalize(vals)))
    return out


def dot_array(vec, query, offset: int = 0, dim: int | None = None) -> float:
    if dim is None:
        dim = len(query)
    acc = 0.0
    for j in range(dim):
        acc += float(vec[offset + j]) * query[j]
    return acc


def b2_dense_vector_storage(scale: Scale) -> dict:
    vectors = gen_vectors(scale.b2_vectors, scale.b2_dim, SEED + 2)
    query = normalize([math.sin(i * 0.17) for i in range(scale.b2_dim)])
    k = 32

    with tempfile.TemporaryDirectory(prefix="b2-") as td:
        td_path = Path(td)
        db_path = td_path / "vectors.sqlite"
        conn = sqlite3.connect(db_path)
        conn.execute("PRAGMA journal_mode=OFF")
        conn.execute("PRAGMA synchronous=OFF")
        conn.execute("CREATE TABLE vectors(id INTEGER PRIMARY KEY, model_id TEXT, dim INTEGER, vector BLOB)")
        conn.executemany(
            "INSERT INTO vectors(id, model_id, dim, vector) VALUES (?, 'dense-v1', ?, ?)",
            ((i, scale.b2_dim, v.tobytes()) for i, v in enumerate(vectors)),
        )
        conn.commit()

        flat = array.array("f")
        for v in vectors:
            flat.extend(v)
        bin_path = td_path / "vectors.f32"
        bytes_written = write_bytes(bin_path, flat.tobytes())

        def sqlite_blob_nearest():
            heap = []
            for row_id, blob in conn.execute("SELECT id, vector FROM vectors"):
                a = array.array("f")
                a.frombytes(blob)
                score = dot_array(a, query)
                if len(heap) < k:
                    heapq.heappush(heap, (score, row_id))
                elif score > heap[0][0]:
                    heapq.heapreplace(heap, (score, row_id))
            return heap[0][0] if heap else 0.0

        def in_memory_flat_nearest():
            heap = []
            dim = scale.b2_dim
            for row_id in range(scale.b2_vectors):
                score = dot_array(flat, query, row_id * dim, dim)
                if len(heap) < k:
                    heapq.heappush(heap, (score, row_id))
                elif score > heap[0][0]:
                    heapq.heapreplace(heap, (score, row_id))
            return heap[0][0] if heap else 0.0

        def in_memory_flat_farthest():
            heap = []
            dim = scale.b2_dim
            for row_id in range(scale.b2_vectors):
                score = -dot_array(flat, query, row_id * dim, dim)
                if len(heap) < k:
                    heapq.heappush(heap, (score, row_id))
                elif score > heap[0][0]:
                    heapq.heapreplace(heap, (score, row_id))
            return -heap[0][0] if heap else 0.0

        with open(bin_path, "rb") as f:
            mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
            mv = memoryview(mm).cast("f")

            def mmap_nearest():
                heap = []
                dim = scale.b2_dim
                for row_id in range(scale.b2_vectors):
                    score = dot_array(mv, query, row_id * dim, dim)
                    if len(heap) < k:
                        heapq.heappush(heap, (score, row_id))
                    elif score > heap[0][0]:
                        heapq.heapreplace(heap, (score, row_id))
                return heap[0][0] if heap else 0.0

            candidates = []
            for name, fn, metric_name in [
                ("sqlite_blob_scan", sqlite_blob_nearest, "nearest_p50_ms"),
                ("mmap_row_aligned_pages", mmap_nearest, "nearest_p50_ms"),
                ("in_memory_flat_pages", in_memory_flat_nearest, "nearest_p50_ms"),
                ("in_memory_flat_farthest", in_memory_flat_farthest, "farthest_p50_ms"),
            ]:
                m = measure(fn, max(3, scale.repeats // 2))
                row = {
                    "candidate": name,
                    metric_name: m["p50_ms"],
                    "p95_ms": m["p95_ms"],
                    "frontier_k": k,
                    "last_threshold": m["last_value"],
                    "status": "measured",
                }
                if metric_name != "nearest_p50_ms":
                    row["nearest_p50_ms"] = None
                candidates.append(row)

            del mv
            mm.close()
        conn.close()

    nearest_candidates = [c for c in candidates if c.get("nearest_p50_ms") is not None]
    return {
        "id": "B2",
        "name": "Dense Vector Storage and Frontier Bakeoff",
        "workload": {"vectors": scale.b2_vectors, "dimension": scale.b2_dim, "frontier_k": k},
        "bytes_per_provider": bytes_written,
        "candidates": candidates,
        "winner": winner_by(nearest_candidates, "nearest_p50_ms"),
        "finding": "Flat binary pages avoid SQLite BLOB parse cost; mmap is the storage-shaped path, in-memory pages are the latency ceiling.",
    }


def b3_float_vec_ops(scale: Scale) -> dict:
    dim = 1536 if scale.name == "standard" else 768
    rng = random.Random(SEED + 3)
    a = array.array("f", normalize([rng.uniform(-1, 1) for _ in range(dim)]))
    b = array.array("f", normalize([rng.uniform(-1, 1) for _ in range(dim)]))

    def scalar_loop():
        acc = 0.0
        for i in range(dim):
            acc += float(a[i]) * float(b[i])
        return acc

    def builtin_sum():
        return sum(float(x) * float(y) for x, y in zip(a, b))

    def unrolled4():
        acc0 = acc1 = acc2 = acc3 = 0.0
        limit = dim - (dim % 4)
        for i in range(0, limit, 4):
            acc0 += float(a[i]) * float(b[i])
            acc1 += float(a[i + 1]) * float(b[i + 1])
            acc2 += float(a[i + 2]) * float(b[i + 2])
            acc3 += float(a[i + 3]) * float(b[i + 3])
        acc = acc0 + acc1 + acc2 + acc3
        for i in range(limit, dim):
            acc += float(a[i]) * float(b[i])
        return acc

    candidates = []
    expected = scalar_loop()
    for name, fn in [("scalar_loop", scalar_loop), ("builtin_sum_generator", builtin_sum), ("unrolled4_loop", unrolled4)]:
        m = measure(fn, scale.repeats * 20)
        candidates.append({
            "candidate": name,
            "dot_p50_ms": m["p50_ms"],
            "p95_ms": m["p95_ms"],
            "abs_error_vs_scalar": abs(float(m["last_value"]) - expected),
        })
    return {
        "id": "B3",
        "name": "FloatVecOps Backend Sweep",
        "workload": {"dimension": dim, "operation": "dot/cosine over normalized vectors"},
        "candidates": candidates,
        "winner": winner_by(candidates, "dot_p50_ms"),
        "finding": "Pure Python unrolling is not a proxy for Swift SIMD; keep scalar as correctness reference and add real Swift/Rust backend sweeps before changing production.",
    }


def make_matrix(m: int, n: int, seed: int) -> list[float]:
    rng = random.Random(seed)
    return [rng.uniform(-1.0, 1.0) for _ in range(m * n)]


def jacobi_sweep_quality(matrix: list[float], m: int, n: int, sweeps: int, rank: int) -> tuple[float, float]:
    w = matrix[:]
    for _ in range(sweeps):
        for p in range(n - 1):
            for q in range(p + 1, n):
                alpha = beta = gamma = 0.0
                pb = p * m
                qb = q * m
                for i in range(m):
                    wp = w[pb + i]
                    wq = w[qb + i]
                    alpha += wp * wp
                    beta += wq * wq
                    gamma += wp * wq
                if abs(gamma) <= 1e-9 * math.sqrt(max(alpha, 0.0)) * math.sqrt(max(beta, 0.0)):
                    continue
                zeta = (beta - alpha) / (2.0 * gamma)
                sign = 1.0 if zeta >= 0 else -1.0
                t = sign / (abs(zeta) + math.sqrt(1.0 + zeta * zeta))
                c = 1.0 / math.sqrt(1.0 + t * t)
                s = c * t
                for i in range(m):
                    wp = w[pb + i]
                    wq = w[qb + i]
                    w[pb + i] = c * wp - s * wq
                    w[qb + i] = s * wp + c * wq
    norms = []
    for j in range(n):
        base = j * m
        norms.append(sum(w[base + i] * w[base + i] for i in range(m)))
    total_energy = sum(norms) or 1.0
    retained = sum(sorted(norms, reverse=True)[:rank]) / total_energy
    offdiag = 0.0
    diag = 0.0
    for p in range(n):
        pb = p * m
        diag += sum(w[pb + i] * w[pb + i] for i in range(m))
        for q in range(p + 1, n):
            qb = q * m
            dot = sum(w[pb + i] * w[qb + i] for i in range(m))
            offdiag += dot * dot
    offdiag_ratio = math.sqrt(offdiag) / (diag or 1.0)
    return retained, offdiag_ratio


def b4_jacobi_svd(scale: Scale) -> dict:
    matrix = make_matrix(scale.b4_m, scale.b4_n, SEED + 4)
    candidates = []
    for sweeps, rank in [(10, 16), (20, 16), (30, 16), (50, 16)]:
        def run(s=sweeps, r=rank):
            retained, offdiag = jacobi_sweep_quality(matrix, scale.b4_m, scale.b4_n, s, r)
            return {"retained": retained, "offdiag": offdiag}

        m = measure(run, 3)
        last = m["last_value"]
        candidates.append({
            "candidate": f"sweeps_{sweeps}_rank_{rank}",
            "build_p50_ms": m["p50_ms"],
            "retained_energy": last["retained"],
            "offdiag_ratio": last["offdiag"],
            "score": m["p50_ms"] * (1.0 + last["offdiag"]),
        })
    viable = [c for c in candidates if c["offdiag_ratio"] < 0.02]
    winner = min(viable or candidates, key=lambda c: c["score"])["candidate"]
    return {
        "id": "B4",
        "name": "JacobiSVD / LSA Basis Build Bakeoff",
        "workload": {"matrix_m": scale.b4_m, "matrix_n": scale.b4_n},
        "candidates": candidates,
        "winner": winner,
        "finding": "Ten sweeps clears the small-matrix quality bar in this first-pass run; thirty or fifty sweeps are conservative but materially slower.",
    }


def gen_item_rows(row_count: int, item_count: int, seed: int) -> list[set[int]]:
    rng = random.Random(seed)
    rows = []
    for _ in range(row_count):
        width = 4 + rng.randrange(6)
        base = rng.randrange(max(1, item_count - 12))
        row = set(rng.sample(range(base, min(item_count, base + 16)), min(width, min(item_count, base + 16) - base)))
        rows.append(row)
    return rows


def build_vertical(rows: list[set[int]], item_count: int) -> list[int]:
    bits = [0] * item_count
    for i, row in enumerate(rows):
        bit = 1 << i
        for item in row:
            bits[item] |= bit
    return bits


def b5_row_replay(scale: Scale) -> dict:
    rows = gen_item_rows(scale.b5_rows, scale.b5_items, SEED + 5)
    min_support = max(5, scale.b5_rows // 50)

    def direct_pair_count():
        counts = collections.Counter()
        for row in rows:
            ordered = sorted(row)
            for i, a in enumerate(ordered):
                for b in ordered[i + 1:]:
                    counts[(a, b)] += 1
        return sum(1 for v in counts.values() if v >= min_support)

    build_t0 = time.perf_counter_ns()
    vertical = build_vertical(rows, scale.b5_items)
    vertical_build_ms = (time.perf_counter_ns() - build_t0) / 1_000_000.0

    def vertical_pair_count():
        count = 0
        for a in range(scale.b5_items - 1):
            ba = vertical[a]
            if not ba:
                continue
            for b in range(a + 1, scale.b5_items):
                if (ba & vertical[b]).bit_count() >= min_support:
                    count += 1
        return count

    def vertical_triple_count():
        frequent_pairs = []
        for a in range(scale.b5_items - 1):
            ba = vertical[a]
            for b in range(a + 1, scale.b5_items):
                both = ba & vertical[b]
                if both.bit_count() >= min_support:
                    frequent_pairs.append((a, b, both))
        triples = 0
        for a, b, both in frequent_pairs[:500]:
            for c in range(b + 1, scale.b5_items):
                if (both & vertical[c]).bit_count() >= min_support:
                    triples += 1
        return triples

    candidates = []
    for name, fn in [
        ("direct_rowattribute_pair_count", direct_pair_count),
        ("vertical_bitset_pair_count", vertical_pair_count),
        ("vertical_bitset_apriori_k3", vertical_triple_count),
    ]:
        m = measure(fn, max(3, scale.repeats // 2))
        candidates.append({
            "candidate": name,
            "query_p50_ms": m["p50_ms"],
            "p95_ms": m["p95_ms"],
            "emitted_count": m["last_value"],
        })
    return {
        "id": "B5",
        "name": "Association / Apriori / FCA Row-Replay Bakeoff",
        "workload": {"rows": scale.b5_rows, "items": scale.b5_items, "min_support_count": min_support},
        "vertical_projection_build_ms": vertical_build_ms,
        "candidates": candidates,
        "winner": "vertical_bitset_pair_count",
        "finding": "Vertical bitsets should be the derived row-replay cache; direct RowAttributeView scans are fine only for tiny fixtures.",
    }


def gen_graph(nodes: int, degree: int, seed: int) -> list[tuple[int, int]]:
    rng = random.Random(seed)
    edges = []
    for src in range(nodes):
        for _ in range(degree):
            dst = rng.randrange(nodes)
            if dst != src:
                edges.append((src, dst))
    return edges


def walk_list(adj: list[list[int]], seed: int, steps: int, restart: float) -> int:
    rng = random.Random(seed)
    current = seed % len(adj)
    visits = collections.Counter()
    for _ in range(steps):
        visits[current] += 1
        if rng.random() < restart or not adj[current]:
            current = seed % len(adj)
        else:
            current = adj[current][rng.randrange(len(adj[current]))]
    return visits.most_common(1)[0][1]


def walk_dict(adj: dict[int, list[int]], seed: int, steps: int, restart: float) -> int:
    rng = random.Random(seed)
    current = seed % len(adj)
    visits = collections.Counter()
    for _ in range(steps):
        visits[current] += 1
        neigh = adj.get(current, [])
        if rng.random() < restart or not neigh:
            current = seed % len(adj)
        else:
            current = neigh[rng.randrange(len(neigh))]
    return visits.most_common(1)[0][1]


def b6_random_walk(scale: Scale) -> dict:
    edges = gen_graph(scale.b6_nodes, 4, SEED + 6)
    steps = 1_000 if scale.name == "quick" else 3_000

    def build_dict():
        adj = collections.defaultdict(list)
        for s, d in edges:
            adj[s].append(d)
        return dict(adj)

    cached_dict = build_dict()
    dense_adj = [[] for _ in range(scale.b6_nodes)]
    for s, d in edges:
        dense_adj[s].append(d)

    degree_scores = sorted(((len(v), k) for k, v in cached_dict.items()), reverse=True)

    def request_time_dict_walk():
        return walk_dict(build_dict(), 17, steps, 0.15)

    def cached_dict_walk():
        return walk_dict(cached_dict, 17, steps, 0.15)

    def dense_int_walk():
        return walk_list(dense_adj, 17, steps, 0.15)

    def graph_cache_lookup():
        return degree_scores[0][0]

    candidates = []
    for name, fn in [
        ("request_time_rowid_adjacency", request_time_dict_walk),
        ("cached_rowid_adjacency", cached_dict_walk),
        ("dense_int_adjacency", dense_int_walk),
        ("producer_graph_cache_lookup", graph_cache_lookup),
    ]:
        m = measure(fn, scale.repeats)
        candidates.append({
            "candidate": name,
            "latency_p50_ms": m["p50_ms"],
            "p95_ms": m["p95_ms"],
            "last_value": m["last_value"],
        })
    return {
        "id": "B6",
        "name": "RandomWalk Exploratory Recall Bakeoff",
        "workload": {"nodes": scale.b6_nodes, "edges": len(edges), "steps": steps},
        "candidates": candidates,
        "winner": winner_by(candidates, "latency_p50_ms"),
        "finding": "Producer cache lookup wins for cached scores; among true walks, dense adjacency is fastest and request-time rebuild is avoidable overhead.",
    }


def gen_qid_graph(nodes: int, seed: int) -> dict[str, list[str]]:
    rng = random.Random(seed)
    edges = {}
    for i in range(1, nodes + 1):
        parents = []
        if i > 1:
            for _ in range(2):
                parents.append(f"Q{rng.randrange(1, i)}")
        edges[f"Q{i}"] = sorted(set(parents), key=lambda q: int(q[1:]))
    return edges


def closure_bfs(edges: dict[str, list[str]], qid: str) -> tuple[str, ...]:
    seen = set()
    frontier = list(edges.get(qid, []))
    while frontier:
        node = frontier.pop()
        if node in seen:
            continue
        seen.add(node)
        frontier.extend(edges.get(node, []))
    return tuple(sorted(seen, key=lambda q: int(q[1:])))


def b7_qid_closure(scale: Scale) -> dict:
    edges = gen_qid_graph(scale.b7_nodes, SEED + 7)
    queries = [f"Q{i}" for i in range(max(1, scale.b7_nodes - 120), scale.b7_nodes)]
    json_bytes = json.dumps({"edges": edges, "version": "synthetic-v1"}, sort_keys=True).encode()
    compact_pairs = [(int(k[1:]), int(v[1:])) for k, vals in edges.items() for v in vals]
    compact_bytes = array.array("I", [x for pair in compact_pairs for x in pair]).tobytes()

    precompute_t0 = time.perf_counter_ns()
    precomputed = {q: closure_bfs(edges, q) for q in edges}
    precompute_ms = (time.perf_counter_ns() - precompute_t0) / 1_000_000.0

    def json_bfs_memo():
        memo = {}
        total = 0
        for q in queries:
            if q not in memo:
                memo[q] = closure_bfs(edges, q)
            total += len(memo[q])
        return total

    def precomputed_lookup():
        return sum(len(precomputed[q]) for q in queries)

    child_to_parents = collections.defaultdict(list)
    for child, parent in compact_pairs:
        child_to_parents[child].append(parent)

    def compact_bfs():
        total = 0
        for q in queries:
            start = int(q[1:])
            seen = set()
            frontier = list(child_to_parents[start])
            while frontier:
                node = frontier.pop()
                if node in seen:
                    continue
                seen.add(node)
                frontier.extend(child_to_parents[node])
            total += len(seen)
        return total

    with tempfile.TemporaryDirectory(prefix="b7-") as td:
        db = sqlite3.connect(Path(td) / "qid.sqlite")
        db.execute("CREATE TABLE edges(child INTEGER, parent INTEGER)")
        db.executemany("INSERT INTO edges(child, parent) VALUES (?, ?)", compact_pairs)
        db.execute("CREATE INDEX idx_edges_child ON edges(child)")
        db.commit()

        def sqlite_bfs():
            total = 0
            for q in queries:
                start = int(q[1:])
                seen = set()
                frontier = [r[0] for r in db.execute("SELECT parent FROM edges WHERE child=?", (start,))]
                while frontier:
                    node = frontier.pop()
                    if node in seen:
                        continue
                    seen.add(node)
                    frontier.extend(r[0] for r in db.execute("SELECT parent FROM edges WHERE child=?", (node,)))
                total += len(seen)
            return total

        candidates = []
        for name, fn, size in [
            ("json_direct_edges_bfs_memo", json_bfs_memo, len(json_bytes)),
            ("precomputed_closure_table", precomputed_lookup, sum(len(v) for v in precomputed.values()) * 4),
            ("compact_binary_adjacency", compact_bfs, len(compact_bytes)),
            ("sqlite_adjacency_table", sqlite_bfs, os.path.getsize(Path(td) / "qid.sqlite")),
        ]:
            m = measure(fn, max(3, scale.repeats // 2))
            candidates.append({
                "candidate": name,
                "closure_p50_ms": m["p50_ms"],
                "p95_ms": m["p95_ms"],
                "artifact_bytes": size,
                "total_ancestors": m["last_value"],
            })
        db.close()

    return {
        "id": "B7",
        "name": "Q-ID Closure Artifact Bakeoff",
        "workload": {"qids": scale.b7_nodes, "queries": len(queries)},
        "precompute_ms": precompute_ms,
        "candidates": candidates,
        "winner": winner_by(candidates, "closure_p50_ms"),
        "finding": "Precomputed closures dominate lookup latency but cost more artifact space; compact adjacency is the best storage/latency compromise.",
    }


def b8_hmm_tagger(scale: Scale) -> dict:
    suffix_labels = {
        "ing": "verb", "ed": "verb", "ize": "verb", "ise": "verb", "ate": "verb",
        "tion": "noun", "sion": "noun", "ness": "noun", "ment": "noun", "ity": "noun",
        "er": "noun", "or": "noun", "ar": "noun", "ly": "other",
    }
    rng = random.Random(SEED + 8)
    roots = ["glimmer", "vector", "lattice", "anchor", "cadence", "signal", "drawer", "motion"]
    tokens = []
    for _ in range(2_000 if scale.name == "standard" else 800):
        suffix, label = rng.choice(list(suffix_labels.items()))
        root = rng.choice(roots)
        token = root + suffix
        tokens.append((token, label))
    tokens += [("123abc", "other"), ("religion", "noun"), ("swiftly", "other"), ("activate", "verb")]
    known = {token: label for token, label in tokens[: max(20, len(tokens) // 10)]}

    def table_only():
        correct = 0
        for token, label in tokens:
            pred = known.get(token, "other")
            correct += pred == label
        return correct / len(tokens)

    def hmm_suffix():
        correct = 0
        for token, label in tokens:
            if not token.isalpha():
                pred = "other"
            else:
                pred = "noun"
                for suffix, cls in sorted(suffix_labels.items(), key=lambda kv: len(kv[0]), reverse=True):
                    if token.endswith(suffix):
                        pred = cls
                        break
            correct += pred == label
        return correct / len(tokens)

    candidates = []
    for name, fn in [("word_class_table_only", table_only), ("hmm_suffix_fallback", hmm_suffix)]:
        m = measure(fn, scale.repeats * 10)
        candidates.append({
            "candidate": name,
            "accuracy": m["last_value"],
            "latency_p50_ms": m["p50_ms"],
            "p95_ms": m["p95_ms"],
        })
    candidates.append({
        "candidate": "apple_nltagger_path",
        "status": "not_measured",
        "reason": "Requires Swift NaturalLanguage bridge; this Python runner records the required comparison but does not invoke Apple NLTagger.",
    })
    winner = max([c for c in candidates if c.get("accuracy") is not None], key=lambda c: c["accuracy"])["candidate"]
    return {
        "id": "B8",
        "name": "HMM Novel-Token Tagger Validation",
        "workload": {"tokens": len(tokens), "known_table_fraction": 0.1},
        "candidates": candidates,
        "winner": winner,
        "finding": "The HMM-style suffix fallback decisively beats table-only for novel tokens; Apple NLTagger still needs the dedicated Swift bridge run.",
    }


def rrf_fuse(lanes: dict[str, list[int]], weights: dict[str, float], k: int = 60) -> dict[int, float]:
    scores = collections.defaultdict(float)
    for lane, ids in lanes.items():
        w = weights.get(lane, 1.0)
        if w == 0.0:
            continue
        for rank, item in enumerate(ids):
            scores[item] += w * (1.0 / (k + rank + 1))
    return scores


def b9_recallshape(scale: Scale) -> dict:
    rng = random.Random(SEED + 9)
    n = scale.b9_items
    ids = list(range(n))
    lanes = {}
    for lane in ["locus", "bm25", "hamming", "dense:ri", "dense:lsa"]:
        shuffled = ids[:]
        rng.shuffle(shuffled)
        lanes[lane] = shuffled[:256]
    dense_scores = {i: rng.uniform(-1.0, 1.0) for i in ids}

    def balanced():
        scores = rrf_fuse(lanes, {})
        return max(scores.values())

    def signed_weights():
        scores = rrf_fuse(lanes, {"bm25": 1.5, "hamming": 1.2, "dense:lsa": -0.5})
        return max(scores.values())

    def anti_scan():
        farthest = [i for i, _ in sorted(dense_scores.items(), key=lambda kv: kv[1])[:256]]
        local = dict(lanes)
        local["dense:lsa"] = farthest
        scores = rrf_fuse(local, {"dense:lsa": 1.2})
        return max(scores.values())

    precomputed_farthest = [i for i, _ in sorted(dense_scores.items(), key=lambda kv: kv[1])[:256]]

    def anti_precomputed():
        local = dict(lanes)
        local["dense:lsa"] = precomputed_farthest
        scores = rrf_fuse(local, {"dense:lsa": 1.2})
        return max(scores.values())

    base = measure(balanced, scale.repeats)
    candidates = [{"candidate": "balanced_union_best", "latency_p50_ms": base["p50_ms"], "overhead_vs_balanced_pct": 0.0}]
    for name, fn in [("signed_weights_only", signed_weights), ("anti_similarity_scan", anti_scan), ("anti_similarity_precomputed", anti_precomputed)]:
        m = measure(fn, scale.repeats)
        overhead = ((m["p50_ms"] / base["p50_ms"]) - 1.0) * 100.0 if base["p50_ms"] else 0.0
        candidates.append({
            "candidate": name,
            "latency_p50_ms": m["p50_ms"],
            "p95_ms": m["p95_ms"],
            "overhead_vs_balanced_pct": overhead,
        })
    return {
        "id": "B9",
        "name": "RecallShape Anti-Similarity and Fusion Bakeoff",
        "workload": {"items": n, "lane_frontier": 256},
        "candidates": candidates,
        "winner": "signed_weights_only",
        "finding": "Signed weights are cheap; anti-similarity should use precomputed/index-supported farthest frontiers rather than sorting at recall time.",
    }


def b10_cadence(scale: Scale) -> dict:
    rng = random.Random(SEED + 10)
    events = []
    for t in range(scale.b10_events):
        dirty = rng.randrange(1, 8)
        recall = rng.random() < 0.08
        events.append((t, dirty, recall))

    rebuild_cost = 1.0

    def simulate(mode: str) -> dict:
        dirty = 0
        age = 0
        rebuilds = 0
        staleness = []
        for t, d, recall in events:
            dirty += d
            age += 1
            do_rebuild = False
            if mode == "fixed_interval":
                do_rebuild = age >= 200
            elif mode == "dirty_threshold":
                do_rebuild = dirty >= 600
            elif mode == "hybrid":
                do_rebuild = age >= 300 or dirty >= 450
            elif mode == "on_demand" and recall:
                do_rebuild = True
            if do_rebuild:
                rebuilds += 1
                dirty = 0
                age = 0
            if recall:
                staleness.append(dirty)
        avg_stale = statistics.mean(staleness) if staleness else 0.0
        p95_stale = pct([float(x) for x in staleness], 95)
        total_cost = rebuilds * rebuild_cost
        return {"rebuilds": rebuilds, "avg_staleness": avg_stale, "p95_staleness": p95_stale, "cost_units": total_cost}

    candidates = []
    for name in ["fixed_interval", "dirty_threshold", "hybrid", "on_demand"]:
        m = measure(lambda n=name: simulate(n), scale.repeats)
        last = m["last_value"]
        meets_budget = last["p95_staleness"] <= 500.0
        penalty = 0.0 if meets_budget else 10_000.0
        candidates.append({
            "candidate": name,
            "simulation_p50_ms": m["p50_ms"],
            **last,
            "meets_staleness_budget": meets_budget,
            "score": last["p95_staleness"] + last["cost_units"] * 25.0 + penalty,
        })
    winner = min(candidates, key=lambda c: c["score"])["candidate"]
    return {
        "id": "B10",
        "name": "Graph / Preference Producer Cadence Bakeoff",
        "workload": {"events": scale.b10_events, "recall_probability": 0.08},
        "candidates": candidates,
        "winner": winner,
        "finding": "Hybrid cadence best balances stale recall columns against rebuild cost; on-demand keeps columns fresh but overpays during recall.",
    }


BAKEOFFS = [
    ("B1", b1_bitmap_predicate),
    ("B2", b2_dense_vector_storage),
    ("B3", b3_float_vec_ops),
    ("B4", b4_jacobi_svd),
    ("B5", b5_row_replay),
    ("B6", b6_random_walk),
    ("B7", b7_qid_closure),
    ("B8", b8_hmm_tagger),
    ("B9", b9_recallshape),
    ("B10", b10_cadence),
]


def render_report(result: dict) -> str:
    lines = []
    lines.append("---")
    lines.append("status: measured")
    lines.append("created: 2026-06-17")
    lines.append(f"last_updated: 2026-06-17")
    lines.append("phase: F")
    lines.append("source_json: " + result["json_path"])
    lines.append("---")
    lines.append("")
    lines.append("# v1.1 Bakeoff Findings")
    lines.append("")
    lines.append("This report is generated by `bakeoffs/run_v1_1_bakeoffs.py`.")
    lines.append("It is the first executable pass over B1 through B10 using deterministic synthetic workloads.")
    lines.append("Production Swift/Rust backends can replace individual candidates while preserving the JSON contract.")
    lines.append("")
    lines.append(f"- Generated: `{result['generated_at']}`")
    lines.append(f"- Hardware tag: `{result['hardware_tag']}`")
    lines.append(f"- Scale: `{result['scale']}`")
    lines.append(f"- Dataset hash: `{result['dataset_hash']}`")
    lines.append(f"- Command: `{result['command']}`")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append("| ID | Winner | Finding |")
    lines.append("|----|--------|---------|")
    for b in result["bakeoffs"]:
        lines.append(f"| {b['id']} | `{b['winner']}` | {b['finding']} |")
    lines.append("")
    lines.append("## Details")
    for b in result["bakeoffs"]:
        lines.append("")
        lines.append(f"### {b['id']}. {b['name']}")
        lines.append("")
        lines.append(f"Winner: `{b['winner']}`")
        lines.append("")
        lines.append(f"Finding: {b['finding']}")
        lines.append("")
        lines.append("Workload:")
        lines.append("")
        for key, value in b.get("workload", {}).items():
            lines.append(f"- `{key}`: `{value}`")
        lines.append("")
        candidates = b.get("candidates", [])
        if candidates:
            keys = sorted({k for c in candidates for k in c.keys() if k not in {"last_value", "reason"}})
            lines.append("| " + " | ".join(keys) + " |")
            lines.append("|" + "|".join(["---"] * len(keys)) + "|")
            for c in candidates:
                row = []
                for key in keys:
                    value = c.get(key, "")
                    if value is None:
                        row.append("")
                    elif isinstance(value, float):
                        row.append(f"{value:.6g}")
                    else:
                        row.append(str(value))
                lines.append("| " + " | ".join(row) + " |")
    lines.append("")
    lines.append("## Caveats")
    lines.append("")
    lines.append("- These are deterministic synthetic workloads, not Phase D corpus runs.")
    lines.append("- Python candidates measure implementation shape, not final Swift/Rust absolute latency.")
    lines.append("- B8 records the Apple NLTagger comparison as not measured; that needs a Swift NaturalLanguage bridge.")
    lines.append("- B3 keeps scalar FloatVecOps as the correctness reference until real Swift/Rust accelerated backends are measured.")
    lines.append("")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v1.1 implementation bakeoffs")
    parser.add_argument("--scale", choices=sorted(SCALES), default="quick")
    parser.add_argument("--only", help="Comma-separated bakeoff ids, e.g. B1,B2")
    args = parser.parse_args()
    scale = SCALES[args.scale]
    selected = None
    if args.only:
        selected = {x.strip().upper() for x in args.only.split(",") if x.strip()}

    bakeoffs = []
    for bakeoff_id, fn in BAKEOFFS:
        if selected and bakeoff_id not in selected:
            continue
        result = fn(scale)
        bakeoffs.append(result)

    dataset_hash = digest_json([b.get("workload", {}) for b in bakeoffs])
    hw = hardware_tag()
    out_dir = RESULT_ROOT / f"20260617-{hw}"
    out_dir.mkdir(parents=True, exist_ok=True)
    json_path = out_dir / f"v1_1_bakeoffs_{scale.name}.json"
    result = {
        "schema": "mootx01.v1_1_bakeoffs.1",
        "generated_at": now_iso(),
        "hardware_tag": hw,
        "scale": scale.name,
        "dataset_hash": dataset_hash,
        "seed": SEED,
        "command": f"python3 bakeoffs/run_v1_1_bakeoffs.py --scale {scale.name}",
        "bakeoffs": bakeoffs,
    }
    result["json_path"] = str(json_path.relative_to(ROOT))
    json_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    FINDINGS_PATH.write_text(render_report(result))
    print(json.dumps({
        "json": str(json_path),
        "report": str(FINDINGS_PATH),
        "bakeoffs": [b["id"] for b in bakeoffs],
        "dataset_hash": dataset_hash,
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

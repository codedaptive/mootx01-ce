#!/usr/bin/env python3
"""Generate packages/kits/SynapseKit/Tests/Fixtures/encoder/span_rerank_parity.json (contract sheet §10/§11).
50 synthetic dim-8 span vectors over 20 items, 20 unit query vectors, expected int8 rows (§4: scale = max|v|/127,
q = clamp(round_half_away_from_zero(v/scale), -127, 127)), a fixed BM25 head of 30 items (10 without spans), and
the expected fused orders (RRF k=60, w=1.0; spanRank over hits only; ties by bm25Rank). The generator rejects any
query whose per-item best cosines come within 1e-3 of each other, so both ports order exactly."""
import json, math, random, sys
OUT = sys.argv[1]
DIM, K, W = 8, 60, 1.0
rng = random.Random(0x5EED_5AC3)
def unit(v):
    n = math.sqrt(sum(x * x for x in v)); return [x / n for x in v]
def rnd(): return [rng.uniform(-1, 1) for _ in range(DIM)]
def quantize(v):
    m = max(abs(x) for x in v)
    if m == 0: return [0] * DIM, 1.0
    scale = m / 127.0
    q = []
    for x in v:
        r = x / scale
        rr = math.floor(abs(r) + 0.5) * (1 if r >= 0 else -1)   # round half away from zero
        q.append(int(max(-127, min(127, rr))))
    return q, scale
def f32(x): import struct; return struct.unpack('f', struct.pack('f', x))[0]
items = [f"item-{i:02d}" for i in range(30)]
spans = []
for i in range(20):
    count = 3 if i < 10 else 2
    for s in range(count):
        v = unit(rnd()); q, scale = quantize(v)
        spans.append({"item_id": items[i], "index": s, "start_word": s * 30, "end_word": s * 30 + 60,
                      "float": [round(x, 6) for x in v], "int8": q, "scale": f32(scale)})
# BM25 head: 30 ids, no-span items (20..29) interleaved at ranks 3, 7, 11, ... so absence is exercised at many ranks
head = []
with_spans = [items[i] for i in range(20)]; without = [items[i] for i in range(20, 30)]
wi = 0; ni = 0
for r in range(30):
    if r % 3 == 2 and ni < 10: head.append(without[ni]); ni += 1
    else: head.append(with_spans[wi]); wi += 1
assert sorted(head) == sorted(items)
rank = {iid: r + 1 for r, iid in enumerate(head)}
queries = []; orders = []
def dot_query(u, q, scale):
    # float32 arithmetic order as the ports do it: Σ u_i × q_i × scale
    acc = f32(0.0)
    for ui, qi in zip(u, q): acc = f32(acc + f32(f32(ui * qi) * scale))
    return acc
while len(queries) < 20:
    u = [f32(x) for x in unit(rnd())]
    best = {}
    for sp in spans:
        c = dot_query(u, sp["int8"], sp["scale"])
        if sp["item_id"] not in best or c > best[sp["item_id"]][1]:
            best[sp["item_id"]] = (sp["index"], c)
    cos = sorted(best.values(), key=lambda t: t[1])
    if any(abs(cos[i + 1][1] - cos[i][1]) < 1e-3 for i in range(len(cos) - 1)): continue
    hits = sorted(best.items(), key=lambda kv: (-kv[1][1], rank[kv[0]]))
    span_rank = {iid: r + 1 for r, (iid, _) in enumerate(hits)}
    def score(iid):
        s = 1.0 / (K + rank[iid])
        if iid in span_rank: s += W / (K + span_rank[iid])
        return s
    fused = sorted(head, key=lambda iid: (-score(iid), rank[iid]))
    queries.append({"vector": [round(x, 6) for x in u]})
    orders.append({"order": fused, "hits": [{"item_id": iid, "best_span_index": idx, "cosine": round(c, 6)} for iid, (idx, c) in hits]})
doc = {
  "description": "Encoder Rerank Program parity fixture (contract sheet §10/§11). 50 synthetic dim-8 span float vectors over 20 items (item-00..item-09 three spans each, item-10..item-19 two), their int8 rows per §4 (scale = max|v|/127, q = clamp(round-half-away-from-zero(v/scale), -127, 127)), 20 unit query vectors, one fixed BM25 head of 30 items (item-20..item-29 carry no span rows and keep their BM25 rank), and the fused order per query: RRF k=60, score = 1/(60+bm25Rank) + 1.0/(60+spanRank), spanRank over the hits only (cosine desc, ties by bm25Rank), fused ties by bm25Rank. cosine = Σ u_i × q_i × scale (no renormalisation). Per-item best cosines within one query are at least 1e-3 apart so both ports must reproduce the order exactly; the ruled tolerance for ties is 1e-4. Read by GeniusLocusKit SpanRerankParityTests.swift and rust/tests/span_rerank_parity.rs; int8 rows are the §4 expectation for SubstrateKernel Int8Vec.",
  "dim": DIM, "rrf_k": K, "span_weight": W, "model_id": "minilm-l6-v2-w60",
  "span_vectors": spans, "query_vectors": queries, "bm25_head": head, "expected_orders": orders,
}
json.dump(doc, open(OUT, "w"), indent=1)
print(f"wrote {OUT}: spans={len(spans)} queries={len(queries)} head={len(head)}")
print("q0 order:", orders[0]["order"][:8], "hits:", orders[0]["hits"][:3])

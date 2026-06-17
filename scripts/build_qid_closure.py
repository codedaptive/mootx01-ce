#!/usr/bin/env python3
"""
Build the pinned Q-ID taxonomic-closure artifact for DrawerFingerprint.qidClosureHash (#7).

Uses the MediaWiki wbgetentities API (NOT the WDQS SPARQL endpoint, which throttles/outages):
fetch DIRECT P31/P279 edges in batches of 50 entities, expand the frontier by BFS until no new
nodes appear, then compute each seed Q-ID's transitive ancestor closure LOCALLY.

One-time, build-time, offline snapshot — pinned + checked in like the FDC artifacts. Runtime
never re-queries. Output fully sorted -> byte-deterministic.
"""
import json, time, urllib.parse, urllib.request, os, re

LEXICON = "/Users/bob/devlop/mootx01-ce/packages/libs/LatticeLib/Sources/LatticeLib/Resources/Lexicon.json"
EDGES = "/Users/bob/devlop/mootx01-ce/scripts/qid_edges.json"
OUT = "/Users/bob/devlop/mootx01-ce/scripts/QIDClosure.partial.json"
API = "https://www.wikidata.org/w/api.php"
UA = "mootx01-qid-closure-builder/3.0 (offline pinned-artifact ETL; bob@codedaptive.com)"
BATCH = 50
SLEEP = 0.25
SNAPSHOT_DATE = "2026-06-17"

def log(m): print(f"[qid-closure] {m}", flush=True)

def load_qids():
    raw = open(LEXICON, "rb").read().decode("utf-8")
    return sorted(set(re.findall(r"Q[0-9]+", raw)), key=lambda q: int(q[1:]))

def query_edges(qids):
    """{qid: set(direct P31/P279 parent qids)} via the MediaWiki API (<=50 ids)."""
    url = API + "?" + urllib.parse.urlencode(
        {"action": "wbgetentities", "ids": "|".join(qids), "props": "claims", "format": "json"})
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = json.load(r)
    out = {}
    for qid, ent in data.get("entities", {}).items():
        if not re.fullmatch(r"Q[0-9]+", qid):
            continue
        parents = set()
        claims = ent.get("claims", {})
        for p in ("P31", "P279"):
            for snak in claims.get(p, []):
                dv = snak.get("mainsnak", {}).get("datavalue")
                if dv and dv.get("type") == "wikibase-entityid":
                    pid = dv["value"]["id"]
                    if re.fullmatch(r"Q[0-9]+", pid):
                        parents.add(pid)
        out[qid] = parents
    return out

def fetch_all_edges(seeds):
    edges = {}
    if os.path.exists(EDGES):
        edges = {k: set(v) for k, v in json.load(open(EDGES)).items()}
        log(f"resumed: {len(edges)} nodes already queried")
    queried = set(edges.keys())
    frontier = [q for q in seeds if q not in queried]
    level = 0
    while frontier:
        level += 1
        log(f"level {level}: {len(frontier)} nodes to query ({len(queried)} done)")
        nxt = set()
        nb = (len(frontier) + BATCH - 1) // BATCH
        for i in range(0, len(frontier), BATCH):
            batch = frontier[i:i + BATCH]
            got = None
            for attempt in range(5):
                try:
                    got = query_edges(batch); break
                except Exception as e:
                    w = SLEEP * (2 ** attempt) + 1
                    log(f"  L{level} batch {i//BATCH}/{nb} attempt {attempt} failed ({e}); retry {w:.1f}s")
                    time.sleep(w)
            if got is None:
                got = {}
                for one in batch:
                    for attempt in range(3):
                        try: got.update(query_edges([one])); break
                        except Exception: time.sleep(1 + attempt)
            for q in batch:
                edges[q] = sorted(got.get(q, set()), key=lambda x: int(x[1:]))
                queried.add(q)
                for pp in edges[q]:
                    if pp not in queried:
                        nxt.add(pp)
            if (i // BATCH) % 25 == 0:
                json.dump({k: edges[k] for k in edges}, open(EDGES + ".tmp", "w"), separators=(",", ":"))
                os.replace(EDGES + ".tmp", EDGES)
                log(f"  L{level} {i//BATCH}/{nb} batches; graph {len(edges)} nodes")
            time.sleep(SLEEP)
        json.dump({k: edges[k] for k in edges}, open(EDGES + ".tmp", "w"), separators=(",", ":"))
        os.replace(EDGES + ".tmp", EDGES)
        log(f"level {level} done; graph {len(edges)} nodes, {len(nxt)} new in next frontier")
        frontier = sorted(nxt, key=lambda x: int(x[1:]))
        if level > 30:
            log("safety cap (level>30); stop"); break
    return edges

def closure(qid, edges):
    seen, stack = set(), list(edges.get(qid, []))
    while stack:
        n = stack.pop()
        if n in seen: continue
        seen.add(n); stack.extend(edges.get(n, []))
    return sorted(seen, key=lambda x: int(x[1:]))

def main():
    seeds = load_qids()
    log(f"{len(seeds)} seed QIDs from Lexicon")
    edges = fetch_all_edges(seeds)
    log(f"edge graph complete: {len(edges)} nodes; computing {len(seeds)} closures")
    closures = {q: closure(q, edges) for q in seeds}
    obj = {
        "version": "1.0.0",
        "source": "Wikidata MediaWiki API (wbgetentities P31/P279) + local transitive closure",
        "generated_utc": SNAPSHOT_DATE,
        "relation": "P31|P279 (instance-of/subclass-of), transitive ancestors",
        "lexicon_qid_count": len(seeds),
        "closures": {q: closures[q] for q in sorted(closures, key=lambda x: int(x[1:]))},
    }
    json.dump(obj, open(OUT + ".tmp", "w"), separators=(",", ":"), sort_keys=True)
    os.replace(OUT + ".tmp", OUT)
    ne = sum(1 for v in closures.values() if v)
    log(f"DONE: {len(closures)} closures ({ne} non-empty). Artifact: {OUT}")

if __name__ == "__main__":
    main()

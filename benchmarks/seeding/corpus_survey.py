#!/usr/bin/env python3
"""Corpus survey — the AI-assist pre-parser.

Point it at a projected record set (any seeder's aggregate.json) and it
reports what an AI modeling a NEW corpus needs to see before freezing the
room structure:

1. ROOM PRESSURE: rooms holding an outsized share of the corpus, with the
   distinctive vocabulary of that room (terms over-represented vs the whole
   corpus). A coherent distinctive cluster = a sub-room suggestion
   ("work is 65% and its distinctive terms are leads/CRM/pipeline"
   -> suggest work/crm).

2. TUNNEL CANDIDATES: recurring proper-noun-ish entities that appear across
   MANY sessions in DIFFERENT rooms — the cross-references a user would have
   asked to tunnel ("my InnovateLeads dashboard" appearing in work and money
   sessions).

Pure term statistics, deterministic, no model. The output is advice to the
AI running the projection, not machinery in the measured system.
"""

import argparse
import json
import math
import re
from collections import Counter, defaultdict
from pathlib import Path

WORD = re.compile(r"[A-Za-z][A-Za-z'\-]+")
CAPSEQ = re.compile(r"\b([A-Z][a-z]+(?:[A-Z][a-z]+)+|[A-Z][a-z]+(?: [A-Z][a-z]+)+)\b")
STOP = set("""
the a an and or but if then else of to in on at for with from by about as is
are was were be been being do does did have has had will would can could
should may might must not no yes it its this that these those i you he she
they we me him her them us my your his their our mine yours user assistant
what when where which who whom how why there here all any some more most
other another such only own same so than too very just also like get got
one two okay ok let's im ive id ill dont cant wont thats youre hes shes
really thing things want know think see make good great sure well
""".split())


def tokens(text):
    return [w.lower() for w in WORD.findall(text)
            if len(w) > 2 and w.lower() not in STOP]


def survey(records, pressure_share=0.25, top_terms=15,
           entity_min_sessions=5):
    n = len(records)
    room_counts = Counter(r["room"] for r in records)

    # --- term stats: per-room vs global document frequency
    global_df = Counter()
    room_df = defaultdict(Counter)
    entity_rooms = defaultdict(set)     # entity -> rooms it appears in
    entity_sessions = Counter()         # entity -> #sessions containing it
    for r in records:
        toks = set(tokens(r["content"]))
        global_df.update(toks)
        room_df[r["room"]].update(toks)
        for ent in set(CAPSEQ.findall(r["content"])):
            entity_sessions[ent] += 1
            entity_rooms[ent].add(r["room"])

    print(f"records: {n}\n")
    print("== ROOM PRESSURE (share of corpus; sub-room suggested when share "
          f"> {pressure_share:.0%} and distinctive terms cohere)")
    for room, cnt in room_counts.most_common():
        share = cnt / n
        flag = "  <-- SUB-ROOM CANDIDATE" if share > pressure_share else ""
        print(f"  {room:10s} {cnt:6d}  {share:5.1%}{flag}")
        if share > pressure_share or room == room_counts.most_common(1)[0][0]:
            # distinctiveness: room df share vs global df share (log-lift)
            scored = []
            for term, df in room_df[room].items():
                if df < max(3, cnt * 0.02):
                    continue
                lift = (df / cnt) / ((global_df[term] + 1) / n)
                scored.append((math.log(lift + 1e-9) * df, term, df))
            scored.sort(reverse=True)
            terms = ", ".join(f"{t}({d})" for _, t, d in scored[:top_terms])
            print(f"             distinctive: {terms}")

    print(f"\n== TUNNEL CANDIDATES (entities in >= {entity_min_sessions} "
          "sessions; cross-room ones first)")
    cands = [(len(entity_rooms[e]), c, e) for e, c in entity_sessions.items()
             if c >= entity_min_sessions]
    cands.sort(reverse=True)
    for nrooms, c, e in cands[:25]:
        rooms = ",".join(sorted(entity_rooms[e]))
        print(f"  {e:32s} sessions:{c:5d}  rooms({nrooms}): {rooms}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("aggregate", help="a seeder's aggregate.json")
    ap.add_argument("--pressure-share", type=float, default=0.25)
    ap.add_argument("--entity-min-sessions", type=int, default=5)
    args = ap.parse_args()
    data = json.loads(Path(args.aggregate).read_text())
    survey(data["records"], pressure_share=args.pressure_share,
           entity_min_sessions=args.entity_min_sessions)


if __name__ == "__main__":
    main()

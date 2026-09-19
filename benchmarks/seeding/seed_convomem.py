#!/usr/bin/env python3
"""ConvoMem/LMEB seeding — Rule-1 projection (one drawer per session).

Source: benchmarks/fixtures/lmeb/data/ConvoMem/<evidence_set>/
  corpus.jsonl     one line per TURN, id scene_N_session_M_turn_K,
                   text already speaker-prefixed ("User: ...")
  queries.jsonl    1st-person queries, id scene_N_q_M
  qrels.tsv        query -> evidence TURN ids
  candidates.jsonl scene -> candidate turn ids (per-query unit scope)

Projection:
  - fold turns into one session document per scene_N_session_M
  - persona per (set, scene), queries rewritten 3rd person
  - no dates in source -> deterministic synthetic walk (sessions inside a
    scene are one day apart; scenes offset by hours)
  - qrels/candidates remap turn -> containing session (dedup'd)
  - aggregate ids namespaced "<set>/<scene>_session_<m>"

Outputs under --out: units/<set>__<scene>.json (first --limit scenes of
each set), wing-estate.json (all sets, plus entity drawers and tunnels),
questions.jsonl, stats, and projection/ in the artifact builder's shape
(seed_projection): one JSONL per unit written, room, shape and the gold
relation per query of the scene; question ids are "<set>__<scene>/q<n>".
The projection carries session records only; entity drawers and tunnels
exist in wing-estate.json alone.
"""

import argparse
import json
import re
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from pathlib import Path

import seed_lme_s
from seed_projection import emit_projection, room_rule_text
from seed_lme_s import (classify_room, emit_seed, persona_for,
                        require_unit_stem, rewrite_question, wing_for_room)

SETS = ["user_evidence", "changing_evidence", "assistant_facts_evidence",
        "abstention_evidence", "preference_evidence",
        "implicit_connection_evidence"]
BASE = datetime(2021, 1, 4, 9, 0)
_TURN = re.compile(r"^(scene_\d+)_(session_\d+)_turn_(\d+)$")


def session_of(turn_id):
    m = _TURN.match(turn_id)
    return f"{m.group(1)}_{m.group(2)}" if m else None


def event_iso(scene_idx, session_idx):
    dt = BASE + timedelta(days=session_idx, hours=scene_idx % 24,
                          minutes=(scene_idx * 7) % 60)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def load_set(root, set_name):
    d = root / set_name
    sessions = defaultdict(list)      # scene_session -> [(turn_no, text)]
    for line in (d / "corpus.jsonl").open():
        rec = json.loads(line)
        m = _TURN.match(rec["id"])
        if not m:
            continue
        key = f"{m.group(1)}_{m.group(2)}"
        sessions[key].append((int(m.group(3)), rec["text"]))
    queries = [json.loads(l) for l in (d / "queries.jsonl").open()]
    qrels = defaultdict(list)
    for line in (d / "qrels.tsv").open():
        parts = line.split()
        if len(parts) >= 2:
            s = session_of(parts[1])
            if s and s not in qrels[parts[0]]:
                qrels[parts[0]].append(s)
    candidates = {}
    for line in (d / "candidates.jsonl").open():
        rec = json.loads(line)
        seen = []
        for tid in rec["candidate_doc_ids"]:
            s = session_of(tid)
            if s and s not in seen:
                seen.append(s)
        candidates[rec["scene_id"]] = seen
    return sessions, queries, qrels, candidates


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixture-root", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=3,
                    help="unit files per evidence set")
    args = ap.parse_args()

    root = Path(args.fixture_root)
    out = Path(args.out)
    (out / "units").mkdir(parents=True, exist_ok=True)

    agg = {}
    room_counts = Counter()
    questions = []
    persona_index = 0
    stats = []
    projection_units = {}       # "<set>__<scene>" -> records, for emit_projection
    projection_questions = []   # unit / question_id / gold_ids

    for set_name in SETS:
        if not (root / set_name).exists():
            continue
        sessions, queries, qrels, candidates = load_set(root, set_name)

        # persona per scene, deterministic across the whole build
        scene_names = {}
        scenes = sorted({k.split("_session_")[0] for k in sessions},
                        key=lambda s: int(s.split("_")[1]))
        for sc in scenes:
            # units/<set>__<scene>.json; every scene is checked, not only
            # the first --limit that get a unit file.
            require_unit_stem(f"{set_name}__{sc}", sc)
            scene_names[sc] = persona_for(persona_index)
            persona_index += 1

        def record_for(key):
            scene, sess = key.split("_session_")
            scene_idx = int(scene.split("_")[1])
            turns = sorted(sessions[key])
            body = "\n".join(t for _, t in turns)
            iso = event_iso(scene_idx, int(sess))
            return {
                "content": body,
                "event_time": iso,
                "id": f"{set_name}/{key}",
                "room": classify_room(body),
                "subject": f"Session with {scene_names[scene]}, {iso[:10]}",
            }

        for key in sessions:
            rec = record_for(key)
            # Form 2: one wing per scene, neutral persona name.
            scene = key.split("_session_")[0]
            agg[rec["id"]] = {**rec, "wing": scene_names[scene]}
            room_counts[rec["room"]] += 1

        # per-scene unit files (Form 1, life wings; first --limit scenes)
        for sc in scenes[:args.limit]:
            keys = [k for k in sessions if k.startswith(sc + "_session_")]
            recs = [record_for(k) for k in sorted(
                keys, key=lambda k: int(k.split("_session_")[1]))]
            emit_seed(out / "units" / f"{set_name}__{sc}.json",
                      f"convomem-{set_name}-{sc}",
                      [{**r, "wing": wing_for_room(r["room"])} for r in recs])
            projection_units[f"{set_name}__{sc}"] = recs

        per_scene_q = Counter()
        for q in queries:
            scene = q["id"].rsplit("_q_", 1)[0]
            unit = f"{set_name}__{scene}"
            per_scene_q[scene] += 1
            if unit in projection_units:
                projection_questions.append({
                    "unit": unit, "question_id": f"{unit}/q{per_scene_q[scene]}",
                    "gold_ids": [f"{set_name}/{s}" for s in qrels.get(q["id"], [])]})
            # The harness derives the unit stem from query_id's scene
            # prefix; a query naming a scene outside `scenes` is checked
            # here on its own.
            require_unit_stem(f"{set_name}__{scene}", q["id"])
            name = scene_names.get(scene, "Alex Calder")
            questions.append({
                "set": set_name,
                "query_id": q["id"],
                "persona": name,
                "wing": name,
                "question": q["text"],
                "question_3p": rewrite_question(q["text"], name),
                "answer_session_ids":
                    [f"{set_name}/{s}" for s in qrels.get(q["id"], [])],
                "candidate_session_ids":
                    [f"{set_name}/{s}" for s in candidates.get(scene, [])],
            })
        stats.append((set_name, len(scenes), len(sessions), len(queries)))

    # Entity drawers + tunnels (survey-driven): recurring people/companies
    # get a topical drawer, tunneled to every session that mentions them —
    # the cross-references a user would have asked for. Greeting/boilerplate
    # phrases are filtered; places pass the filter but rarely clear the
    # session floor as coherent contacts, and a spare place drawer is
    # harmless organization.
    capseq = re.compile(
        r"\b([A-Z][a-z]+(?:[A-Z][a-z]+)+|[A-Z][a-z]+(?: [A-Z][a-z]+)+)\b")
    greeting = re.compile(
        r"^(Hello|Hi|Hey|Dear|Thanks|Thank|Good|Okay|Sounds|Executive"
        r"|Next|Key|Action|Draft|Subject|Best|Regards)\b")
    mentions = defaultdict(list)
    for rid, rec in agg.items():
        for ent in set(capseq.findall(rec["content"])):
            if not greeting.match(ent):
                mentions[ent].append(rid)
    entity_records, tunnels = [], []
    # Second tokens that mark a place/org, not a person, even in
    # "Xxx Xxx" shape.
    nonperson = {"Francisco", "Northwest", "Coast", "Area", "Valley",
                 "Park", "County", "District", "Asia", "York", "Hill",
                 "Arbor", "Solutions", "Systems", "Technologies", "Labs",
                 "Group", "Partners", "Inc", "Beach", "City", "Island",
                 "Diego", "Angeles", "Vegas", "Summary"}
    base_iso = BASE.strftime("%Y-%m-%dT%H:%M:%SZ")
    top = sorted(((len(v), e) for e, v in mentions.items()), reverse=True)
    for count, ent in top:
        if count < 30 or len(entity_records) >= 40:
            break
        eid = "entity/" + ent.lower().replace(" ", "-")
        context = " ".join(agg[r]["content"][:400] for r in mentions[ent][:20])
        room = ("people"
                if re.fullmatch(r"[A-Z][a-z]+ [A-Z][a-z]+", ent)
                and ent.split()[1] not in nonperson
                else classify_room(context))
        entity_records.append({
            "content": f"{ent} — recurring contact/topic across "
                       f"{count} saved sessions.",
            "event_time": base_iso,
            "id": eid,
            "room": room,
            "subject": f"{ent} (recurring across sessions)",
            # Entity drawers span scenes, so they take life wings.
            "wing": wing_for_room(room),
        })
        for rid in mentions[ent]:
            tunnels.append({"from": eid, "to": rid, "kind": "references",
                            "label": f"mentions {ent}"})

    # Form 2 for ConvoMem (no haystack overlap): the aggregate IS the wing
    # estate — session records carry per-scene persona wings.
    emit_seed(out / "wing-estate.json", "convomem-wing-estate",
              list(agg.values()) + entity_records, tunnels=tunnels)
    print(f"entity drawers: {len(entity_records)}, tunnels: {len(tunnels)}")
    with (out / "questions.jsonl").open("w") as f:
        for q in questions:
            f.write(json.dumps(q, ensure_ascii=False) + "\n")
    # Session ids are namespaced by set and scene, so no unit shares a record
    # with another: overlap False.
    emit_projection(out, dataset="convomem", room_rule=room_rule_text(seed_lme_s),
                    overlap=False, units=projection_units,
                    questions=projection_questions, shape="session")

    print(f"{'set':34s} {'scenes':>7s} {'sessions':>9s} {'queries':>8s}")
    for name, sc, se, qn in stats:
        print(f"{name:34s} {sc:7d} {se:9d} {qn:8d}")
    print(f"\naggregate session drawers: {len(agg)}")
    no_ev = sum(1 for q in questions if not q["answer_session_ids"])
    print(f"questions: {len(questions)} (no evidence — abstention by design: {no_ev})")
    print("\nroom distribution (aggregate):")
    for room, n in room_counts.most_common():
        print(f"  {room:10s} {n:6d}  {100*n/len(agg):5.1f}%")


if __name__ == "__main__":
    main()

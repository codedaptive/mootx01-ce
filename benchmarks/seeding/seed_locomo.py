#!/usr/bin/env python3
"""LoCoMo seeding — Rule-1 projection (one drawer per session).

locomo10.json = 10 two-person multi-session conversations. Speakers are
already named people, so no persona machinery and no question rewrite —
LoCoMo questions are natively 3rd person ("When did Caroline go to ...").

  - unit = one conversation (10 units), record per session
  - subject = "Session between <A> and <B>, <YYYY-MM-DD>"
  - aggregate ids namespaced "<sample_id>/S<n>" (no sharing across convs)
  - qrels: evidence dia_ids ("D3:7") map to their session ("S3")

Outputs under --out: units/<sample_id>.json, aggregate.json,
questions.jsonl, stats to stdout, and projection/ in the artifact builder's
shape (seed_projection.emit_projection): one JSONL per unit with room, shape
and the gold relation per question; question ids are "<sample_id>/q<n>".
"""

import argparse
import json
import re
from collections import Counter
from datetime import datetime
from pathlib import Path

import seed_lme_s
from seed_lme_s import (classify_room, emit_seed, require_unit_stem,
                        wing_for_room)
from seed_projection import emit_projection, room_rule_text


def parse_locomo_date(raw: str) -> str:
    """'1:56 pm on 8 May, 2023' -> '2023-05-08T13:56:00Z'."""
    dt = datetime.strptime(raw.strip(), "%I:%M %p on %d %B, %Y")
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def turn_line(turn) -> str:
    text = turn.get("text", "")
    caption = turn.get("blip_caption")
    if caption:
        text = f"{text} [shares photo: {caption}]" if text else f"[shares photo: {caption}]"
    return f"{turn['speaker']}: {text}"


def conversation_records(conv, sample_id, a, b):
    records = []
    n = 1
    while f"session_{n}" in conv:
        session = conv.get(f"session_{n}") or []
        raw_date = conv.get(f"session_{n}_date_time")
        if session and raw_date:
            iso = parse_locomo_date(raw_date)
            body = "\n".join(turn_line(t) for t in session)
            records.append({
                "content": body,
                "event_time": iso,
                "id": f"{sample_id}/S{n}",
                "room": classify_room(body),
                "subject": f"Session between {a} and {b}, {iso[:10]}",
            })
        n += 1
    return records


def evidence_sessions(evidence) -> list:
    """qa 'evidence' is a list (or stringified list) of dia_ids 'D<sess>:<turn>'."""
    if isinstance(evidence, str):
        try:
            evidence = json.loads(evidence.replace("'", '"'))
        except json.JSONDecodeError:
            evidence = re.findall(r"D\d+:\d+", evidence)
    out = []
    for dia in evidence or []:
        m = re.match(r"D(\d+):", str(dia))
        if m and f"S{m.group(1)}" not in out:
            out.append(f"S{m.group(1)}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixture", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=None,
                    help="only the first N conversations (tests use 1)")
    args = ap.parse_args()

    data = json.loads(Path(args.fixture).read_text())
    if args.limit is not None:
        data = data[:args.limit]
    out = Path(args.out)
    (out / "units").mkdir(parents=True, exist_ok=True)

    agg = []
    wing_estate = []
    room_counts = Counter()
    questions = []
    projection_units = {}       # sample_id -> records, for emit_projection
    projection_questions = []   # unit / question_id / gold_ids
    wing_names = {}     # sample_id -> unique neutral wing name (speaker pair)
    for c in data:
        conv = c["conversation"]
        a, b = conv["speaker_a"], conv["speaker_b"]
        # The unit stem IS the sample id (units/<sample_id>.json).
        sid = require_unit_stem(c["sample_id"], c["sample_id"])
        wing = f"{a} & {b}"
        if wing in wing_names.values():          # disambiguate reused pairs
            wing = f"{a} & {b} ({len(wing_names) + 1})"
        wing_names[sid] = wing
        records = conversation_records(conv, sid, a, b)
        # Form 1 unit: life wings (Personal/Professional by room).
        emit_seed(out / "units" / f"{sid}.json", f"locomo-{sid}",
                  [{**r, "wing": wing_for_room(r["room"])} for r in records])
        # Form 2: one wing per conversation, neutral speaker-pair name.
        wing_estate.extend({**r, "wing": wing} for r in records)
        agg.extend(records)
        projection_units[sid] = records
        for r in records:
            room_counts[r["room"]] += 1
        for q_index, q in enumerate(c["qa"], start=1):
            sessions = evidence_sessions(q.get("evidence"))
            projection_questions.append({
                "unit": sid, "question_id": f"{sid}/q{q_index}",
                "gold_ids": [f"{sid}/{s}" for s in sessions]})
            questions.append({
                "sample_id": sid,
                "wing": wing,
                "question": q["question"],
                "answer": q.get("answer"),
                "category": q.get("category"),
                "evidence_dia_ids": q.get("evidence"),
                "answer_session_ids": [f"{sid}/{s}" for s in sessions],
            })

    emit_seed(out / "aggregate.json", "locomo-aggregate", agg)
    emit_seed(out / "wing-estate.json", "locomo-wing-estate", wing_estate)
    with (out / "questions.jsonl").open("w") as f:
        for q in questions:
            f.write(json.dumps(q, ensure_ascii=False) + "\n")
    # LoCoMo haystacks never share sessions across conversations: overlap False.
    emit_projection(out, dataset="locomo", room_rule=room_rule_text(seed_lme_s),
                    overlap=False, units=projection_units,
                    questions=projection_questions, shape="session")

    no_evidence = sum(1 for q in questions if not q["answer_session_ids"])
    print(f"conversations: {len(data)}")
    print(f"session drawers (aggregate): {len(agg)}")
    print(f"questions: {len(questions)} "
          f"(no session evidence — e.g. adversarial: {no_evidence})")
    print("\nroom distribution:")
    for room, n in room_counts.most_common():
        print(f"  {room:10s} {n:4d}  {100*n/len(agg):5.1f}%")
    print(f"\nwrote {len(data)} unit files, aggregate.json, questions.jsonl, "
          f"projection/ -> {out}")


if __name__ == "__main__":
    main()

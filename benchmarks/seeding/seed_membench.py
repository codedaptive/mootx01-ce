#!/usr/bin/env python3
"""MemBench seeding — Rule-2 projection (topical drawer + kgfacts).

MemData/{FirstAgent,ThirdAgent}/<category>.json — each file holds sections
(roles/events/items/places/hybrid); a section is a list of items; an item
is one small world: a message_list of dated single-statement messages, each
pre-parsed as rel / attr / value, plus one QA.

Projection per item:
  - group messages by rel — one TOPICAL DRAWER per (item, rel):
      person rels (boss, Mother, ...)   -> room people
      Own                               -> room home
      Lives Here                        -> room home
      event rels (attr mentions event)  -> room events
    drawer body = the dated statements verbatim (time survives in content;
    the facts[] seam carries no event time).
  - one kgfact per message: subject = persona's rel handle,
    predicate = attr, object = value, record_id = the drawer.
  - persona per item (deterministic); questions get the persona spliced in
    ("the boss" -> "<Name>'s boss") for the aggregate tier.
  - qrels: QA.target_step_id (mids) -> the drawers holding those mids.

Outputs under --out: units/ (first --limit items of each family/category),
wing-estate.json (drawers + facts), questions.jsonl, stats, and projection/
in the artifact builder's shape (seed_projection): one JSONL per unit
written with room, shape and the gold relation to the item's one question,
id "<unit>/q1". The projection carries drawers only; kgfacts exist in the
unit and wing-estate seed files alone.
"""

import argparse
import json
import re
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

from seed_projection import emit_projection
from seed_lme_s import (emit_seed, persona_for, require_unit_stem,
                        rewrite_question, wing_for_room)

FAMILIES = ["FirstAgent", "ThirdAgent"]
PERSON_RELS = {
    "boss", "coworker", "subordinate", "Mother", "Father", "Sister",
    "Brother", "Aunt", "Uncle", "Niece", "Nephew", "Cousin(Female)",
    "Cousin(Male)", "Grandmother", "Grandfather", "Friend", "friend",
}


def parse_time(raw):
    """"'2024-10-01 08:00' Tuesday" -> ISO Z."""
    m = re.search(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2})", str(raw))
    if not m:
        return "2024-10-01T00:00:00Z"
    return datetime.strptime(m.group(1), "%Y-%m-%d %H:%M")\
        .strftime("%Y-%m-%dT%H:%M:%SZ")


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", str(s).lower()).strip("-")


# room_for in words, for the builder ledger (seed_projection.emit_projection).
ROOM_RULE = ("room = room_for(rel, messages, section): events/items/places "
             "sections -> events/home/home; person rels -> people; Own or "
             "Lives Here -> home; event rels or event attrs -> events; hybrid "
             "section otherwise -> events; else general")


def room_for(rel, messages, section=""):
    # The source's own section typing decides when rel/attr text doesn't:
    # events/items/places sections are events/home/home respectively.
    if section == "events":
        return "events"
    if section in ("items", "places"):
        return "home"
    base = rel.split("#")[0]     # FirstAgent thread labels carry "#idx"
    if base in PERSON_RELS or base.lower() in {r.lower() for r in PERSON_RELS}:
        return "people"
    if base in ("Own", "Lives Here"):
        return "home"
    if base.startswith("event ") or any(
            "event" in str(m.get("attr", "")).lower() for m in messages):
        return "events"
    # hybrid mixes persons, possessions, and events; a rel that is none of
    # the former is an event name (Team Connect, ClimbFest, ...).
    if section == "hybrid":
        return "events"
    return "general"


def subject_for(persona, rel, room):
    first = persona.split()[0]
    base = rel.split("#")[0]
    if room == "people":
        return f"{first}'s {base}"
    if base == "Own":
        return f"{first}'s belongings"
    if base == "Lives Here":
        return f"{first}'s home"
    if room == "events":
        return f"{base.removeprefix('event ')} (event {first} follows)"
    return f"{first}'s notes ({base})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixture-root", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=2,
                    help="unit files per (family, category)")
    args = ap.parse_args()

    root = Path(args.fixture_root)
    out = Path(args.out)
    (out / "units").mkdir(parents=True, exist_ok=True)

    agg_records, agg_facts = [], []
    room_counts = Counter()
    questions = []
    projection_units = {}       # unit stem -> drawers, for emit_projection
    projection_questions = []   # unit / question_id / gold_ids
    persona_idx = 0
    n_items = n_msgs = 0

    for fam in FAMILIES:
        for cat_file in sorted((root / fam).glob("*.json")):
            cat = cat_file.stem
            data = json.loads(cat_file.read_text())
            emitted_units = 0
            for sec, items in data.items():
                if not isinstance(items, list):
                    continue
                for item in items:
                    ml = item.get("message_list")
                    if not ml:
                        continue
                    n_items += 1
                    persona = persona_for(persona_idx)
                    persona_idx += 1
                    # Two shipped shapes:
                    #   ThirdAgent: flat list of dicts pre-parsed with
                    #     rel/attr/value -> group by rel, facts minted.
                    #   FirstAgent: list of THREADS (lists of dialog
                    #     exchanges, no triples) -> one topical drawer per
                    #     thread, dated statements verbatim, NO facts
                    #     (nothing shipped to file as triples).
                    by_rel = defaultdict(list)
                    if isinstance(ml[0], dict):
                        for m in ml:
                            by_rel[m.get("rel", "misc")].append(m)
                    else:
                        person_words = {
                            "uncle", "aunt", "mother", "father", "mom", "dad",
                            "sister", "brother", "niece", "nephew", "cousin",
                            "grandmother", "grandfather", "boss", "coworker",
                            "subordinate", "friend", "neighbor", "colleague",
                            "wife", "husband", "partner", "mentor"}
                        for t_idx, thread in enumerate(ml):
                            first_msg = str(thread[0].get("user_message", ""))
                            m_rel = re.search(r"\bmy (\w+)\b", first_msg,
                                              re.IGNORECASE)
                            m_evt = re.search(
                                r"\battend(?:ing)? (?:the )?([A-Z][\w&' -]*)",
                                first_msg)
                            if m_rel and m_rel.group(1).lower() in person_words:
                                label = m_rel.group(1).lower()
                            elif m_evt:
                                label = f"event {m_evt.group(1).strip()}"
                            elif re.search(r"\bI live\b", first_msg):
                                label = "Lives Here"
                            elif re.search(r"\b(I'm all about|I use|I own)\b",
                                           first_msg):
                                label = "Own"
                            else:
                                label = f"thread-{t_idx}"
                            by_rel[f"{label}#{t_idx}"] = [
                                {"mid": f"{t_idx}-{x.get('sid')}",
                                 "message": f"user: {x.get('user_message', '')}"
                                            f"\nassistant: "
                                            f"{x.get('assistant_message', '')}",
                                 "time": x.get("time", ""),
                                 "place": x.get("place", ""),
                                 "rel": label}
                                for x in thread]
                    unit_records, unit_facts = [], []
                    mid_to_drawer = {}
                    base = f"{fam}/{cat}/{sec}/{item.get('tid')}"
                    used_slugs = {}
                    for rel, msgs in by_rel.items():
                        room = room_for(rel, msgs, sec)
                        # Distinct rels can slug identically ("Surf Fest" /
                        # "Surf-Fest") — disambiguate within the item so ids
                        # stay unique across the seed file.
                        s = slug(rel)
                        n = used_slugs.get(s, 0)
                        used_slugs[s] = n + 1
                        if n:
                            s = f"{s}-{n + 1}"
                        did = f"{base}/{s}"
                        lines = [
                            f"{parse_time(m['time'])[:16]} "
                            f"({m.get('place', '-')}) — {m['message']}"
                            for m in msgs]
                        subject = subject_for(persona, rel, room)
                        rec = {
                            "content": f"{subject}.\n" + "\n".join(lines),
                            "event_time": parse_time(msgs[0]["time"]),
                            "id": did,
                            "room": room,
                            "subject": subject,
                        }
                        unit_records.append(rec)
                        room_counts[room] += 1
                        for m in msgs:
                            n_msgs += 1
                            mid_to_drawer[str(m["mid"])] = did
                            # Facts only where the source ships triples
                            # (ThirdAgent); FirstAgent threads have none.
                            if m.get("attr") is not None:
                                unit_facts.append({
                                    "subject": subject,
                                    "predicate": str(m.get("attr", "")),
                                    "object": str(m.get("value", "")),
                                    "record_id": did,
                                })
                    # Form 2: one wing per item, neutral persona name.
                    agg_records.extend(
                        {**r, "wing": persona} for r in unit_records)
                    agg_facts.extend(unit_facts)

                    qa = item.get("QA") or {}
                    q = str(qa.get("question", ""))
                    first = persona.split()[0]
                    q3 = q
                    for rel in by_rel:
                        base_rel = str(rel).split("#")[0]
                        q3 = re.sub(rf"\bthe {re.escape(base_rel)}\b",
                                    f"{first}'s {base_rel}", q3)
                    # Full 1st/2nd-person conversion — the rel splice alone
                    # left "my aunt"-style possessives untouched (QA FAIL
                    # class, 34% of the MemBench sample).
                    q3 = rewrite_question(q3, persona)
                    # target_step_id: ThirdAgent = [sid, ...];
                    # FirstAgent = [[flat_sid, thread_idx], ...] (sometimes
                    # as a string). mid keys: ThirdAgent "sid",
                    # FirstAgent "thread-sid".
                    raw_ts = qa.get("target_step_id") or []
                    if isinstance(raw_ts, str):
                        try:
                            raw_ts = json.loads(raw_ts)
                        except json.JSONDecodeError:
                            raw_ts = []
                    ev = []
                    for s in raw_ts:
                        key = (f"{s[1]}-{s[0]}" if isinstance(s, list)
                               else str(s))
                        ev.append(mid_to_drawer.get(key))
                    # units/<family>__<category>__<section>__<tid>.json;
                    # the harness rebuilds this stem from the question row,
                    # so every item is checked, not only the emitted units.
                    unit_stem = require_unit_stem(
                        f"{fam}__{cat}__{sec}__{item.get('tid')}",
                        f"{fam}/{cat}/{sec}/{item.get('tid')}")
                    questions.append({
                        "family": fam, "category": cat, "section": sec,
                        "tid": item.get("tid"), "persona": persona,
                        "wing": persona,
                        "question": q, "question_3p": q3,
                        "answer": qa.get("answer"),
                        "choices": qa.get("choices"),
                        "answer_drawer_ids":
                            sorted({d for d in ev if d}),
                    })
                    if emitted_units < args.limit:
                        emit_seed(out / "units" / f"{unit_stem}.json",
                                  f"membench-{fam}-{cat}-{item.get('tid')}",
                                  [{**r, "wing": wing_for_room(r["room"])}
                                   for r in unit_records],
                                  facts=unit_facts)
                        emitted_units += 1
                        projection_units[unit_stem] = unit_records
                        projection_questions.append({
                            "unit": unit_stem, "question_id": f"{unit_stem}/q1",
                            "gold_ids": sorted({d for d in ev if d})})

    # Form 2 for MemBench (no overlap): the aggregate IS the wing estate.
    emit_seed(out / "wing-estate.json", "membench-wing-estate",
              agg_records, facts=agg_facts)
    with (out / "questions.jsonl").open("w") as f:
        for q in questions:
            f.write(json.dumps(q, ensure_ascii=False) + "\n")
    # Every item is its own small world; drawer ids never repeat across
    # units, so the aggregate is a straight second write: overlap False.
    emit_projection(out, dataset="membench", room_rule=ROOM_RULE, overlap=False,
                    units=projection_units, questions=projection_questions,
                    shape="topical")

    print(f"items: {n_items}, messages: {n_msgs}")
    print(f"topical drawers: {len(agg_records)}, kgfacts: {len(agg_facts)}")
    print(f"questions: {len(questions)} "
          f"(no evidence: {sum(1 for q in questions if not q['answer_drawer_ids'])})")
    print("\nroom distribution:")
    for room, n in room_counts.most_common():
        print(f"  {room:8s} {n:6d}  {100*n/len(agg_records):5.1f}%")


if __name__ == "__main__":
    main()

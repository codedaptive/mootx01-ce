#!/usr/bin/env python3
"""lme-s seeding spike — Rule-1 projection (one drawer per session).

Reads longmemeval_s_cleaned.json and projects it into moot_json_import
seed files (schema v1) per the 2026-08-27 structure rulings:
  - one record per session, body VERBATIM ("role: content" lines)
  - event_time = the session's real corpus date
  - persona per instance (deterministic), subject wrapper
    "Session with <Name>, <YYYY-MM-DD>"
  - room from the coarse 12+1 keyword lexicon (provenance-blind)
  - questions rewritten 3rd person naming the persona

Outputs (under --out):
  units/<qid>.json        per-instance seed file (first --limit instances)
  aggregate.json          dedup'd union across ALL instances (session-id keyed)
  projection/             the artifact builder's shape (seed_projection): one
                          JSONL per unit written (first --limit instances) with
                          room, shape and the gold relation; question id "<qid>/q1"
  questions.jsonl         rewritten questions + qrels (answer_session_ids)
  stats printed to stdout.
"""

import argparse
import json
import re
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

from seed_projection import emit_projection, room_rule_text

# ---------------------------------------------------------------- personas

FIRST = [
    "Alex", "Priya", "Marcus", "Elena", "Tomas", "Aisha", "Jordan", "Mei",
    "Victor", "Sofia", "Dmitri", "Hannah", "Kwame", "Lucia", "Owen", "Yuki",
    "Nadia", "Felix", "Ingrid", "Rafael", "Zara", "Colin", "Amara", "Stefan",
    "Leila", "Bruno", "Tessa", "Hugo", "Freya", "Dante", "Iris", "Emil",
    "Carmen", "Silas", "Wanda", "Pavel", "Greta", "Omar", "Bianca", "Lars",
]
LAST = [
    "Calder", "Nishimura", "Okafor", "Marchetti", "Lindqvist", "Deshpande",
    "Kovacs", "Whitfield", "Aldana", "Petrov", "Halloran", "Mbeki",
    "Sorensen", "Vidal", "Tanaka", "Brennan", "Iqbal", "Moreau", "Castillo",
    "Novak", "Ferreira", "Ashford", "Duran", "Kimura", "Vance",
]


def persona_for(index: int) -> str:
    """Deterministic instance-order -> unique full name. 1000 combos, then
    a numeric suffix keeps names unique at any corpus size (ConvoMem has
    5,867 scenes, MemBench 20,137 items)."""
    base = f"{FIRST[index % len(FIRST)]} {LAST[(index // len(FIRST)) % len(LAST)]}"
    combos = len(FIRST) * len(LAST)
    return base if index < combos else f"{base} {index // combos + 1}"


def wing_for_room(room: str) -> str:
    """Life-wing mapping (Form 1 units and the lme beast): work topics file
    to Professional, everything else Personal. Wing names never carry
    benchmark identity — the wing<->dataset mapping lives in harness
    config, per the 2026-08-27 two-form ruling."""
    return "Professional" if room.split("/")[0] == "work" else "Personal"


# ---------------------------------------------------------------- rooms

# Coarse 12+1 taxonomy (approved 2026-08-27). Keyword lexicon scorer:
# case-insensitive whole-word hits, highest count wins, ties break in this
# fixed order, below-threshold lands in general.
ROOM_ORDER = [
    "people", "work", "health", "home", "money", "food", "travel",
    "hobbies", "media", "tech", "learning", "events",
]
LEXICON = {
    "people": [
        "friend", "family", "mother", "father", "sister", "brother", "wife",
        "husband", "partner", "girlfriend", "boyfriend", "colleague",
        "coworker", "boss", "neighbor", "cousin", "aunt", "uncle", "relationship",
    ],
    "work": [
        "job", "work", "career", "interview", "resume", "meeting", "client",
        "project", "deadline", "manager", "office", "business", "startup",
        "salary", "promotion", "hire", "hiring", "company", "team", "invoice",
        "marketing", "sales", "customer",
    ],
    "health": [
        "workout", "exercise", "gym", "run", "running", "yoga", "diet",
        "doctor", "sleep", "stress", "anxiety", "meditation", "therapy",
        "injury", "pain", "calories", "fitness", "weight", "protein",
        "symptoms", "medication", "mental health", "spin class",
    ],
    "home": [
        "apartment", "house", "furniture", "decor", "garden", "renovation",
        "cleaning", "living room", "bedroom", "kitchen", "rent", "lease",
        "landlord", "coffee table", "couch", "plants", "redecorating",
        "homeowner", "mortgage",
    ],
    "money": [
        "budget", "budgeting", "spending", "savings", "invest", "investment",
        "loan", "debt", "bank", "tax", "taxes", "insurance", "credit",
        "finance", "financial", "fintech", "retirement", "expense",
    ],
    "food": [
        "recipe", "cook", "cooking", "dinner", "lunch", "breakfast",
        "restaurant", "meal", "baking", "ingredients", "chicken", "pasta",
        "vegetarian", "vegan", "pancakes", "dessert", "cuisine",
    ],
    "travel": [
        "trip", "travel", "flight", "hotel", "vacation", "itinerary",
        "airport", "visa", "passport", "tour", "destination", "airline",
        "booking", "road trip", "sightseeing",
    ],
    "hobbies": [
        "board game", "game", "gaming", "hobby", "craft", "knitting",
        "painting", "photography", "hiking", "camping", "fishing", "chess",
        "puzzle", "collect", "collecting", "gardening", "woodworking",
        "guitar", "piano",
    ],
    "media": [
        "book", "books", "novel", "movie", "film", "music", "album",
        "playlist", "series", "show", "podcast", "author", "reading",
        "writing", "essay", "poem", "zine", "youtube", "channel",
    ],
    "tech": [
        "code", "coding", "python", "javascript", "software", "app", "phone",
        "laptop", "computer", "battery", "algorithm", "programming", "server",
        "database", "raspberry pi", "linux", "android", "iphone", "samsung",
        "wifi", "bug", "api",
    ],
    "learning": [
        "learn", "learning", "course", "class", "study", "studying", "exam",
        "degree", "university", "college", "school", "tutorial", "lecture",
        "language", "spanish", "french", "training", "certification",
        "education", "student",
    ],
    "events": [
        "party", "wedding", "birthday", "concert", "festival", "event",
        "appointment", "schedule", "guest list", "invitation", "anniversary",
        "reunion", "conference", "ceremony",
    ],
}
THRESHOLD = 2  # fewer than this many lexicon hits -> general

# One combined alternation, longest keywords first so multi-word phrases win.
_KW_TO_ROOM = {}
for _room, _kws in LEXICON.items():
    for _kw in _kws:
        _KW_TO_ROOM[_kw] = _room
_ALL_KW_RE = re.compile(
    r"\b(" + "|".join(re.escape(k) for k in
                      sorted(_KW_TO_ROOM, key=len, reverse=True)) + r")\b")
_ROOM_RANK = {room: i for i, room in enumerate(ROOM_ORDER)}


# Sub-rooms (survey-driven, 2026-08-27): when a coarse room wins AND the
# sub-lexicon fires strongly, the record files to the topic-specific
# sub-room hanging off the parent (room paths are hierarchical). First
# entry: work/crm, surfaced by corpus_survey.py on the ConvoMem aggregate
# (work at 65% with crm/sales/pipeline/leads as its distinctive terms).
SUBROOMS = {
    "work": {
        "crm": [
            "crm", "lead", "leads", "pipeline", "prospect", "prospects",
            "quota", "outreach", "cold call", "follow-up", "deal", "deals",
            "demo", "sales call", "closing", "commission", "account manager",
        ],
    },
}
SUB_THRESHOLD = 3

_SUB_RE = {
    parent: {
        sub: re.compile(r"\b(" + "|".join(re.escape(k) for k in
                        sorted(kws, key=len, reverse=True)) + r")\b")
        for sub, kws in subs.items()
    }
    for parent, subs in SUBROOMS.items()
}


def classify_room(text: str) -> str:
    lowered = text.lower()
    counts = Counter()
    for m in _ALL_KW_RE.finditer(lowered):
        counts[_KW_TO_ROOM[m.group(1)]] += 1
    if not counts:
        return "general"
    best_room = min(counts, key=lambda r: (-counts[r], _ROOM_RANK[r]))
    if counts[best_room] < THRESHOLD:
        return "general"
    for sub, rx in _SUB_RE.get(best_room, {}).items():
        if len(rx.findall(lowered)) >= SUB_THRESHOLD:
            return f"{best_room}/{sub}"
    return best_room


# ---------------------------------------------------------------- questions

# Assistant-addressed frames ("Can you remind me of X?") must transform
# BEFORE pronoun substitution, or the addressee and subject collapse to the
# same name ("Can Alex remind Alex of X?" — the ConvoMem QA failure class).
_FRAME_REMIND = re.compile(
    r"^(?:Can|Could|Would|Will)\s+you\s+(?:please\s+)?remind\s+me\s+"
    r"(?:of|about|)\s*", re.IGNORECASE)
_FRAME_TELL_WH = re.compile(
    r"^(?:Can|Could|Would|Will)\s+you\s+(?:please\s+)?"
    r"(?:tell\s+me|let\s+me\s+know)\s+"
    r"(what|where|when|who|whom|which|how|why)\s*", re.IGNORECASE)
_FRAME_KNOW_WH = re.compile(
    r"^Do\s+you\s+(?:know|remember|recall)\s+"
    r"(what|where|when|who|whom|which|how|why)\s*", re.IGNORECASE)


def strip_assistant_frame(q: str) -> str:
    m = _FRAME_TELL_WH.match(q) or _FRAME_KNOW_WH.match(q)
    if m:
        rest = q[m.end():].strip()
        out = f"{m.group(1).capitalize()} {rest}".rstrip(".?! ")
        return out + "?"
    m = _FRAME_REMIND.match(q)
    if m:
        rest = q[m.end():].strip().rstrip(".?! ")
        return f"What is {rest}?" if rest else q
    return q


# Mechanical 1st->3rd person rewrite. Order matters: longer phrases first.
def rewrite_question(q: str, name: str) -> str:
    q = strip_assistant_frame(q)
    first = name.split()[0]
    subs = [
        (r"\bI have\b", f"{first} has"),
        (r"\bI am\b", f"{first} is"),
        (r"\bI was\b", f"{first} was"),
        (r"\bI do\b", f"{first} does"),
        (r"\byou were\b", f"{first} was"),
        (r"\byou are\b", f"{first} is"),
        (r"\byou have\b", f"{first} has"),
        (r"\bare you\b", f"is {first}"),
        (r"\bAre you\b", f"Is {first}"),
        (r"\bdo you\b", f"does {first}"),
        (r"\bDo you\b", f"Does {first}"),
        (r"\bdid you\b", f"did {first}"),
        (r"\bDid you\b", f"Did {first}"),
        (r"\bhave you\b", f"has {first}"),
        (r"\bHave you\b", f"Has {first}"),
        (r"\byou'\w+\b", first),
        (r"\byour\b", f"{first}'s"),
        (r"\bYour\b", f"{first}'s"),
        (r"\byours\b", f"{first}'s"),
        (r"\byourself\b", first),
        (r"\byou\b", first),
        (r"\bYou\b", first),
        (r"\bam I\b", f"is {first}"),
        (r"\bAm I\b", f"Is {first}"),
        (r"\bdo I\b", f"does {first}"),
        (r"\bDo I\b", f"Does {first}"),
        (r"\bdid I\b", f"did {first}"),
        (r"\bDid I\b", f"Did {first}"),
        (r"\bhave I\b", f"has {first}"),
        (r"\bHave I\b", f"Has {first}"),
        (r"\bwas I\b", f"was {first}"),
        (r"\bWas I\b", f"Was {first}"),
        (r"\bI'm\b", f"{first} is"),
        (r"\bI've\b", f"{first} has"),
        (r"\bI'll\b", f"{first} will"),
        (r"\bI'd\b", f"{first} would"),
        (r"\bI\b", first),
        (r"\bmy\b", f"{first}'s"),
        (r"\bMy\b", f"{first}'s"),
        (r"\bme\b", first),
        (r"\bmine\b", f"{first}'s"),
        (r"\bmyself\b", f"{first}"),
    ]
    out = q
    for pat, rep in subs:
        out = re.sub(pat, rep, out)
    return out


# ---------------------------------------------------------------- dates

def parse_lme_date(raw: str) -> str:
    """'2023/05/20 (Sat) 02:21' -> '2023-05-20T02:21:00Z'."""
    cleaned = re.sub(r"\s*\([^)]*\)\s*", " ", raw).strip()
    dt = datetime.strptime(cleaned, "%Y/%m/%d %H:%M")
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- records

_room_cache = {}


def session_record(session, session_id, date_raw, persona):
    body = "\n".join(f"{t['role']}: {t['content']}" for t in session)
    iso = parse_lme_date(date_raw)
    day = iso[:10]
    if session_id not in _room_cache:
        _room_cache[session_id] = classify_room(body)
    room = _room_cache[session_id]
    return {
        "content": body,
        "event_time": iso,
        "id": session_id,
        "room": room,
        "subject": f"Session with {persona}, {day}",
        "wing": wing_for_room(room),
    }


# ---------------------------------------------------------------- unit stems

# Longest unit stem accepted, in bytes. A stem names a unit seed file
# (units/<stem>.json) and, downstream, a unit estate directory; 128 keeps
# both well inside every filesystem's name limit with room for the suffix.
UNIT_STEM_MAX_LEN = 128
_UNIT_STEM_ALNUM = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
_UNIT_STEM_CHARS = _UNIT_STEM_ALNUM | frozenset("._-")
UNIT_STEM_RULE = ("a unit stem must be non-empty, at most 128 characters, "
                  "start with an ASCII letter or digit, and contain only "
                  "ASCII letters, digits, '.', '_' or '-'")


def is_valid_unit_stem(stem) -> bool:
    """True iff `stem` may name a unit seed file / unit estate directory.

    Stems are corpus-derived (sample_id, question_id, tid path ...). The
    measurement harness joins a stem under its fleet directory and
    interpolates that path into the serve launch command, which its stdio
    launcher splits on whitespace. The rule is therefore deliberately
    narrow — non-empty, at most UNIT_STEM_MAX_LEN bytes, first character an
    ASCII letter or digit, later characters ASCII letters, digits, '.',
    '_' or '-', never '.' or '..' — so a valid stem is exactly one plain
    path component and one launch-command token. The harness applies the
    same rule (Swift isValidUnitStem, Rust is_valid_unit_stem), and the
    ports pin the same literal vectors in their tests.
    """
    if not isinstance(stem, str) or not stem:
        return False
    if len(stem.encode("utf-8")) > UNIT_STEM_MAX_LEN:
        return False
    if stem in (".", ".."):
        return False
    if stem[0] not in _UNIT_STEM_ALNUM:
        return False
    return all(c in _UNIT_STEM_CHARS for c in stem)


def require_unit_stem(stem, source_id) -> str:
    """Return `stem` if valid, else exit non-zero naming the offending id.

    Called before any unit filename is written: a corpus that smuggles a
    path or a launch-command token into an id stops the build here, never
    produces a file.
    """
    if not is_valid_unit_stem(stem):
        sys.exit(f"error: unit stem {stem!r} derived from id {source_id!r} "
                 f"is not a valid unit stem: {UNIT_STEM_RULE}")
    return stem


def emit_seed(path: Path, name: str, records, facts=None, tunnels=None):
    # Defensive subject normalization (mirrors the Swift emitter): single
    # line, collapsed whitespace, trimmed — the importer rejects the whole
    # file on one leading/trailing-whitespace subject.
    for r in records:
        s = " ".join(str(r.get("subject", "")).split())
        r["subject"] = s[:120].strip()
    doc = {"format_version": 1, "name": name, "records": records}
    if facts:
        doc["facts"] = facts
    if tunnels:
        doc["tunnels"] = tunnels
    path.write_text(json.dumps(doc, ensure_ascii=False, indent=1))


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixture", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=5,
                    help="how many per-instance unit files to write")
    args = ap.parse_args()

    data = json.loads(Path(args.fixture).read_text())
    out = Path(args.out)
    (out / "units").mkdir(parents=True, exist_ok=True)

    agg_records = {}          # session_id -> record (first-seen wins)
    agg_persona = {}          # session_id -> persona of first-seen instance
    dup_hits = 0
    room_counts = Counter()
    questions = []
    projection_units = {}       # qid -> unit records, for emit_projection
    projection_questions = []   # unit / question_id / gold_ids

    for idx, inst in enumerate(data):
        persona = persona_for(idx)
        unit_records = []
        unit_seen = set()   # a haystack can reference the same session twice
        for s_idx, session in enumerate(inst["haystack_sessions"]):
            if not session:
                continue
            sid = inst["haystack_session_ids"][s_idx]
            if sid in unit_seen:
                dup_hits += 1
                continue
            unit_seen.add(sid)
            rec = session_record(session, sid, inst["haystack_dates"][s_idx], persona)
            unit_records.append(rec)
            if sid in agg_records:
                dup_hits += 1
            else:
                agg_records[sid] = rec
                agg_persona[sid] = persona
                room_counts[rec["room"]] += 1

        # The unit stem IS the question id (units/<qid>.json); every id is
        # checked, not only the first --limit that get a unit file.
        qid = require_unit_stem(inst["question_id"], inst["question_id"])
        questions.append({
            "question_id": qid,
            "question_type": inst["question_type"],
            "persona": persona,
            "question": inst["question"],
            "question_3p": rewrite_question(inst["question"], persona),
            "question_date": parse_lme_date(inst["question_date"]),
            "answer": inst["answer"],
            "answer_session_ids": inst["answer_session_ids"],
        })

        if idx < args.limit:
            emit_seed(out / "units" / f"{qid}.json",
                      f"lme-s-{qid}", unit_records)
            projection_units[qid] = unit_records
            projection_questions.append({
                "unit": qid, "question_id": f"{qid}/q1",
                "gold_ids": list(inst["answer_session_ids"])})

    emit_seed(out / "aggregate.json", "lme-s-aggregate",
              list(agg_records.values()))
    with (out / "questions.jsonl").open("w") as f:
        for q in questions:
            f.write(json.dumps(q, ensure_ascii=False) + "\n")
    # Haystacks share filler sessions across instances: the aggregate is the
    # dedup'd union, so the builder must skip ids already present (overlap).
    emit_projection(out, dataset="lme-s", room_rule=room_rule_text(sys.modules[__name__]),
                    overlap=True, units=projection_units,
                    questions=projection_questions, shape="session")

    total_refs = sum(
        sum(1 for s in inst["haystack_sessions"] if s) for inst in data)
    print(f"instances: {len(data)}")
    print(f"session references: {total_refs}")
    print(f"unique sessions (aggregate drawers): {len(agg_records)}")
    print(f"duplicate references collapsed: {dup_hits}")
    shared = Counter()
    for inst in data:
        for s_idx, s in enumerate(inst["haystack_sessions"]):
            if s:
                shared[inst["haystack_session_ids"][s_idx]] += 1
    multi = sum(1 for c in shared.values() if c > 1)
    print(f"sessions appearing in >1 instance: {multi} "
          f"(max reuse {max(shared.values())})")
    print("\nroom distribution (aggregate):")
    for room, n in room_counts.most_common():
        print(f"  {room:10s} {n:6d}  {100*n/len(agg_records):5.1f}%")
    print(f"\nwrote {min(args.limit, len(data))} unit files, aggregate.json, "
          f"questions.jsonl, projection/ -> {out}")


if __name__ == "__main__":
    main()

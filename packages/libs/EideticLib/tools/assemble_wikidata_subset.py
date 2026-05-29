#!/usr/bin/env python3
"""
assemble_wikidata_subset.py

Assembles EideticLib's Wikidata subset by hitting the Wikidata
REST API directly (wbsearchentities + wbgetentities) rather
than the SPARQL endpoint. The REST API is faster and more
reliable than WDQS for this use case, since we want bounded
lookups (one search per UDC code, one entity fetch per
candidate) rather than open-ended subclass traversals.

Section A: UDC-anchor mapping. For each code in the
UDCSchedule.json, search Wikidata for the canonical concept
using the gazetteer terms, pick the best candidate by
sitelink count and description-vs-UDC-label alignment.

Section B: stratified common-knowledge entities. For each
non-vacant UDC main class, search Wikidata for entities
related to a small set of seed terms drawn from the schedule's
gazetteer, take the top-N by sitelinks per class.

The output replaces WikidataSubset.json in place. The
schema and field shapes are identical to the synthetic
version, so the resolver code and the rest of the kit work
without modification.

License: the script ships under the kit's MIT-or-Apache code
license. The output JSON ships under CC0 (Wikidata's
dedication for label and Q-ID data).
"""

import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Optional


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
UDC_SCHEDULE = (
    REPO_ROOT
    / "EideticLib"
    / "Sources"
    / "EideticLib"
    / "Resources"
    / "UDCSchedule.json"
)
OUTPUT_PATH = (
    REPO_ROOT
    / "EideticLib"
    / "Sources"
    / "EideticLib"
    / "Resources"
    / "WikidataSubset.json"
)

USER_AGENT = (
    "EideticLib/0.1 data-assembly (MOOTx01; "
    "https://github.com/bob-codedaptive/mootx01)"
)
WBSEARCH_ENDPOINT = "https://www.wikidata.org/w/api.php"
WBGETENTITIES_ENDPOINT = "https://www.wikidata.org/w/api.php"


def http_get_json(url: str, timeout: int = 15) -> Optional[dict]:
    req = urllib.request.Request(
        url, headers={"User-Agent": USER_AGENT}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except Exception as exc:
        print(f"    HTTP error: {exc}", file=sys.stderr)
        return None


def wbsearch(query: str, limit: int = 10) -> list[dict]:
    url = WBSEARCH_ENDPOINT + "?" + urllib.parse.urlencode({
        "action": "wbsearchentities",
        "search": query,
        "language": "en",
        "limit": str(limit),
        "type": "item",
        "format": "json",
    })
    data = http_get_json(url)
    return data.get("search", []) if data else []


def wbget_entity(qid: str) -> Optional[dict]:
    """Fetch a single entity. Returns dict with keys: qid,
    label, aliases (list of strings), sitelinks_count."""
    url = WBGETENTITIES_ENDPOINT + "?" + urllib.parse.urlencode({
        "action": "wbgetentities",
        "ids": qid,
        "props": "labels|aliases|sitelinks",
        "languages": "en",
        "format": "json",
    })
    data = http_get_json(url)
    if not data:
        return None
    entities = data.get("entities", {})
    ent = entities.get(qid)
    if not ent:
        return None
    label = (
        ent.get("labels", {})
        .get("en", {})
        .get("value", "")
    )
    aliases_raw = ent.get("aliases", {}).get("en", [])
    aliases = [a.get("value", "") for a in aliases_raw if a.get("value")]
    sitelinks = ent.get("sitelinks", {})
    return {
        "qid": qid,
        "label": label,
        "aliases": aliases,
        "sitelinks_count": len(sitelinks),
    }


def is_likely_concept_for(
    candidate: dict,
    udc_label: str,
    udc_description: str,
) -> bool:
    """Heuristic: is this Wikidata entity a plausible canonical
    concept for the UDC code? We reject entities whose search
    description mentions things like 'journal', 'magazine',
    'album', 'film', 'song', 'novel', or 'category' since those
    are specific works rather than topic concepts."""
    desc = (candidate.get("description") or "").lower()
    EXCLUDE_TYPES = (
        "journal", "magazine", "newspaper",
        "album", "film", "song", "novel",
        "movie", "tv series", "video game",
        "wikimedia", "disambiguation",
        "manga", "anime",
    )
    return not any(et in desc for et in EXCLUDE_TYPES)


def resolve_udc_anchor(
    code: str,
    schedule_label: str,
    schedule_description: str,
    gazetteer_terms: list[str],
) -> Optional[dict]:
    """Pick the canonical Wikidata Q-ID for a UDC code.

    Strategy: search Wikidata using the first gazetteer term
    (usually the most specific topic name), filter out entities
    that look like specific works (journals, songs, etc),
    fetch full details for top candidates, and pick the best.

    Ranking: candidates whose Wikidata label exactly matches
    the search term beat those that don't (this prevents the
    "religion" search from picking Q432 Islam over Q9174
    Religion). Among label-matching candidates, the most-
    sitelinked wins. If no candidate label-matches, fall back
    to most-sitelinked overall."""
    if not gazetteer_terms:
        return None
    search_term = gazetteer_terms[0]
    search_lower = search_term.lower()
    print(f"  UDC {code} ({schedule_label}) -> searching '{search_term}'")
    hits = wbsearch(search_term, limit=10)
    if not hits:
        print(f"    no wbsearch hits")
        return None

    candidates = [
        h for h in hits if is_likely_concept_for(
            h, schedule_label, schedule_description
        )
    ]
    if not candidates:
        candidates = hits

    enriched: list[dict] = []
    for hit in candidates[:5]:
        qid = hit.get("id", "")
        if not qid.startswith("Q"):
            continue
        details = wbget_entity(qid)
        if details:
            details["description"] = hit.get("description", "")
            enriched.append(details)
        time.sleep(0.1)

    if not enriched:
        return None

    # Sort: exact label match (case-insensitive) first, then
    # by sitelinks descending. This makes "religion" prefer
    # Q9174 (label "religion") over Q432 (label "Islam").
    def sort_key(c):
        label_match = c["label"].lower() == search_lower
        return (0 if label_match else 1, -c["sitelinks_count"])

    enriched.sort(key=sort_key)
    best = enriched[0]
    print(
        f"    chose {best['qid']} ({best['label']}, "
        f"{best['sitelinks_count']} sitelinks)"
    )
    return best


def assemble_section_a(udc_schedule: dict) -> list[dict]:
    print("\n=== Section A: UDC-anchor mappings ===\n")
    entries: list[dict] = []
    for code_entry in udc_schedule["codes"]:
        code = code_entry["code"]
        terms = code_entry.get("gazetteer_terms", [])
        if not terms:
            continue
        resolved = resolve_udc_anchor(
            code,
            code_entry.get("label", ""),
            code_entry.get("description", ""),
            terms,
        )
        if resolved is None:
            continue
        entries.append({
            "qid": resolved["qid"],
            "label": resolved["label"].lower(),
            "aliases": [a.lower() for a in resolved["aliases"]],
            "udc_hint": code,
            "source_section": "udc_anchor",
        })
        time.sleep(0.2)
    return entries


def assemble_section_b(
    udc_schedule: dict,
    section_a_entries: list[dict],
    per_class_target: int = 200,
) -> list[dict]:
    """For each non-vacant UDC main class, pull additional
    entities via wbsearch on the class's seed terms (drawn
    from the schedule's gazetteer for that class and its
    sub-classes). De-dupe against section A."""
    print("\n=== Section B: stratified common-knowledge ===\n")

    seen_qids: set[str] = {e["qid"] for e in section_a_entries}
    entries: list[dict] = []

    # Pull seed terms per main class from the schedule itself:
    # the gazetteer terms of all codes in the class.
    class_seeds: dict[str, list[str]] = {}
    for entry in udc_schedule["codes"]:
        code = entry["code"]
        main_class = code[0] if code else ""
        if not main_class or main_class == "4":
            continue
        for term in entry.get("gazetteer_terms", []):
            class_seeds.setdefault(main_class, []).append(term)

    for main_class in sorted(class_seeds.keys()):
        seeds = class_seeds[main_class]
        # Take more seeds per class than v0.1 (was 15, now 40)
        # to broaden coverage.
        seeds = seeds[:40]
        print(f"  Class {main_class}: {len(seeds)} seeds")
        class_count = 0
        for seed in seeds:
            if class_count >= per_class_target:
                break
            hits = wbsearch(seed, limit=10)
            for hit in hits:
                if class_count >= per_class_target:
                    break
                qid = hit.get("id", "")
                if not qid.startswith("Q") or qid in seen_qids:
                    continue
                if not is_likely_concept_for(hit, "", ""):
                    continue
                label = hit.get("label", "").lower()
                if not label:
                    continue
                seen_qids.add(qid)
                entries.append({
                    "qid": qid,
                    "label": label,
                    "aliases": [],  # backfill in alias pass
                    "udc_hint": main_class,
                    "source_section": "common_knowledge",
                })
                class_count += 1
            time.sleep(0.15)
        print(f"    class {main_class}: took {class_count}")

    return entries


def enrich_aliases(
    entries: list[dict],
    max_to_enrich: int = 200,
) -> None:
    print(f"\n=== Aliases (up to {max_to_enrich} entries) ===\n")
    enriched = 0
    for entry in entries:
        if enriched >= max_to_enrich:
            break
        if entry.get("aliases"):
            continue
        details = wbget_entity(entry["qid"])
        if details and details.get("aliases"):
            entry["aliases"] = [a.lower() for a in details["aliases"]]
            enriched += 1
        time.sleep(0.1)
    print(f"  Enriched aliases on {enriched} entries")


def deduplicate_and_clean(entries: list[dict]) -> list[dict]:
    """Drop entries with empty labels and dedupe Q-IDs, preferring
    udc_anchor entries over common_knowledge when both share a
    Q-ID. This keeps each entity's strongest UDC association while
    eliminating the conformance-breaking duplicates."""
    # Drop empty labels.
    cleaned = [e for e in entries if e["label"].strip()]

    # Dedupe by Q-ID. Section A wins ties.
    priority = {"udc_anchor": 0, "common_knowledge": 1}
    seen: dict[str, dict] = {}
    for entry in cleaned:
        qid = entry["qid"]
        existing = seen.get(qid)
        if existing is None:
            seen[qid] = entry
            continue
        if priority.get(entry["source_section"], 99) < priority.get(
            existing["source_section"], 99
        ):
            seen[qid] = entry

    return list(seen.values())


def main() -> int:
    print(f"Loading UDC schedule from {UDC_SCHEDULE}")
    schedule = json.loads(UDC_SCHEDULE.read_text())
    print(f"  {len(schedule['codes'])} UDC entries loaded")

    section_a = assemble_section_a(schedule)
    section_b = assemble_section_b(schedule, section_a)
    all_entries = section_a + section_b
    print(
        f"\nAssembled {len(all_entries)} entries "
        f"({len(section_a)} section A + {len(section_b)} section B)"
    )

    all_entries = deduplicate_and_clean(all_entries)
    print(
        f"After dedup and cleanup: {len(all_entries)} entries"
    )

    enrich_aliases(all_entries, max_to_enrich=300)

    output = {
        "schema_version": "1",
        "data_version": "0.1.0",
        "source_notes": (
            "Wikidata Q-IDs assembled by "
            "EideticLib/tools/assemble_wikidata_subset.py via the "
            "Wikidata REST API (wbsearchentities + "
            "wbgetentities). Section A: one entry per code in "
            "UDCSchedule.json v0.1.0, found by searching the "
            "first gazetteer term and ranked by Wikidata "
            "sitelinks count after filtering out specific-work "
            "candidates (journals, films, albums, etc). Section "
            "B: stratified by UDC main class, drawn from "
            "gazetteer-term searches across each class's "
            "constituent codes. Aliases backfilled on the first "
            "300 entries. Re-runnable; mild drift is expected as "
            "Wikidata evolves."
        ),
        "license_note": (
            "Creative Commons CC0 1.0 Universal, matching "
            "Wikidata's own dedication. No attribution required, "
            "no share-alike clause."
        ),
        "entries": all_entries,
    }

    OUTPUT_PATH.write_text(
        json.dumps(output, indent=2, ensure_ascii=False) + "\n"
    )
    print(f"\nWrote {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

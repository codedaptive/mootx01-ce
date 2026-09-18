#!/usr/bin/env python3
"""Portable, deterministic record-shape classification for mint routing.

This is deliberately not a semantic or quality classifier.  It measures only
observable document topology (speaker turns, dated lines, bullets, headings,
and dense scalar fields) and returns multi-label evidence.  Model-specific
policy is a separate layer: the classifier never sees record identifiers,
expected outputs, or benchmark pass/fail results.

All runtime decisions use integer counts and ratios expressed as percentages
so Swift and Rust ports can reproduce them byte-for-byte without an ML runtime.
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
import re


TAG_LINE = re.compile(r"^\s*([A-Za-z][A-Za-z0-9_ -]{0,23}):\s*(.*)$")
DATE_LEAD = re.compile(
    r"^\s*(?:\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?"
    r"|\d{1,2}[/-]\d{1,2}[/-]\d{2,4})\b"
)
BULLET_LEAD = re.compile(r"^\s*(?:[-*+]\s+|\d+[.)]\s+)")
HEADING_LEAD = re.compile(
    r"^\s*(?:chapter|section|part|act|scene|title|book summary)\b",
    re.IGNORECASE,
)
DATE_ANY = re.compile(
    r"\b(?:\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?"
    r"|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4})\b"
)
NUMBER_ANY = re.compile(r"\b\d+(?:[.,]\d+)?\b")
EMAIL = re.compile(r"\b[^\s@]+@[^\s@]+\.[^\s@]+\b")
KNOWN_SPEAKERS = {
    "user", "assistant", "human", "system", "customer", "agent",
    "interviewer", "interviewee", "speaker", "participant",
}


def _pct(numerator: int, denominator: int) -> int:
    return 0 if denominator <= 0 else numerator * 100 // denominator


@dataclass(frozen=True)
class ShapeDecision:
    """Content-only structural classification with auditable evidence."""

    primary: str
    labels: tuple[str, ...]
    scores: dict[str, int]
    features: dict[str, int]
    confidence_margin: int

    def has(self, label: str) -> bool:
        return label in self.labels

    def as_dict(self) -> dict:
        return {
            "primary": self.primary,
            "labels": list(self.labels),
            "scores": dict(self.scores),
            "features": dict(self.features),
            "confidence_margin": self.confidence_margin,
        }


def classify_record(content: str) -> ShapeDecision:
    """Classify record topology without using corpus or outcome knowledge."""

    lines = [line for line in content.splitlines() if line.strip()]
    line_count = max(1, len(lines))

    tags: list[str] = []
    known_speaker_lines = 0
    for line in lines:
        match = TAG_LINE.match(line)
        if not match:
            continue
        tag = match.group(1).strip().lower()
        tags.append(tag)
        if tag in KNOWN_SPEAKERS or tag.startswith("speaker "):
            known_speaker_lines += 1

    tag_counts = Counter(tags)
    top2_tag_lines = sum(count for _, count in tag_counts.most_common(2))
    tag_switches = sum(1 for left, right in zip(tags, tags[1:]) if left != right)

    date_lead_lines = sum(bool(DATE_LEAD.match(line)) for line in lines)
    bullet_lines = sum(bool(BULLET_LEAD.match(line)) for line in lines)
    heading_lines = sum(bool(HEADING_LEAD.match(line)) for line in lines)
    pipe_parts = len([part for part in re.split(r"\s+\|\s+", content)
                      if part.strip()])
    pipe_date_parts = sum(bool(DATE_LEAD.match(part)) for part in
                          re.split(r"\s+\|\s+", content) if part.strip())
    date_mentions = len(DATE_ANY.findall(content))
    number_mentions = len(NUMBER_ANY.findall(content))
    email_mentions = len(EMAIL.findall(content))
    average_line_chars = len(content) // line_count

    features = {
        "chars": len(content),
        "lines": len(lines),
        "tag_lines": len(tags),
        "distinct_tags": len(tag_counts),
        "known_speaker_lines": known_speaker_lines,
        "tag_line_pct": _pct(len(tags), line_count),
        "top2_tag_pct": _pct(top2_tag_lines, len(tags)),
        "tag_switch_pct": _pct(tag_switches, max(1, len(tags) - 1)),
        "date_lead_lines": date_lead_lines,
        "date_lead_pct": _pct(date_lead_lines, line_count),
        "bullet_lines": bullet_lines,
        "bullet_line_pct": _pct(bullet_lines, line_count),
        "heading_lines": heading_lines,
        "pipe_parts": pipe_parts,
        "pipe_date_parts": pipe_date_parts,
        "date_mentions": date_mentions,
        "number_mentions": number_mentions,
        "email_mentions": email_mentions,
        "average_line_chars": average_line_chars,
    }

    scores = {"dialogue": 0, "timeline": 0, "outline": 0,
              "entity_dense": 0, "prose": 0}

    # Dialogue requires repeated speaker structure, not merely colon-headed
    # lines.  Known user/assistant labels are strong evidence, while arbitrary
    # character names can still qualify through repetition and alternation.
    if len(tags) >= 4:
        scores["dialogue"] += 5
    if features["tag_line_pct"] >= 25:
        scores["dialogue"] += 2
    if features["top2_tag_pct"] >= 60:
        scores["dialogue"] += 4
    if features["tag_switch_pct"] >= 50:
        scores["dialogue"] += 2
    if known_speaker_lines >= 2:
        scores["dialogue"] += 4

    if date_lead_lines >= 3:
        scores["timeline"] += 7
    if features["date_lead_pct"] >= 25:
        scores["timeline"] += 4
    if pipe_date_parts >= 3:
        scores["timeline"] += 5
    if date_mentions >= 5:
        scores["timeline"] += 2

    if bullet_lines >= 3:
        scores["outline"] += 7
    if features["bullet_line_pct"] >= 20:
        scores["outline"] += 4
    if heading_lines >= 2:
        scores["outline"] += 4
    if pipe_parts >= 5:
        scores["outline"] += 3

    scalar_mentions = date_mentions + number_mentions + email_mentions
    if scalar_mentions >= 8:
        scores["entity_dense"] += 5
    if scalar_mentions * 1000 // max(1, len(content)) >= 3:
        scores["entity_dense"] += 3
    if email_mentions:
        scores["entity_dense"] += 2

    if len(lines) <= 4:
        scores["prose"] += 4
    if average_line_chars >= 120:
        scores["prose"] += 3
    if not tags and not date_lead_lines and not bullet_lines:
        scores["prose"] += 4

    active = [label for label, score in scores.items() if score >= 6]
    structural = [label for label in ("dialogue", "timeline", "outline")
                  if label in active]
    if not active:
        active = ["prose"]

    ranked = sorted(active, key=lambda label: (-scores[label], label))
    if len(structural) >= 2:
        primary = "hybrid"
        labels = ("hybrid", *ranked)
    else:
        primary = ranked[0]
        labels = tuple(ranked)

    ordered_scores = sorted(scores.values(), reverse=True)
    margin = ordered_scores[0] - ordered_scores[1]
    return ShapeDecision(primary=primary, labels=labels, scores=scores,
                         features=features, confidence_margin=margin)


def nuextract_method_order(decision: ShapeDecision) -> tuple[str, ...]:
    """Rank same-model NuExtract templates from structural evidence."""

    if decision.has("timeline"):
        return ("timeline", "documentary", "conversation", "compact")
    # Documentary evidence wins hybrid records with outlines/timelines; the
    # conversation template remains the deterministic second attempt.
    documentary_score = max(decision.scores["timeline"],
                            decision.scores["outline"],
                            decision.scores["entity_dense"],
                            decision.scores["prose"])
    dialogue_score = decision.scores["dialogue"]
    first_two = (("conversation", "documentary")
                 if dialogue_score > documentary_score
                 else ("documentary", "conversation"))
    # The compact scalar template is a final same-model method for short or
    # thin documents; policy may omit it for long inputs.
    return (*first_two, "compact")


def qwen3_method_order(decision: ShapeDecision) -> tuple[str, ...]:
    """Rank same-model Qwen3 framings from structural evidence."""

    repetitive = any(decision.has(label)
                     for label in ("dialogue", "timeline", "outline", "hybrid"))
    first_two = (("reframed", "standard") if repetitive
                 else ("standard", "reframed"))
    if (decision.has("dialogue")
            and decision.scores["dialogue"] > decision.scores["outline"]):
        return (first_two[0], "dialogue_facts", first_two[1], "json_chunks")
    return (*first_two, "json_chunks")

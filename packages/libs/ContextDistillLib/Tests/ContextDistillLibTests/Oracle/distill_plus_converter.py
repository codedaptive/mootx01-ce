#!/usr/bin/env python3
"""Offline deterministic distillation candidates for Model-Plus experiments.

This tool is deliberately outside the MOOT distillation/dream lifecycle.  It
opens an estate read-only, derives four attributed representations, and writes
sidecar JSONL overlays.  It never writes an estate and never invokes a model.

Candidate contracts:

* ``p23-current`` preserves the estate's stored p2.3 representation.
* ``p23-core`` reproduces p2.3's capitalization-feature recurrence test but
  omits the episodic tail that production currently appends.
* ``freq-mmr`` selects mechanically scored semantic units under a fixed budget
  with mandatory integer token-overlap redundancy suppression.
* ``intent-span`` selects complete, exact source atoms around operative intent
  and dependency-closed document structure without rewriting their contents.
* ``intent-span-v23`` preserves the frozen v22 behavior and adds a symmetric
  peer-dialogue lane for transcripts whose speakers use ordinary names.
* ``intent-span-v23-attributed`` renders that exact selection as inline
  attributed prose so miners do not see an alternating chat-log topology.

The existing enrichment trailer is split from the stored p2.3 representation.
The first three candidates append it unchanged.  ``intent-span`` retains that
raw trailer for audit but applies only fields that are source-anchored and safe
for their declared type.  The converter never regenerates enrichment from the
reduced text.
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
from typing import Iterable, Sequence
from urllib.parse import quote

from blind200_manifest import load_manifest
from record_shape_classifier import (
    BULLET_LEAD,
    DATE_LEAD,
    HEADING_LEAD,
    KNOWN_SPEAKERS,
    TAG_LINE,
    ShapeDecision,
    classify_record,
)


CONVERTER_VERSION = "distill-plus-v1"
RULESET_VERSION = "mechanical-v8-scoring-corrections"
CANDIDATES = (
    "p23-current", "p23-core", "freq-mmr", "intent-span",
    "intent-span-v23", "intent-span-v23-attributed",
)
INTENT_SPAN_VERSION = "intent-span-v22-authority-closure"
INTENT_SPAN_V23_VERSION = "intent-span-v23-peer-dialogue"
INTENT_SPAN_V23_ATTRIBUTED_VERSION = "intent-span-v23.2-attributed-prose"

# Debug-7 membership is structural test-bed configuration, never an input to
# classification or reduction.  Prefix matching mirrors protocol_lab.py.
DEBUG7_PREFIXES = (
    "8B891FB8", "0277CF4B", "A5C46986", "1A976AE7", "D0947A73",
    "BDCA9D1E", "A1ADADBD",
)

TRAILER_RE = re.compile(r"(?P<trailer>\s+\(\*\[\s.*?\s\]\*\))\s*$", re.DOTALL)
PIPE_SPLIT_RE = re.compile(r"\s+\|\s+")
INLINE_NUMBERED_RE = re.compile(r"(?:^|\s)(?P<marker>\d+[.)]\s+)")
LIST_MARKER_RE = re.compile(r"^\s*(?:[-*+•]|\d+[.)])\s+")
WORD_RE = re.compile(r"[A-Za-z0-9]+(?:['-][A-Za-z0-9]+)*")
NUMBER_RE = re.compile(r"\b\d+(?:[.,]\d+)?\b")
DATE_RE = re.compile(
    r"\b(?:\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?"
    r"|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4})\b"
)
CAPITALIZED_RE = re.compile(r"\b[A-Z][A-Za-z0-9_-]+\b")

# This is the portable subset of TokenCompaction v1 plus experiment-specific
# conversational scaffolding.  Negation, quantifiers, modals, dates, entities,
# and numbers are intentionally absent from the drop set.
STOPWORDS = frozenset({
    "really", "very", "quite", "actually", "basically",
    "literally", "honestly", "frankly", "anyway", "please",
})
SCORING_STOPWORDS = STOPWORDS | frozenset({
    "a", "an", "the", "and", "as", "at", "be", "been", "being", "by", "for", "from", "in",
    "of", "on", "or", "that", "this", "to", "was", "were", "with", "you",
    "your", "we", "our", "they", "their", "it", "its", "i", "my", "me",
})
PHRASE_REWRITES = (
    ("due to the fact that", "because"),
    ("at this point in time", "now"),
    ("in the event that", "if"),
    ("as a result of", "because of"),
    ("with regard to", "regarding"),
    ("in order to", "to"),
    ("make sure to", ""),
    ("kind of", ""),
    ("sort of", ""),
    ("of course", ""),
)
GREETING_PREFIX_RE = re.compile(
    r"^\s*(?:(?:hi|hello|hey|good morning|good afternoon|good evening)"
    r"(?:\s+there)?[!,.\s]*|(?:thanks|thank you)(?:\s+so much)?[!,.\s]+)",
    re.IGNORECASE,
)
GREETING_ONLY_RE = re.compile(
    r"^\s*(?:hi|hello|hey|good morning|good afternoon|good evening|thanks|"
    r"thank you|bye|goodbye)(?:\s+(?:there|for now|so much))?[!,.\s]*$",
    re.IGNORECASE,
)
DIALOGUE_FILLER_ONLY_RE = re.compile(
    r"^\s*(?:exactly|precisely|absolutely|sure|right|okay|ok|"
    r"oh[, ]+tell me about it|that(?:'s| is) (?:great|wonderful|lovely|"
    r"fantastic)(?: to hear)?)[!.\s]*$",
    re.IGNORECASE,
)
REVISION_MARKER_RE = re.compile(
    r"\b(?:revised|updated|final)\s+(?:chapter\s+)?(?:outline|draft|plan|version)\b",
    re.IGNORECASE,
)
INITIAL_DRAFT_MARKER_RE = re.compile(
    r"\b(?:first|initial|original)\s+(?:chapter\s+)?"
    r"(?:outline|draft|plan|version)\b",
    re.IGNORECASE,
)
ACTION_WORDS = frozenset({
    "agreed", "approved", "assigned", "build", "built", "cancel", "changed",
    "choose", "decided", "deliver", "due", "failed", "fixed", "launch",
    "must", "need", "planned", "prefer", "preferred", "prefers",
    "preference", "favorite", "routine", "regularly", "usually", "required",
    "ship", "shipped", "should", "started", "stop", "will", "won't",
})
COREF_EXCLUSIONS = frozenset({
    "Assistant", "User", "Human", "System", "Chapter", "Section", "Part",
    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    "Sunday", "January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December",
})

KNOWN_USER_SPEAKERS = frozenset({"user", "human", "customer", "interviewer"})
KNOWN_ANSWER_SPEAKERS = frozenset({
    "assistant", "agent", "system", "interviewee",
})
PEER_FIELD_LABELS = frozenset({
    "address", "country", "date", "email", "entity", "id", "location",
    "name", "notes", "phone", "place", "quantity", "status", "subject",
    "title", "type",
})
OPERATIVE_RE = re.compile(
    r"^\s*(?:please\s+)?(?:amend|analy[sz]e|answer|check|compare|convert|"
    r"describe|determine|edit|explain|extract|find|identify|list|review|"
    r"revise|show|summarize|tell|update|verify|write)\b",
    re.IGNORECASE,
)
TURN_FILLER_RE = re.compile(
    r"^\s*(?:acknowledged|noted|received|ok(?:ay)?|sure|thanks|thank you|got it|understood|"
    r"sounds good|great|perfect|exactly|absolutely|you(?:'re| are) welcome)"
    r"[.!\s]*$",
    re.IGNORECASE,
)
ASSISTANT_BOILERPLATE_RE = re.compile(
    r"^\s*(?:certainly|sure|of course)[.!,:\s]*(?:i(?:'d| will) be happy to)?"
    r"\s*$|^\s*i hope this helps[.!?\s]*$|"
    r"^\s*let me know if you (?:have|need)(?: any)? "
    r"(?:questions|anything(?: else)?)[.!?\s]*$",
    re.IGNORECASE | re.DOTALL,
)
EMBEDDED_USER_FACT_RE = re.compile(
    r"(?:^|\n).*?(?P<fact>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}[^\n]*?"
    r"\s[—-]\s*user:\s*[^\n]+)",
    re.IGNORECASE,
)
FENCE_OPEN_RE = re.compile(r"^\s*(`{3,}|~{3,})")
MARKDOWN_HEADING_RE = re.compile(r"^(?P<marks>#{1,6})\s+\S")
BOLD_HEADING_RE = re.compile(r"^\s*\*\*[^*\n]{1,120}\*\*\s*:?[ \t]*$")
FIELD_LINE_RE = re.compile(
    r"^\s*[A-Za-z][A-Za-z0-9 _./()-]{0,80}:\s*\S"
)
TABLE_SEPARATOR_RE = re.compile(
    r"^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$"
)
DIAGRAM_RE = re.compile(r"[\u2500-\u257f]|(?:--?>|==>|<--?)")
LOCATIVE_CUE = (
    r"(?:in|at|from|to|near|around|inside|outside|visit(?:ed|ing)?|"
    r"located|based|live[sd]?|moved|travel(?:led|ed|ing)?)"
)
ENTITY_CUE = r"(?:called|named|project|company|person|store|city|brand|organization)"
ENTITY_SUBJECT_CUE = (
    r"(?:agreed|approved|asked|attended|bought|chose|decided|discovered|"
    r"joined|lives|moved|ordered|owns|planned|prefers|said|shipped|works)"
)
ENTITY_NON_NAME_PREFIXES = frozenset({
    "analyze", "answer", "check", "compare", "convert", "describe",
    "determine", "explain", "extract", "find", "identify", "list",
    "please", "provide", "review", "show", "summarize", "tell", "verify",
    "write",
})
ENTITY_NON_NAME_VALUES = frozenset({
    "absolutely", "acknowledged", "certainly", "correct", "exactly",
    "got it", "great", "hello", "no", "noted", "okay", "perfect",
    "received", "right", "sounds good", "sure", "thanks",
    "thank you", "understood", "yes", "you're welcome", "you are welcome",
})
QUERY_STOPWORDS = SCORING_STOPWORDS | frozenset({
    "answer", "analyze", "check", "compare", "convert", "describe",
    "document", "explain", "extract", "find", "following", "identify",
    "list", "question", "review", "show", "summarize", "tell", "text",
    "verify", "write",
})
POLARITY_ONLY_RE = re.compile(r"^\s*(?:yes|no)\b[.!?\s]*$", re.IGNORECASE)
TRANSFORM_FOLLOWUP_RE = re.compile(
    r"\b(?:adapt|convert|make|port|rewrite|translate|turn)\b[^\n]{0,120}"
    r"\b(?:answer|code|example|function|it|that|this)\b|"
    r"\b(?:answer|code|example|function|it|that|this)\b[^\n]{0,120}"
    r"\b(?:adapt|convert|make|port|rewrite|translate|turn)\b",
    re.IGNORECASE,
)
QUANTITY_VALUE_RE = re.compile(
    r"^[€£$]?\d+(?:[.,]\d+)?(?:\s+[A-Za-z%][A-Za-z0-9%._/-]*){0,3}$"
)
ABBREVIATIONS = frozenset({
    "dr", "e.g", "i.e", "jr", "mr", "mrs", "ms", "prof", "sr", "u.s",
    "u.k", "vs",
})


@dataclass(frozen=True)
class SemanticUnit:
    """One original-source unit with stable character offsets."""

    index: int
    start: int
    end: int
    text: str
    kind: str
    speaker: str | None = None


@dataclass(frozen=True)
class EstateRecord:
    drawer_id: str
    content: str
    distilled: str
    event_time: str | None


@dataclass(frozen=True)
class IntentAtom:
    """An indivisible, exact source span used by ``intent-span``."""

    atom_id: int
    start: int
    end: int
    text: str
    kind: str
    speaker: str | None = None
    dependencies: tuple[int, ...] = ()
    hard_required: bool = False


@dataclass(frozen=True)
class SpeakerTurn:
    start: int
    end: int
    first_line_end: int
    body_start: int
    speaker: str


def source_digest(content: str) -> str:
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


def estimate_tokens(text: str) -> int:
    """Mirror TokenCompaction's deterministic advisory estimator."""

    words = text.split()
    if not words:
        return 0
    return (3 * len(text.encode("utf-8")) + 16 * len(words) + 12) // 24


def split_enrichment(distilled: str) -> tuple[str, str]:
    """Return stored rendering body and exact grammar-v1 trailer."""

    match = TRAILER_RE.search(distilled)
    if not match:
        return distilled.strip(), ""
    return distilled[:match.start()].rstrip(), match.group("trailer").strip()


def _line_spans(text: str) -> list[tuple[int, int, str]]:
    spans: list[tuple[int, int, str]] = []
    for match in re.finditer(r"[^\n]+", text):
        raw = match.group(0)
        left = len(raw) - len(raw.lstrip())
        right = len(raw.rstrip())
        if right > left:
            spans.append((match.start() + left, match.start() + right,
                          raw[left:right]))
    return spans


def _period_is_abbreviation(text: str, index: int) -> bool:
    prefix = text[max(0, index - 24):index + 1]
    # A numbered item marker is not a one-token sentence.  This matters when
    # the first item shares a physical line with a pinned speaker label, for
    # example ``Assistant: 1. WASH programs ...``.  Keeping the marker with
    # its text lets answer-list coverage treat item 1 like later items.
    line_prefix = text[text.rfind("\n", 0, index) + 1:index + 1]
    if re.fullmatch(
            r"\s*(?:[A-Za-z][A-Za-z ]{0,24}:\s*)?\d+\.", line_prefix):
        following = text[index + 1:].lstrip()
        if following:
            return True
    if re.search(r"(?:\b[A-Za-z]\.){2,}$", prefix):
        return True
    token = re.search(r"([A-Za-z]+(?:\.[A-Za-z]+)*)\.$", prefix)
    if token and token.group(1).casefold() in ABBREVIATIONS:
        return True
    if token and len(token.group(1)) == 1:
        following = text[index + 1:].lstrip()
        return bool(following and following[0].isupper())
    return False


def _sentence_spans(text: str, base: int = 0) -> list[tuple[int, int, str]]:
    spans: list[tuple[int, int, str]] = []
    start = 0
    for index, char in enumerate(text):
        # Single newlines in pasted PDFs and articles are commonly visual
        # wrapping, not semantic sentence boundaries.  A newline closes a
        # sentence only when the preceding visible character already does.
        newline_boundary = False
        if char == "\n":
            previous = text[:index].rstrip()
            newline_boundary = bool(previous and previous[-1] in ".!?。！？")
        boundary = newline_boundary or char in "。！？" or (
            char in ".!?"
            and (index + 1 == len(text) or text[index + 1].isspace())
            and not (char == "." and _period_is_abbreviation(text, index))
        )
        if not boundary:
            continue
        raw = text[start:index + 1]
        left = len(raw) - len(raw.lstrip())
        right = len(raw.rstrip())
        if right > left:
            spans.append((base + start + left, base + start + right,
                          raw[left:right]))
        start = index + 1
    if start < len(text):
        raw = text[start:]
        left = len(raw) - len(raw.lstrip())
        right = len(raw.rstrip())
        if right > left:
            spans.append((base + start + left, base + start + right,
                          raw[left:right]))
    return spans


def _pipe_spans(text: str, start: int) -> list[tuple[int, int, str]]:
    separators = list(PIPE_SPLIT_RE.finditer(text))
    if not separators:
        return [(start, start + len(text), text)]
    bounds = [0, *(m.end() for m in separators)]
    ends = [*(m.start() for m in separators), len(text)]
    result = []
    for left, right in zip(bounds, ends):
        raw = text[left:right]
        trim_left = len(raw) - len(raw.lstrip())
        trim_right = len(raw.rstrip())
        if trim_right > trim_left:
            result.append((start + left + trim_left, start + left + trim_right,
                           raw[trim_left:trim_right]))
    return result


def _inline_numbered_spans(text: str, start: int) -> list[tuple[int, int, str]]:
    """Split an inline ``1. ... 2. ...`` list without orphaning markers."""

    markers = list(INLINE_NUMBERED_RE.finditer(text))
    if len(markers) < 3:
        return []
    result = []
    prefix = text[:markers[0].start("marker")].strip()
    if prefix:
        left = text.index(prefix)
        result.append((start + left, start + left + len(prefix), prefix))
    for index, marker in enumerate(markers):
        left = marker.start("marker")
        right = (markers[index + 1].start("marker")
                 if index + 1 < len(markers) else len(text))
        raw = text[left:right]
        trim_left = len(raw) - len(raw.lstrip())
        trim_right = len(raw.rstrip())
        if trim_right > trim_left:
            result.append((start + left + trim_left,
                           start + left + trim_right,
                           raw[trim_left:trim_right]))
    return result


def semantic_units(content: str, decision: ShapeDecision) -> list[SemanticUnit]:
    """Split by content topology while retaining offsets into ``content``."""

    raw_units: list[tuple[int, int, str, str, str | None]] = []
    lines = _line_spans(content)

    if decision.primary == "hybrid":
        for start, _, line in lines:
            kind = ("timeline" if DATE_LEAD.match(line) else
                    "outline" if BULLET_LEAD.match(line) else
                    "outline" if HEADING_LEAD.match(line) else
                    "dialogue" if TAG_LINE.match(line) else "prose")
            tag = TAG_LINE.match(line) if kind == "dialogue" else None
            speaker = tag.group(1).strip() if tag else None
            body = tag.group(2).strip() if tag else line
            body_start = start + (tag.start(2) if tag else 0)
            numbered = _inline_numbered_spans(body, body_start)
            if numbered:
                parts = numbered
            elif kind == "timeline":
                parts = _pipe_spans(body, body_start)
            elif len(body) > 800:
                parts = _sentence_spans(body, body_start)
            else:
                parts = [(body_start, body_start + len(body), body)]
            raw_units.extend((a, b, t, kind, speaker) for a, b, t in parts)
    elif decision.has("dialogue"):
        for start, end, line in lines:
            tag = TAG_LINE.match(line)
            speaker = tag.group(1).strip() if tag else None
            body = tag.group(2).strip() if tag else line
            body_start = start + (tag.start(2) if tag else 0)
            # A long turn remains a turn semantically, but sentence subdivision
            # keeps a single speaker monologue from defeating the fixed budget.
            parts = _inline_numbered_spans(body, body_start)
            if not parts and len(body) > 800:
                parts = _sentence_spans(body, body_start)
            if parts:
                raw_units.extend((a, b, t, "dialogue", speaker)
                                 for a, b, t in parts)
            elif body:
                raw_units.append((body_start, body_start + len(body), body,
                                  "dialogue", speaker))
    elif decision.has("timeline"):
        for start, _, line in lines:
            raw_units.extend((a, b, t, "timeline", None)
                             for a, b, t in _pipe_spans(line, start))
    elif decision.has("outline"):
        raw_units.extend((start, end, line, "outline", None)
                         for start, end, line in lines)
    else:
        raw_units.extend((a, b, t, "prose", None)
                         for a, b, t in _sentence_spans(content))

    if not raw_units and content.strip():
        start = len(content) - len(content.lstrip())
        text = content.strip()
        raw_units.append((start, start + len(text), text, "prose", None))

    return [SemanticUnit(i, start, end, text, kind, speaker)
            for i, (start, end, text, kind, speaker) in enumerate(raw_units)]


def p23_sentence_units(content: str) -> list[SemanticUnit]:
    """Portable p2.3 per-item unit surface: source-order sentences.

    Production calls ``EideticLib.sentences`` before recurrence selection.
    The side converter uses its deterministic delimiter-compatible span
    surface, rather than the shape-specific Model-Plus unitizer, so the tail
    ablation does not accidentally test a different selection topology.
    """
    spans = _sentence_spans(content)
    if not spans and content.strip():
        start = len(content) - len(content.lstrip())
        spans = [(start, start + len(content.strip()), content.strip())]
    return [SemanticUnit(index, start, end, text, "p23")
            for index, (start, end, text) in enumerate(spans)]


def _normalize_punctuation(text: str) -> str:
    return text.translate(str.maketrans({
        "\u2018": "'", "\u2019": "'", "\u201b": "'",
        "\u201c": '"', "\u201d": '"', "\u201f": '"',
        "\u2013": "-", "\u2014": "-", "\u2015": "-", "\u2026": "...",
        "\u00a0": " ", "\u2007": " ", "\u202f": " ",
    }))


def _recapitalize(text: str) -> str:
    chars = list(text)
    needs_capital = True
    for index, char in enumerate(chars):
        if needs_capital and "a" <= char <= "z":
            chars[index] = char.upper()
            needs_capital = False
        elif char.isalnum():
            needs_capital = False
        # A dot inside an email/domain/decimal is not a sentence boundary.
        if char in ".!?" and (
                index + 1 == len(chars) or chars[index + 1].isspace()):
            needs_capital = True
    return "".join(chars)


def _urgency_collapse(text: str) -> str:
    """Collapse repeated urgency scaffolding without dropping urgency itself."""

    if len(re.findall(r"\bnow\b", text, re.IGNORECASE)) < 2:
        return text
    text = re.sub(r",?\s*no\s+really\s*,?", " ", text,
                  flags=re.IGNORECASE)
    text = re.sub(r",?\s*I\s+mean\s*,?", " ", text,
                  flags=re.IGNORECASE)
    matches = list(re.finditer(r"\bnow\b", text, re.IGNORECASE))
    if len(matches) > 1:
        keep = matches[-1].span()
        pieces: list[str] = []
        cursor = 0
        for match in matches[:-1]:
            pieces.append(text[cursor:match.start()])
            cursor = match.end()
        pieces.append(text[cursor:keep[0]])
        pieces.append(text[keep[0]:])
        text = "".join(pieces)
    return text


def compact_text(text: str, *, dialogue: bool = False) -> str:
    """Pure mechanical compaction; no paraphrase or generated vocabulary."""

    value = _normalize_punctuation(text).strip()
    # Structural markers are source scaffolding, not semantic payload.  Date
    # prefixes remain untouched; only the classifier's pinned list markers go.
    value = BULLET_LEAD.sub("", value).strip()
    if dialogue:
        if GREETING_ONLY_RE.fullmatch(value):
            return ""
        value = GREETING_PREFIX_RE.sub("", value).strip()
        if DIALOGUE_FILLER_ONLY_RE.fullmatch(value):
            return ""
    value = _urgency_collapse(value)
    for phrase, replacement in PHRASE_REWRITES:
        value = re.sub(rf"\b{re.escape(phrase)}\b", replacement, value,
                       flags=re.IGNORECASE)

    tokens = value.split()
    kept: list[str] = []
    previous_core = ""
    for token in tokens:
        core_match = WORD_RE.search(token)
        core = core_match.group(0).lower() if core_match else ""
        if core in STOPWORDS:
            continue
        # Consecutive word repetition is always safe to collapse.  Longer
        # duplicate units are handled by unit-level selection/deduplication.
        if core and core == previous_core:
            continue
        kept.append(token)
        if core:
            previous_core = core
    value = " ".join(kept)
    value = re.sub(r"\s+([,.;:!?])", r"\1", value)
    value = re.sub(r"(?:\s*,\s*){2,}", ", ", value)
    value = re.sub(r"\s{2,}", " ", value).strip(" ,")
    return _recapitalize(value)


def _named_entities(text: str) -> set[str]:
    # Match DistillationPipeline.defaultExtractor: skip word index zero, not
    # merely the first capitalized token.  Punctuation is outside WORD_RE.
    words = list(WORD_RE.finditer(text))
    return {match.group(0) for index, match in enumerate(words)
            if index > 0 and match.group(0)[0].isupper()
            and len(match.group(0)) > 1
            and match.group(0) not in COREF_EXCLUSIONS}


def _coref_entities(text: str) -> set[str]:
    """Broader antecedent pool; ambiguity intentionally disables rewriting."""

    return {match.group(0) for match in CAPITALIZED_RE.finditer(text)
            if match.group(0) not in COREF_EXCLUSIONS}


def resolve_conservative_coref(rendered: Sequence[tuple[SemanticUnit, str]]) -> list[tuple[SemanticUnit, str]]:
    """Resolve leading subject pronouns only with one prior named antecedent."""

    antecedents: set[str] = set()
    result: list[tuple[SemanticUnit, str]] = []
    for unit, text in rendered:
        if len(antecedents) == 1:
            antecedent = next(iter(antecedents))
            text = re.sub(r"^(?:He|She|They)\b", antecedent, text, count=1)
        antecedents.update(_coref_entities(text))
        result.append((unit, text))
    return result


def _normalized_terms(text: str) -> tuple[str, ...]:
    terms = []
    for match in WORD_RE.finditer(text.lower()):
        word = match.group(0)
        if word in SCORING_STOPWORDS or len(word) < 2:
            continue
        # Small fixed stemmer used only for scoring/deduplication.  The surface
        # representation is never rewritten from these stems.
        for suffix in ("ing", "ed", "es", "s"):
            if word.endswith(suffix) and len(word) > len(suffix) + 3:
                word = word[:-len(suffix)]
                break
        terms.append(word)
    return tuple(terms)


ACTION_STEMS = frozenset(
    term for word in ACTION_WORDS for term in _normalized_terms(word))


def _anchors(text: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    """Dates and quantities distinguish otherwise similar factual units."""

    return (tuple(DATE_RE.findall(text)), tuple(NUMBER_RE.findall(text)))


def _redundant(left_text: str, left_terms: set[str], right_text: str,
               right_terms: set[str], threshold: int) -> bool:
    left_anchors = _anchors(left_text)
    right_anchors = _anchors(right_text)
    # Different explicit dates/quantities describe different events or states;
    # common topical vocabulary must not collapse them.
    if ((left_anchors[0] or right_anchors[0])
            and left_anchors[0] != right_anchors[0]):
        return False
    if ((left_anchors[1] or right_anchors[1])
            and left_anchors[1] != right_anchors[1]):
        return False
    return _overlap_permille(left_terms, right_terms) >= threshold


def _overlap_permille(left: set[str], right: set[str]) -> int:
    if not left or not right:
        return 0
    return len(left & right) * 1000 // len(left | right)


def _dedupe_units(items: Sequence[tuple[SemanticUnit, str]]) -> list[tuple[SemanticUnit, str]]:
    kept: list[tuple[SemanticUnit, str]] = []
    indexed: list[tuple[str, set[str]]] = []
    for item in items:
        terms = set(_normalized_terms(item[1]))
        if any(_redundant(item[1], terms, prior_text, prior_terms, 780)
               for prior_text, prior_terms in indexed):
            continue
        kept.append(item)
        indexed.append((item[1], terms))
    return kept


def _collapse_shared_timeline_scaffolding(
        rendered: Sequence[tuple[SemanticUnit, str]]) -> list[tuple[SemanticUnit, str]]:
    """Keep a repeated parenthesized place once without losing events."""

    groups = Counter(
        match.group(0) for unit, text in rendered if unit.kind == "timeline"
        for match in re.finditer(r"\([^()]{2,80}\)", text)
    )
    recurring = {value for value, count in groups.items() if count >= 2}
    seen: set[str] = set()
    collapsed = []
    for unit, text in rendered:
        if unit.kind == "timeline":
            for value in sorted(recurring, key=lambda item: (-len(item), item)):
                if value in text:
                    if value in seen:
                        text = text.replace(value, "", 1)
                    else:
                        seen.add(value)
            text = re.sub(r"\s{2,}", " ", text)
            text = re.sub(r"\s+([,.;:!?])", r"\1", text).strip()
        collapsed.append((unit, text))
    return collapsed


def _render_selected(units: Sequence[SemanticUnit]) -> tuple[str, list[dict]]:
    rendered = []
    for unit in sorted(units, key=lambda item: item.index):
        text = compact_text(unit.text, dialogue=unit.kind == "dialogue")
        if text:
            rendered.append((unit, text))
    rendered = resolve_conservative_coref(_dedupe_units(rendered))
    rendered = _collapse_shared_timeline_scaffolding(rendered)
    core = " ".join(text for _, text in rendered).strip()
    spans = [{
        "unit_index": unit.index,
        "start": unit.start,
        "end": unit.end,
        "kind": unit.kind,
    } for unit, _ in rendered]
    return core, spans


def p23_core(units: Sequence[SemanticUnit]) -> tuple[str, list[dict], dict]:
    """Ablate only p2.3 Stage-5's ``+ tailUnits`` behavior."""

    if len(units) < 3:
        core, spans = _render_selected(units)
        return core, spans, {"selection": "p23-short-item-all", "recurring": []}

    per_unit = [_named_entities(unit.text) for unit in units]
    counts = Counter(entity for entities in per_unit for entity in entities)
    recurring = {entity for entity, count in counts.items() if count >= 2}
    selected = [unit for unit, entities in zip(units, per_unit)
                if entities & recurring]
    core, spans = _render_selected(selected)
    return core, spans, {
        "selection": "p23-recurring-capitalized-entity-tail-omitted",
        "recurring": sorted(recurring),
        "empty_core": not bool(selected),
    }


def _unit_relevance(unit: SemanticUnit, terms: tuple[str, ...],
                    frequencies: Counter[str]) -> int:
    if not terms:
        return 0
    # Repetition is evidence of topic, not unbounded importance. Capping its
    # contribution prevents a long conversational refrain from beating a rare
    # date, quantity, preference, or commitment.
    score = sum(min(frequencies[term], 4) * 80
                for term in set(terms)) // len(terms)
    # Structural bullet/ordinal markers are never facts. Score the same surface
    # that rendering uses so `1. Research Boston` does not gain a quantity or
    # false-capitalized-entity advantage over `Research Boston`.
    scoring_text = BULLET_LEAD.sub("", unit.text).strip()
    score += len(DATE_RE.findall(scoring_text)) * 300
    score += len(NUMBER_RE.findall(scoring_text)) * 180
    score += len(_named_entities(scoring_text)) * 120
    score += sum(1 for term in terms if term in ACTION_STEMS) * 220
    if "?" in unit.text:
        score += 320
    if unit.speaker:
        speaker = unit.speaker.casefold()
        if speaker in {"user", "human"}:
            score += 240
        elif speaker in {"assistant", "bot", "ai"}:
            score += 40
    return score


def _mmr_select_pool(candidates: Sequence[dict], budget_bytes: int,
                     prior_selected: Sequence[dict] = (),
                     preserve_all: bool = False) -> list[dict]:
    """Select one deterministic MMR pool under its own byte allowance.

    ``prior_selected`` participates in novelty and duplicate rejection but not
    in this pool's byte accounting.  That lets a long record reserve equal
    allowances for fixed positional regions without allowing repeated material
    in an earlier region to be selected again later.
    """

    selected = list(prior_selected)
    added: list[dict] = []
    added_bytes = 0
    remaining = list(candidates)
    covered_terms = set().union(
        *(item["terms"] for item in selected)) if selected else set()
    for item in remaining:
        item["max_redundancy"] = 0
        for prior in selected:
            if _anchors(item["text"]) == _anchors(prior["text"]):
                item["max_redundancy"] = max(
                    item["max_redundancy"],
                    _overlap_permille(item["terms"], prior["terms"]),
                )

    while remaining:
        ranked = []
        for item in remaining:
            novelty = len(item["terms"] - covered_terms)
            utility = (item["relevance"] * 1000 + novelty * 120
                       - item["max_redundancy"] * 500)
            ranked.append((utility, item["relevance"], -item["unit"].index,
                           item))
        _, _, _, best = max(ranked, key=lambda row: row[:3])
        remaining.remove(best)
        if preserve_all:
            duplicate = any(
                re.sub(r"\s+", " ", best["text"]).casefold()
                == re.sub(r"\s+", " ", prior["text"]).casefold()
                for prior in selected)
        else:
            duplicate = any(_redundant(
                best["text"], best["terms"], prior["text"],
                prior["terms"], 780) for prior in selected)
        if duplicate:
            continue
        cost = len(best["text"].encode("utf-8")) + (1 if added else 0)
        # Keep one indivisible evidence unit even when that unit alone exceeds
        # the allowance.  The overflow remains explicit in result metadata.
        if (not preserve_all and added
                and added_bytes + cost > budget_bytes):
            continue
        selected.append(best)
        added.append(best)
        added_bytes += cost
        covered_terms.update(best["terms"])
        for item in remaining:
            if _anchors(item["text"]) == _anchors(best["text"]):
                item["max_redundancy"] = max(
                    item["max_redundancy"],
                    _overlap_permille(item["terms"], best["terms"]),
                )
        if not preserve_all and added_bytes >= budget_bytes:
            break
    return added


def freq_mmr(units: Sequence[SemanticUnit], source_bytes: int,
             trailer_bytes: int = 0) -> tuple[str, list[dict], dict]:
    """Frequency relevance plus mandatory integer MMR suppression."""

    rendered: list[tuple[SemanticUnit, str, tuple[str, ...]]] = []
    for unit in units:
        text = compact_text(unit.text, dialogue=unit.kind == "dialogue")
        if text:
            rendered.append((unit, text, _normalized_terms(text)))
    frequencies = Counter(term for _, _, terms in rendered for term in set(terms))
    candidates = [{
        "unit": unit,
        "text": text,
        "terms": set(terms),
        "relevance": _unit_relevance(unit, terms, frequencies),
        "max_redundancy": 0,
    } for unit, text, terms in rendered]

    # v1's 35% / 2 KiB hard ceiling was blind-evaluated and rejected: it
    # discarded non-redundant facts from six of seven Debug-7 records. Preserve
    # complete short records and give long records enough room to fit inside a
    # typical 8K model window after deterministic de-duplication.
    core_budget = max(280, source_bytes * 55 // 100 - trailer_bytes)
    selected: list[dict] = []
    preserve_all = source_bytes <= 2048 or (
        source_bytes <= 4096
        and bool(candidates)
        and all(item["unit"].kind == "timeline" for item in candidates)
    )
    revision_indexes = [
        item["unit"].index for item in candidates
        if REVISION_MARKER_RE.search(item["text"])
    ]
    initial_draft_indexes = [
        item["unit"].index for item in candidates
        if INITIAL_DRAFT_MARKER_RE.search(item["text"])
    ]
    speakers = {
        (item["unit"].speaker or "").casefold() for item in candidates
        if item["unit"].speaker
    }
    outline_count = sum(
        1 for item in candidates if item["unit"].kind == "outline")
    assistant_starts = [
        item["unit"].index for item in candidates
        if (item["unit"].speaker or "").casefold()
        in {"assistant", "bot", "ai"}
    ]
    # Iterative outline conversations often begin with a plain assistant
    # answer rather than the literal words "initial outline".  The first
    # assistant turn is a safe draft boundary only when the record has both
    # sides of a conversation, several outline units, and a later explicit
    # revision marker.  Ordinary prose containing "final plan" cannot enter
    # this branch.
    if (not initial_draft_indexes and revision_indexes and outline_count >= 3
            and speakers & {"user", "human"}
            and speakers & {"assistant", "bot", "ai"}
            and assistant_starts):
        initial_draft_indexes = [min(assistant_starts)]
    revision_floor = (
        max(revision_indexes)
        if revision_indexes and initial_draft_indexes
        and speakers & {"user", "human"}
        and speakers & {"assistant", "bot", "ai"}
        else None
    )
    initial_draft_floor = (
        min(index for index in initial_draft_indexes if index < revision_floor)
        if revision_floor is not None
        and any(index < revision_floor for index in initial_draft_indexes)
        else None
    )
    if initial_draft_floor is None:
        revision_floor = None
    if revision_floor is not None:
        # A versioned outline is not a bag of equally-current bullets. Keep the
        # last explicitly marked revision and every explicit user constraint;
        # omit superseded assistant drafts. This is source-topology routing,
        # never benchmark identity or semantic invention.
        focused = [
            item for item in candidates
            if item["unit"].index >= revision_floor
            or item["unit"].index < initial_draft_floor
            or (item["unit"].speaker or "").casefold() in {"user", "human"}
        ]
        selected = []
        for item in sorted(focused, key=lambda value: value["unit"].index):
            if any(_redundant(item["text"], item["terms"],
                              prior["text"], prior["terms"], 780)
                   for prior in selected):
                continue
            selected.append(item)
    dialogue_count = sum(
        1 for item in candidates if item["unit"].kind == "dialogue")
    stratified_long_record = (
        source_bytes >= 8_000
        and len(candidates) >= 16
        and revision_floor is None
    )
    stratified_long_dialogue = (
        stratified_long_record
        and dialogue_count * 2 >= max(1, len(candidates))
    )
    positional_strata = 0
    if revision_floor is None and stratified_long_record:
        # Fixed source-position buckets prevent an early recurring subject from
        # consuming the entire budget.  Classification and bucketing depend
        # only on source topology; IDs, benchmark labels, and expected answers
        # are never visible here.
        stratum_count = 8
        buckets: list[list[dict]] = [[] for _ in range(stratum_count)]
        for item in candidates:
            bucket = min(
                stratum_count - 1,
                item["unit"].start * stratum_count
                // max(1, max(unit.end for unit in units)),
            )
            buckets[bucket].append(item)
        nonempty = [bucket for bucket in buckets if bucket]
        positional_strata = len(nonempty)
        base_allowance, remainder = divmod(
            core_budget, max(1, positional_strata))
        for index, bucket in enumerate(nonempty):
            allowance = base_allowance + (1 if index < remainder else 0)
            selected.extend(_mmr_select_pool(
                bucket, allowance, prior_selected=selected))
    elif revision_floor is None:
        selected = _mmr_select_pool(
            candidates, core_budget, preserve_all=preserve_all)

    if not selected and candidates:
        # A representation must contain evidence.  Preserve the best complete
        # unit even when a single indivisible source unit exceeds the budget and
        # report that overflow explicitly.
        selected = [max(candidates,
                        key=lambda item: (item["relevance"], -item["unit"].index))]

    selected.sort(key=lambda item: item["unit"].index)
    selected_pairs = resolve_conservative_coref(
        [(item["unit"], item["text"]) for item in selected])
    selected_pairs = _collapse_shared_timeline_scaffolding(selected_pairs)
    core = " ".join(text for _, text in selected_pairs).strip()
    spans = [{
        "unit_index": unit.index,
        "start": unit.start,
        "end": unit.end,
        "kind": unit.kind,
    } for unit, _ in selected_pairs]
    return core, spans, {
        "selection": "frequency-integer-mmr",
        "core_budget_bytes": core_budget,
        "selected_core_bytes": len(core.encode("utf-8")),
        "budget_overflow": len(core.encode("utf-8")) > core_budget,
        "redundancy_reject_permille": 780,
        "preserve_all_short_record": preserve_all,
        "latest_revision_floor": revision_floor,
        "initial_draft_floor": initial_draft_floor,
        "latest_revision_focus": revision_floor is not None,
        "stratified_long_record": stratified_long_record,
        "stratified_long_dialogue": stratified_long_dialogue,
        "positional_strata": positional_strata,
    }


def _physical_lines(source: str, start: int = 0,
                    end: int | None = None) -> list[tuple[int, int, str]]:
    """Return exact physical-line spans, including each line terminator."""

    stop = len(source) if end is None else end
    lines = []
    cursor = start
    while cursor < stop:
        newline = source.find("\n", cursor, stop)
        line_end = stop if newline < 0 else newline + 1
        raw = source[cursor:line_end]
        lines.append((cursor, line_end, raw.rstrip("\r\n")))
        cursor = line_end
    return lines


def _known_speaker(line: str) -> tuple[str, int] | None:
    match = TAG_LINE.match(line)
    if not match:
        return None
    speaker = match.group(1).strip().casefold()
    if speaker not in KNOWN_SPEAKERS and not speaker.startswith("speaker "):
        return None
    return speaker, match.start(2)


def _speaker_turns(source: str) -> list[SpeakerTurn]:
    """Parse only pinned speaker labels, ignoring labels inside fences."""

    markers: list[tuple[int, int, int, str]] = []
    fence: str | None = None
    for start, end, visible in _physical_lines(source):
        fence_match = FENCE_OPEN_RE.match(visible)
        if fence_match:
            token = fence_match.group(1)
            marker = token[0]
            if fence is None:
                fence = marker
            elif marker == fence:
                fence = None
            continue
        if fence is not None:
            continue
        parsed = _known_speaker(visible)
        if parsed:
            speaker, body_offset = parsed
            markers.append((start, end, start + body_offset, speaker))
    turns = []
    for index, (start, first_end, body_start, speaker) in enumerate(markers):
        end = markers[index + 1][0] if index + 1 < len(markers) else len(source)
        turns.append(SpeakerTurn(start, end, first_end, body_start, speaker))
    return turns


def _peer_speaker_turns(source: str) -> list[SpeakerTurn]:
    """Parse a strict alternating two-person transcript with named peers.

    The v22 classifier already recognized arbitrary repeated speaker names as
    dialogue, but the intent selector accepted only pinned role labels such as
    ``User`` and ``Assistant``.  Requiring two labels, at least six tagged
    turns, at least 90 percent tagged-line coverage, and 75 percent switching
    keeps metadata/field documents out of this lane while admitting ordinary
    ``Alice:``/``Bob:`` conversation exports.
    """

    lines: list[tuple[int, int, str]] = []
    markers: list[tuple[int, int, int, str]] = []
    labels: list[str] = []
    fence: str | None = None
    for start, end, visible in _physical_lines(source):
        fence_match = FENCE_OPEN_RE.match(visible)
        if fence_match:
            marker = fence_match.group(1)[0]
            if fence is None:
                fence = marker
            elif marker == fence:
                fence = None
            continue
        if fence is not None or not visible.strip():
            continue
        lines.append((start, end, visible))
        match = TAG_LINE.match(visible)
        if not match:
            continue
        speaker = match.group(1).strip().casefold()
        labels.append(speaker)
        markers.append((start, end, start + match.start(2), speaker))

    distinct = set(labels)
    switches = sum(left != right for left, right in zip(labels, labels[1:]))
    if (len(labels) < 6 or len(distinct) != 2
            or distinct & (KNOWN_SPEAKERS | PEER_FIELD_LABELS)
            or len(labels) * 100 // max(1, len(lines)) < 90
            or switches * 100 // max(1, len(labels) - 1) < 75):
        return []

    turns = []
    for index, (start, first_end, body_start, speaker) in enumerate(markers):
        end = markers[index + 1][0] if index + 1 < len(markers) else len(source)
        turns.append(SpeakerTurn(start, end, first_end, body_start, speaker))
    return turns


def _heading_level(line: str) -> int | None:
    markdown = MARKDOWN_HEADING_RE.match(line)
    if markdown:
        return len(markdown.group("marks"))
    if BOLD_HEADING_RE.match(line):
        return 7
    if HEADING_LEAD.match(line):
        return 1
    return None


def _is_list_line(line: str) -> bool:
    return bool(BULLET_LEAD.match(line))


def _indent_width(line: str) -> int:
    prefix = line[:len(line) - len(line.lstrip(" \t"))]
    return sum(4 if char == "\t" else 1 for char in prefix)


def _append_exact_atom(atoms: list[IntentAtom], source: str, start: int,
                       end: int, kind: str, speaker: str | None = None,
                       dependencies: tuple[int, ...] = (),
                       hard_required: bool = False) -> IntentAtom:
    atom = IntentAtom(len(atoms), start, end, source[start:end], kind, speaker,
                      dependencies, hard_required)
    atoms.append(atom)
    return atom


def _structured_atoms(source: str, start: int = 0,
                      end: int | None = None) -> tuple[list[IntentAtom], list[str]]:
    """Build non-overlapping, exact, indivisible document atoms."""

    stop = len(source) if end is None else end
    lines = _physical_lines(source, start, stop)
    atoms: list[IntentAtom] = []
    unsupported: list[str] = []
    index = 0
    while index < len(lines):
        line_start, line_end, visible = lines[index]
        if not visible.strip():
            index += 1
            continue

        adjacent_field = any(
            0 <= neighbor < len(lines)
            and FIELD_LINE_RE.match(lines[neighbor][2])
            for neighbor in (index - 1, index + 1)
        )
        date_entry = (DATE_LEAD.match(visible)
                      and len(DATE_RE.findall(visible)) <= 1)
        if date_entry or (
                FIELD_LINE_RE.match(visible) and adjacent_field):
            kind = "timeline-entry" if date_entry else "field-entry"
            _append_exact_atom(atoms, source, line_start, line_end, kind)
            index += 1
            continue

        fence_match = FENCE_OPEN_RE.match(visible)
        if fence_match:
            marker = fence_match.group(1)[0]
            finish = index + 1
            closed = False
            while finish < len(lines):
                if re.match(rf"^\s*{re.escape(marker)}{{3,}}\s*$",
                            lines[finish][2]):
                    finish += 1
                    closed = True
                    break
                finish += 1
            atom_end = lines[finish - 1][1] if finish else line_end
            kind = "fenced-code" if closed else "unsupported-unclosed-fence"
            if not closed:
                unsupported.append("unclosed-fence")
            _append_exact_atom(atoms, source, line_start, atom_end, kind)
            index = finish
            continue

        if visible.startswith("    ") or visible.startswith("\t"):
            finish = index + 1
            while finish < len(lines):
                candidate = lines[finish][2]
                if (not candidate.strip() or candidate.startswith("    ")
                        or candidate.startswith("\t")):
                    finish += 1
                else:
                    break
            _append_exact_atom(atoms, source, line_start,
                               lines[finish - 1][1], "indented-code")
            index = finish
            continue

        heading_level = _heading_level(visible)
        if heading_level is not None:
            # A heading is context, not an indivisible copy of its entire
            # section.  Grouping a 70 KB article below one heading made a
            # single query-coverage atom overflow the reducer budget.
            _append_exact_atom(atoms, source, line_start, line_end,
                               "heading")
            index += 1
            continue

        if (index + 1 < len(lines) and "|" in visible
                and TABLE_SEPARATOR_RE.match(lines[index + 1][2])):
            finish = index + 2
            while finish < len(lines) and "|" in lines[finish][2]:
                finish += 1
            _append_exact_atom(atoms, source, line_start,
                               lines[finish - 1][1], "table")
            index = finish
            continue

        if DIAGRAM_RE.search(visible):
            finish = index + 1
            while finish < len(lines) and (
                    DIAGRAM_RE.search(lines[finish][2])
                    or not lines[finish][2].strip()):
                finish += 1
            _append_exact_atom(atoms, source, line_start,
                               lines[finish - 1][1], "diagram")
            index = finish
            continue

        if _is_list_line(visible):
            parent_indent = _indent_width(visible)
            finish = index + 1
            while finish < len(lines):
                candidate = lines[finish][2]
                if _is_list_line(candidate):
                    if _indent_width(candidate) <= parent_indent:
                        break
                    finish += 1
                    continue
                if (not candidate.strip() or candidate.startswith("  ")
                        or candidate.startswith("\t")):
                    finish += 1
                else:
                    break
            _append_exact_atom(atoms, source, line_start,
                               lines[finish - 1][1], "list-item")
            index = finish
            continue

        finish = index + 1
        while finish < len(lines):
            candidate = lines[finish][2]
            if not candidate.strip():
                break
            if (FENCE_OPEN_RE.match(candidate)
                    or candidate.startswith("    ") or candidate.startswith("\t")
                    or _heading_level(candidate) is not None
                    or _is_list_line(candidate)
                    or DIAGRAM_RE.search(candidate)):
                break
            if (finish + 1 < len(lines) and "|" in candidate
                    and TABLE_SEPARATOR_RE.match(lines[finish + 1][2])):
                break
            finish += 1
        atom_end = lines[finish - 1][1]
        paragraph = source[line_start:atom_end]
        sentence_spans = _sentence_spans(paragraph, line_start)
        pipe_spans = _pipe_spans(paragraph, line_start)
        # A single physical line can contain an entire timeline or several
        # prose facts.  Treat each complete sentence/pipe entry as an exact
        # atom so one repetitive line cannot force a whole-record overflow.
        # Protected structures above remain indivisible.
        subdivisions = (sentence_spans if len(sentence_spans) > 1
                        else pipe_spans if len(pipe_spans) > 1 else [])
        if subdivisions:
            for sub_start, sub_end, _ in subdivisions:
                _append_exact_atom(atoms, source, sub_start, sub_end,
                                   "sentence-or-entry")
            index = finish
            continue
        kind = "paragraph"
        if len(paragraph.encode("utf-8")) > 4096:
            kind = "unsupported-oversized-unstructured"
            unsupported.append("oversized-unstructured-paragraph")
        _append_exact_atom(atoms, source, line_start, atom_end, kind)
        index = finish
    # Selecting content must pull in its nearest section heading; nested
    # headings in turn depend on their parent.  Headings are context atoms,
    # never free-standing high-score selections.
    linked: list[IntentAtom] = []
    heading_stack: list[tuple[int, int]] = []
    for atom in atoms:
        dependencies = list(atom.dependencies)
        if atom.kind == "heading":
            level = _heading_level(atom.text) or 7
            while heading_stack and heading_stack[-1][0] >= level:
                heading_stack.pop()
            if heading_stack:
                dependencies.append(heading_stack[-1][1])
            heading_stack.append((level, atom.atom_id))
        elif heading_stack:
            dependencies.append(heading_stack[-1][1])
        linked.append(IntentAtom(
            atom.atom_id, atom.start, atom.end, atom.text, atom.kind,
            atom.speaker, tuple(dict.fromkeys(dependencies)),
            atom.hard_required,
        ))
    return linked, sorted(set(unsupported))


def _reindex_atoms(atoms: Sequence[IntentAtom], offset: int = 0,
                   dependency_map: dict[int, tuple[int, ...]] | None = None,
                   hard_ids: set[int] | None = None) -> list[IntentAtom]:
    dependency_map = dependency_map or {}
    hard_ids = hard_ids or set()
    result = []
    for atom in atoms:
        new_id = atom.atom_id + offset
        dependencies = dependency_map.get(atom.atom_id, atom.dependencies)
        result.append(IntentAtom(
            new_id, atom.start, atom.end, atom.text, atom.kind, atom.speaker,
            tuple(dep + offset for dep in dependencies),
            atom.hard_required or atom.atom_id in hard_ids,
        ))
    return result


def _turn_body(source: str, turn: SpeakerTurn) -> str:
    return source[turn.body_start:turn.end].strip()


def _substantive_turn(source: str, turn: SpeakerTurn) -> bool:
    body = _turn_body(source, turn)
    return bool(body and not TURN_FILLER_RE.fullmatch(body)
                and not ASSISTANT_BOILERPLATE_RE.fullmatch(body))


def _short_operative(text: str) -> bool:
    body = text.strip()
    return bool(body and len(body.encode("utf-8")) <= 280
                and ("?" in body or OPERATIVE_RE.match(body)))


def _query_terms(text: str) -> set[str]:
    return {term for term in _normalized_terms(text)
            if term not in QUERY_STOPWORDS and len(term) >= 3}


def _atom_terms(atom: IntentAtom) -> set[str]:
    return set(_normalized_terms(atom.text))


def _find_document_exchange(source: str, turns: Sequence[SpeakerTurn]) -> tuple[
        SpeakerTurn, int, SpeakerTurn] | None:
    for index, turn in enumerate(turns):
        if turn.speaker not in KNOWN_USER_SPEAKERS:
            continue
        first_body = source[turn.body_start:turn.first_line_end].strip()
        continuation_start = turn.first_line_end
        if not _short_operative(first_body):
            continue
        answers = [candidate for candidate in turns[index + 1:]
                   if candidate.speaker in KNOWN_ANSWER_SPEAKERS
                   and _substantive_turn(source, candidate)]
        if answers:
            # The final answer is authoritative when a pasted transcript or
            # document itself contains role-labelled lines.  Earlier labels
            # belong to the payload; treating the first one as the outer
            # answer silently discards the actual response.
            answer = answers[-1]
            continuation = source[continuation_start:answer.start]
            if len(continuation.encode("utf-8")) < 800:
                continue
            immediate_payload = source[continuation_start:turn.end]
            if len(immediate_payload.encode("utf-8")) < 800:
                continue
            return turn, continuation_start, answer
    return None


def _embedded_user_fact_atoms(source: str) -> list[IntentAtom]:
    """Recover user facts embedded after assistant scaffolding on one line.

    Some transcript exports serialize each exchange as an assistant reaction
    followed by ``timestamp - user: fact`` on the same physical line.  The
    normal speaker-turn parser correctly sees the line prefix as assistant,
    but that topology would make the embedded user facts optional.  When the
    shape repeats, retain each exact timestamped user span and omit the
    reaction scaffolding.
    """

    matches: list[tuple[int, int]] = []
    assistant_spans: list[tuple[int, int]] = []
    other_spans: list[tuple[int, int]] = []
    prefix_spans: list[tuple[int, int]] = []
    eligible_lines = 0
    assistant_scaffold_lines = 0
    other_lines = 0
    fence: str | None = None
    saw_fence = False
    for line_start, _, visible in _physical_lines(source):
        fence_match = FENCE_OPEN_RE.match(visible)
        if fence_match:
            saw_fence = True
            marker = fence_match.group(1)[0]
            if fence is None:
                fence = marker
            elif fence == marker:
                fence = None
            continue
        if fence is not None or not visible.strip():
            continue
        eligible_lines += 1
        match = EMBEDDED_USER_FACT_RE.search(visible)
        if match:
            start, end = match.span("fact")
            prefix = visible[:start]
            prefix_end = len(prefix.rstrip())
            if prefix_end:
                prefix_spans.append((line_start, line_start + prefix_end))
            matches.append((line_start + start, line_start + end))
        else:
            speaker = _known_speaker(visible)
            if speaker and speaker[0] in KNOWN_ANSWER_SPEAKERS:
                assistant_scaffold_lines += 1
                assistant_spans.append((line_start, line_start + len(visible)))
            else:
                other_lines += 1
                other_spans.append((line_start, line_start + len(visible)))
    # This is a repeated transcript shape, not a two-line trigger.  Real
    # exports alternate one timestamped user fact with one assistant reaction,
    # plus at most a small title/tail.  Four occurrences and near-half line
    # coverage reject mixed records; fenced examples were excluded above.
    if (saw_fence or len(matches) < 4 or other_lines > 2
            or abs(assistant_scaffold_lines - len(matches)) > 1
            or len(matches) * 2 < eligible_lines - 2):
        return []
    atoms: list[IntentAtom] = []
    inventory = [
        (start, end, "embedded-timestamped-user-fact", "user", True)
        for start, end in matches
    ] + [
        (start, end, "embedded-assistant-turn", "assistant", False)
        for start, end in assistant_spans
    ] + [
        (start, end, "embedded-context-line", None, False)
        for start, end in other_spans
    ] + [
        (start, end, "embedded-line-prefix", None, False)
        for start, end in prefix_spans
    ]
    for start, end, kind, speaker, required in sorted(inventory):
        _append_exact_atom(
            atoms, source, start, end, kind, speaker,
            hard_required=required,
        )
    return atoms


def _append_answer_subatoms(atoms: list[IntentAtom], source: str,
                            turn: SpeakerTurn,
                            dependencies: tuple[int, ...]) -> tuple[list[int],
                                                                   list[str]]:
    """Append exact semantic subunits for one substantive answer turn."""

    parts, unsupported = _structured_atoms(source, turn.start, turn.end)
    ids: list[int] = []
    base_id = len(atoms)
    for part_index, part in enumerate(parts):
        part_dependencies = tuple(
            base_id + dependency for dependency in part.dependencies
        )
        part_kind = part.kind
        if part_index == 0:
            speaker_prefix = _known_speaker(part.text)
            if (speaker_prefix is not None
                    and _is_list_line(part.text[speaker_prefix[1]:])):
                part_kind = "list-item"
        atom = _append_exact_atom(
            atoms, source, part.start, part.end,
            f"answer-{part_kind}", turn.speaker,
            dependencies=tuple(dict.fromkeys(
                (*dependencies, *part_dependencies)
            )),
        )
        ids.append(atom.atom_id)
    if not ids:
        atom = _append_exact_atom(
            atoms, source, turn.start, turn.end, "answer-turn", turn.speaker,
            dependencies=dependencies,
        )
        ids.append(atom.atom_id)
    return ids, unsupported


def _normalized_atom_text(atom: IntentAtom) -> str:
    text = atom.text
    if atom.kind in {"list-item", "answer-list-item"}:
        if atom.kind == "answer-list-item":
            speaker = _known_speaker(text)
            if speaker is not None:
                text = text[speaker[1]:]
        text = LIST_MARKER_RE.sub("", text, count=1)
    return re.sub(r"\s+", " ", text).strip().casefold()


def _distinct_answer_ids(atoms: Sequence[IntentAtom],
                         answer_ids: Sequence[int]) -> list[int]:
    seen: set[str] = set()
    distinct_ids: list[int] = []
    for atom_id in answer_ids:
        normalized = _normalized_atom_text(atoms[atom_id])
        if normalized in seen:
            continue
        seen.add(normalized)
        distinct_ids.append(atom_id)
    return distinct_ids


def _answer_coverage_ids(atoms: Sequence[IntentAtom],
                         answer_ids: Sequence[int]) -> set[int]:
    """Return deterministic topical coverage for a substantive answer."""

    distinct_ids = _distinct_answer_ids(atoms, answer_ids)
    candidates = [atom_id for atom_id in distinct_ids
                  if atoms[atom_id].kind != "answer-heading"]
    if not candidates:
        return set()
    covered = {max(
        candidates,
        key=lambda atom_id: (
            _intent_relevance(atoms[atom_id]), -atoms[atom_id].start,
        ),
    )}
    list_ids = [atom_id for atom_id in candidates
                if atoms[atom_id].kind == "answer-list-item"]
    # Lists encode distinct recommendations or catalog fields.  Preserve every
    # distinct complete item; repeated items were collapsed above.
    covered.update(list_ids)
    heading_ids = [atom_id for atom_id in answer_ids
                   if atoms[atom_id].kind == "answer-heading"]
    for heading_id in heading_ids:
        children = [atom_id for atom_id in candidates
                    if heading_id in atoms[atom_id].dependencies]
        if children:
            covered.add(max(
                children,
                key=lambda atom_id: (
                    _intent_relevance(atoms[atom_id]), -atoms[atom_id].start,
                ),
            ))
    return covered


def _intent_atoms(source: str, *, peer_dialogue: bool = False) -> tuple[
        list[IntentAtom], set[int], set[int], list[str], dict]:
    """Return atoms, hard IDs, query-coverage IDs, unsupported shapes, mode."""

    embedded_facts = _embedded_user_fact_atoms(source)
    if embedded_facts:
        hard = {atom.atom_id for atom in embedded_facts
                if atom.hard_required}
        return (embedded_facts, hard, set(), [], {
            "mode": "embedded-transcript",
            "embedded_user_fact_count": len(hard),
            "embedded_assistant_turn_count": sum(
                atom.kind == "embedded-assistant-turn"
                for atom in embedded_facts
            ),
            "embedded_context_line_count": sum(
                atom.kind == "embedded-context-line"
                for atom in embedded_facts
            ),
            "embedded_line_prefix_count": sum(
                atom.kind == "embedded-line-prefix"
                for atom in embedded_facts
            ),
        })

    turns = _speaker_turns(source)
    exchange = _find_document_exchange(source, turns)
    if exchange is not None:
        request_turn, document_start, answer_turn = exchange
        atoms: list[IntentAtom] = []
        request = _append_exact_atom(
            atoms, source, request_turn.start, request_turn.first_line_end,
            "operative-request", request_turn.speaker, hard_required=True)
        document_atoms, unsupported = _structured_atoms(
            source, document_start, answer_turn.start)
        atoms.extend(_reindex_atoms(document_atoms, len(atoms)))
        query = _query_terms(source[request_turn.body_start:
                                    request_turn.first_line_end])
        coverage: set[int] = set()
        document_ids = {atom.atom_id for atom in atoms
                        if document_start <= atom.start < answer_turn.start}
        for term in sorted(query):
            matches = [atom for atom in atoms if atom.atom_id in document_ids
                       and atom.kind != "heading"
                       and term in _atom_terms(atom)]
            if matches:
                best = min(matches, key=lambda atom: (len(atom.text), atom.start))
                coverage.add(best.atom_id)
        protected_document = any(
            atom.kind in {
                "fenced-code", "indented-code", "table", "diagram",
                "list-item", "unsupported-unclosed-fence",
                "unsupported-oversized-unstructured",
            }
            for atom in document_atoms
        )
        # In this topology the user supplied the authoritative document and
        # the assistant produced a derivative transform.  The transform may
        # contain hallucinations or lossy simplifications, so feeding it back
        # to a memory miner would launder generated content as evidence.  Keep
        # the request and supplied document; record the exact omitted span for
        # audit.  Genuine dialogue answers follow the separate path below.
        return (atoms, {request.atom_id}, coverage, unsupported,
                {"mode": "document-exchange", "query_terms": sorted(query),
                 "protected_document_structure": protected_document,
                 "derived_answer_omitted": {
                     "start": answer_turn.start,
                     "end": answer_turn.end,
                     "speaker": answer_turn.speaker,
                     "reason": "generated-transform-not-source-evidence",
                 }})

    if peer_dialogue:
        peer_turns = _peer_speaker_turns(source)
        if peer_turns:
            atoms = []
            unsupported: list[str] = []
            discarded = []
            for turn in peer_turns:
                body = _turn_body(source, turn)
                if (not body or TURN_FILLER_RE.fullmatch(body)
                        or GREETING_ONLY_RE.fullmatch(body)
                        or DIALOGUE_FILLER_ONLY_RE.fullmatch(body)):
                    discarded.append({
                        "speaker": turn.speaker,
                        "start": turn.start,
                        "reason": "filler",
                    })
                    continue
                prefix = _append_exact_atom(
                    atoms, source, turn.start, turn.body_start,
                    "peer-speaker-prefix", turn.speaker,
                )
                parts, problems = _structured_atoms(
                    source, turn.body_start, turn.end)
                unsupported.extend(problems)
                if not parts:
                    _append_exact_atom(
                        atoms, source, turn.body_start, turn.end,
                        "peer-dialogue-turn", turn.speaker,
                        dependencies=(prefix.atom_id,),
                    )
                    continue
                base_id = len(atoms)
                for part in parts:
                    dependencies = tuple(
                        base_id + dependency for dependency in part.dependencies
                    )
                    _append_exact_atom(
                        atoms, source, part.start, part.end,
                        f"peer-{part.kind}", turn.speaker,
                        dependencies=tuple(dict.fromkeys(
                            (prefix.atom_id, *dependencies)
                        )),
                    )
            if any(atom.kind != "peer-speaker-prefix" for atom in atoms):
                return (atoms, set(), set(), sorted(set(unsupported)), {
                    "mode": "peer-dialogue",
                    "peer_speakers": sorted({turn.speaker
                                             for turn in peer_turns}),
                    "peer_turn_count": len(peer_turns),
                    "discarded_turns": discarded,
                })

    if len(turns) >= 2:
        atoms = []
        hard: set[int] = set()
        coverage: set[int] = set()
        unsupported: list[str] = []
        discarded = []
        consumed_answers: set[int] = set()
        turn_atom_ids: dict[int, tuple[int, ...]] = {}
        substantive_user_indexes = [
            index for index, candidate in enumerate(turns)
            if candidate.speaker in KNOWN_USER_SPEAKERS
            and _substantive_turn(source, candidate)
        ]
        last_substantive_user = (
            substantive_user_indexes[-1] if substantive_user_indexes else None
        )
        if turns[0].start > 0 and source[:turns[0].start].strip():
            prefix = _append_exact_atom(
                atoms, source, 0, turns[0].start,
                "dialogue-prefix-context", hard_required=True)
            hard.add(prefix.atom_id)
        for index, turn in enumerate(turns):
            if turn.speaker not in KNOWN_USER_SPEAKERS:
                continue
            if not _substantive_turn(source, turn):
                discarded.append({"speaker": turn.speaker, "start": turn.start,
                                  "reason": "filler"})
                continue
            dependencies: tuple[int, ...] = ()
            user_body = _turn_body(source, turn)
            if index > 0:
                context_turn = turns[index - 1]
                context_body = _turn_body(source, context_turn)
                context_needed = bool(
                    POLARITY_ONLY_RE.fullmatch(user_body)
                    or (len(user_body.encode("utf-8")) <= 160
                        and "?" in context_body)
                    or (len(user_body.encode("utf-8")) <= 280
                        and TRANSFORM_FOLLOWUP_RE.search(user_body))
                )
                if (context_needed
                        and context_turn.speaker in KNOWN_ANSWER_SPEAKERS
                        and _substantive_turn(source, context_turn)):
                    context_ids = turn_atom_ids.get(index - 1)
                    if context_ids is None:
                        context_ids, problems = _append_answer_subatoms(
                            atoms, source, context_turn, ())
                        unsupported.extend(problems)
                        turn_atom_ids[index - 1] = tuple(context_ids)
                    hard.update(context_ids)
                    dependencies = tuple(context_ids)
            user_atom = _append_exact_atom(
                atoms, source, turn.start, turn.end, "substantive-user-turn",
                turn.speaker, dependencies=dependencies, hard_required=True)
            turn_atom_ids[index] = (user_atom.atom_id,)
            hard.add(user_atom.atom_id)
            answer_indexes: list[int] = []
            for answer_index in range(index + 1, len(turns)):
                answer_turn = turns[answer_index]
                if answer_turn.speaker in KNOWN_USER_SPEAKERS:
                    break
                if (answer_index not in consumed_answers
                        and answer_turn.speaker in KNOWN_ANSWER_SPEAKERS
                        and _substantive_turn(source, answer_turn)):
                    answer_indexes.append(answer_index)
            for paired_answer_index in answer_indexes:
                answer_turn = turns[paired_answer_index]
                if paired_answer_index not in turn_atom_ids:
                    answer_ids, problems = _append_answer_subatoms(
                        atoms, source, answer_turn, (user_atom.atom_id,))
                    unsupported.extend(problems)
                    turn_atom_ids[paired_answer_index] = tuple(answer_ids)
                answer_ids = turn_atom_ids[paired_answer_index]
                # Every retained substantive prompt must retain at least one
                # complete answer unit.  This prevents the distillate from
                # becoming a stack of orphaned questions while still allowing
                # long enumerations to be reduced under the shared budget.
                coverage.update(_answer_coverage_ids(atoms, answer_ids))
                active_answer = bool(
                    index == last_substantive_user
                    and ("?" in user_body or OPERATIVE_RE.match(user_body)
                         or REVISION_MARKER_RE.search(user_body))
                )
                if active_answer:
                    hard.update(_distinct_answer_ids(atoms, answer_ids))
                consumed_answers.add(paired_answer_index)
        for index, turn in enumerate(turns):
            if (index not in turn_atom_ids
                    and turn.speaker in KNOWN_ANSWER_SPEAKERS
                    and _substantive_turn(source, turn)):
                answer_ids, problems = _append_answer_subatoms(
                    atoms, source, turn, ())
                unsupported.extend(problems)
                turn_atom_ids[index] = tuple(answer_ids)
        if atoms:
            return (atoms, hard, coverage, sorted(set(unsupported)),
                    {"mode": "genuine-dialogue", "discarded_turns": discarded})

    atoms, unsupported = _structured_atoms(source)
    return atoms, set(), set(), unsupported, {"mode": "document"}


def _dependency_closure(atom_by_id: dict[int, IntentAtom],
                        initial: Iterable[int]) -> set[int]:
    closure = set(initial)
    stack = list(closure)
    while stack:
        atom = atom_by_id[stack.pop()]
        for dependency in atom.dependencies:
            if dependency not in closure:
                closure.add(dependency)
                stack.append(dependency)
    return closure


def _selection_bytes(source: str, atoms: Sequence[IntentAtom],
                     selected: set[int]) -> int:
    chosen = sorted((atom for atom in atoms if atom.atom_id in selected),
                    key=lambda atom: atom.start)
    if not chosen:
        return 0
    size = sum(len(atom.text.encode("utf-8")) for atom in chosen)
    for left, right in zip(chosen, chosen[1:]):
        gap = source[left.end:right.start]
        size += len(gap.encode("utf-8")) if not gap.strip() else 2
    return size


def _intent_relevance(atom: IntentAtom) -> int:
    terms = _atom_terms(atom)
    score = len(terms) * 10
    score += len(DATE_RE.findall(atom.text)) * 160
    score += len(NUMBER_RE.findall(atom.text)) * 100
    score += sum(term in ACTION_STEMS for term in terms) * 140
    score += {
        "fenced-code": 300, "indented-code": 300, "table": 280,
        "diagram": 240, "list-item": 220, "heading": 180,
        "answer-fenced-code": 300, "answer-indented-code": 300,
        "answer-table": 280, "answer-diagram": 240,
        "answer-list-item": 220, "answer-heading": 180,
    }.get(atom.kind, 0)
    return score


def _render_exact(source: str, atoms: Sequence[IntentAtom],
                  selected: set[int],
                  hard_ids: set[int] | None = None) -> tuple[str, list[dict]]:
    hard_ids = hard_ids or set()
    atom_by_id = {atom.atom_id: atom for atom in atoms}

    def peer_group(atom: IntentAtom | None) -> int | None:
        if atom is None or not atom.kind.startswith("peer-"):
            return None
        if atom.kind == "peer-speaker-prefix":
            return atom.atom_id
        for dependency in atom.dependencies:
            candidate = atom_by_id.get(dependency)
            if candidate is not None and candidate.kind == "peer-speaker-prefix":
                return candidate.atom_id
        return None

    chosen = sorted((atom for atom in atoms if atom.atom_id in selected),
                    key=lambda atom: (atom.start, atom.end))
    pieces = []
    spans = []
    previous_end: int | None = None
    previous_atom: IntentAtom | None = None
    for atom in chosen:
        if previous_end is not None and atom.start > previous_end:
            gap = source[previous_end:atom.start]
            same_peer_turn = (peer_group(previous_atom) is not None
                              and peer_group(previous_atom) == peer_group(atom))
            pieces.append(gap if not gap.strip()
                          else " " if same_peer_turn else "\n\n")
        # Assertion is load-bearing: intent-span may never render a rewritten
        # or partially sliced protected atom.
        assert atom.text == source[atom.start:atom.end]
        pieces.append(atom.text)
        spans.append({
            "atom_id": atom.atom_id,
            "start": atom.start,
            "end": atom.end,
            "kind": atom.kind,
            "speaker": atom.speaker,
            "dependencies": list(atom.dependencies),
            "hard_required": atom.hard_required or atom.atom_id in hard_ids,
        })
        previous_end = atom.end
        previous_atom = atom
    return "".join(pieces), spans


def _source_occurrences(source: str, value: str) -> list[re.Match]:
    return list(re.finditer(
        rf"(?<![\w]){re.escape(value)}(?![\w])", source, re.IGNORECASE))


def _sentence_initial(source: str, start: int) -> bool:
    cursor = start - 1
    while cursor >= 0:
        if source[cursor] == "\n":
            return True
        if source[cursor].isspace() or source[cursor] in "-*>•([{\"'":
            cursor -= 1
            continue
        break
    return cursor < 0 or source[cursor] in ".!?\n"


def project_intent_trailer(source: str, trailer: str) -> tuple[str, dict]:
    """Project only source-anchored, type-context-safe trailer fields."""

    accepted = []
    rejected = []
    if not trailer:
        return "", {"accepted": accepted, "rejected": rejected}
    match = re.fullmatch(r"\(\*\[\s*(.*?)\s*\]\*\)", trailer, re.DOTALL)
    if not match:
        return "", {"accepted": accepted, "rejected": [
            {"raw": trailer, "reason": "invalid-trailer-grammar"}
        ]}
    # A comma followed by a field label is a delimiter; a comma inside a
    # numeric value (for example ``quantity: 1,200``) is data.
    raw_fields = re.split(
        r",\s*(?=[A-Za-z][A-Za-z0-9_-]*\s*:)", match.group(1)
    )
    for raw in raw_fields:
        field = raw.strip()
        if not field:
            continue
        if ":" not in field:
            rejected.append({"raw": field, "reason": "invalid-field"})
            continue
        label, value = (part.strip() for part in field.split(":", 1))
        label = label.casefold()
        occurrences = _source_occurrences(source, value)
        reason = None
        if label in {"kind", "fdc"}:
            reason = "opaque-taxonomy"
        elif label not in {"entity", "place", "country", "date", "quantity"}:
            reason = "unsupported-field-type"
        elif not occurrences:
            reason = "not-source-anchored"
        elif label == "entity":
            value_terms = _normalized_terms(value)
            capitalized_any = any(
                source[item.start():item.end()][:1].isupper()
                for item in occurrences
            )
            capitalized = any(
                source[item.start():item.end()][:1].isupper()
                and not _sentence_initial(source, item.start())
                for item in occurrences
            )
            cue = re.search(
                rf"\b{ENTITY_CUE}\s+(?:the\s+)?{re.escape(value)}\b",
                source, re.IGNORECASE)
            subject_cue = capitalized_any and re.search(
                rf"\b{re.escape(value)}\s+{ENTITY_SUBJECT_CUE}\b",
                source, re.IGNORECASE)
            if value.strip().casefold() in ENTITY_NON_NAME_VALUES:
                reason = "unsafe-entity-context"
            elif (value_terms and value_terms[0] in ENTITY_NON_NAME_PREFIXES):
                reason = "unsafe-entity-context"
            elif not capitalized and not cue and not subject_cue:
                reason = "unsafe-entity-context"
        elif label in {"place", "country"}:
            cue = re.search(
                rf"\b{LOCATIVE_CUE}\s+(?:the\s+)?{re.escape(value)}\b",
                source, re.IGNORECASE)
            explicit = re.search(
                rf"\b{label}\s*(?:is|:)?\s*{re.escape(value)}\b",
                source, re.IGNORECASE)
            if not cue and not explicit:
                reason = "unsafe-locative-context"
        elif label == "date" and not DATE_RE.fullmatch(value):
            reason = "unsafe-date-context"
        elif label == "quantity" and not QUANTITY_VALUE_RE.fullmatch(value):
            reason = "unsafe-quantity-context"
        item = {"field": label, "value": value, "raw": field}
        if reason:
            item["reason"] = reason
            rejected.append(item)
        else:
            accepted.append(item)
    projected = ""
    if accepted:
        body = ", ".join(f"{item['field']}: {item['value']}"
                         for item in accepted)
        projected = f"(*[ {body} ]*)"
    return projected, {"accepted": accepted, "rejected": rejected}


def intent_span(source: str, trailer: str, *, peer_dialogue: bool = False
                ) -> tuple[str, list[dict], dict, str]:
    """Select complete exact source atoms with deterministic dependencies."""

    atoms, hard, coverage, unsupported, mode_details = _intent_atoms(
        source, peer_dialogue=peer_dialogue)
    projection_source = source
    excluded_projection_spans: list[dict] = []
    omitted = mode_details.get("derived_answer_omitted")
    if isinstance(omitted, dict):
        start = omitted.get("start")
        end = omitted.get("end")
        if (isinstance(start, int) and isinstance(end, int)
                and 0 <= start <= end <= len(source)):
            # Preserve character offsets while making the generated transform
            # unavailable to every trailer anchoring/context check.  Spaces
            # avoid inventing a match across the redaction boundary.
            projection_source = (
                source[:start] + (" " * (end - start)) + source[end:]
            )
            excluded_projection_spans.append({
                "start": start,
                "end": end,
                "reason": "generated-transform-not-source-evidence",
            })
    projected_trailer, projection = project_intent_trailer(
        projection_source, trailer)
    projection["excluded_source_spans"] = excluded_projection_spans
    atom_by_id = {atom.atom_id: atom for atom in atoms}
    selected = _dependency_closure(atom_by_id, hard | coverage) if atoms else set()
    budget_percent = 55
    if (mode_details.get("mode") == "document-exchange"
            and not mode_details.get("protected_document_structure")):
        budget_percent = 35
    budget = max(
        512,
        len(source.encode("utf-8")) * budget_percent // 100
        - len(projected_trailer.encode("utf-8")),
    )
    source_bytes = len(source.encode("utf-8"))
    preserve_all_short = source_bytes <= 512 or (
        mode_details.get("mode") == "document" and source_bytes <= 2048
    )
    if preserve_all_short:
        selected = _dependency_closure(atom_by_id, atom_by_id) if atoms else set()

    terms_by_id = {atom.atom_id: _atom_terms(atom) for atom in atoms}
    relevance_by_id = {
        atom.atom_id: _intent_relevance(atom) for atom in atoms
    }
    normalized_by_id = {
        atom.atom_id: _normalized_atom_text(atom) for atom in atoms
    }
    remaining = [atom for atom in atoms
                 if atom.atom_id not in selected
                 and atom.kind not in {
                     "heading", "answer-heading", "peer-speaker-prefix",
                 }]
    budget_rejected = []
    while remaining:
        selected_terms = set().union(
            *(terms_by_id[atom_id] for atom_id in selected)
        ) if selected else set()
        selected_normalized = {
            normalized_by_id[atom_id] for atom_id in selected
        }
        ranked = []
        for atom in remaining:
            terms = terms_by_id[atom.atom_id]
            novelty = len(terms - selected_terms)
            max_overlap = max(
                (_overlap_permille(terms, terms_by_id[atom_id])
                 for atom_id in selected),
                default=0,
            )
            relevance = relevance_by_id[atom.atom_id]
            utility = (relevance * 1000 + novelty * 120
                       - max_overlap * 300)
            ranked.append((utility, relevance, -atom.start, atom))
        _, _, _, atom = max(ranked, key=lambda row: row[:3])
        remaining.remove(atom)
        if normalized_by_id[atom.atom_id] in selected_normalized:
            budget_rejected.append({
                "atom_id": atom.atom_id,
                "kind": atom.kind,
                "bytes": len(atom.text.encode("utf-8")),
                "reason": "exact-duplicate",
            })
            continue
        proposed = _dependency_closure(atom_by_id, selected | {atom.atom_id})
        if _selection_bytes(source, atoms, proposed) <= budget:
            selected = proposed
        else:
            budget_rejected.append({
                "atom_id": atom.atom_id,
                "kind": atom.kind,
                "bytes": len(atom.text.encode("utf-8")),
                "reason": "complete-atom-does-not-fit",
            })
    core, spans = _render_exact(source, atoms, selected, hard)
    selected_bytes = len(core.encode("utf-8"))
    if atoms and not core.strip():
        unsupported = sorted(set(unsupported) | {"no-complete-atom-fits-budget"})
    hard_closure = _dependency_closure(atom_by_id, hard | coverage) if atoms else set()
    details = {
        "selection": "intent-span-exact-source-atoms",
        "intent_span_version": INTENT_SPAN_VERSION,
        **mode_details,
        "core_budget_bytes": budget,
        "core_budget_percent": budget_percent,
        "selected_core_bytes": selected_bytes,
        "budget_overflow": selected_bytes > budget,
        "empty_core": not bool(core.strip()),
        "preserve_all_short_document": preserve_all_short,
        "hard_required_atom_ids": sorted(hard),
        "query_coverage_atom_ids": sorted(coverage),
        "dependency_closed_atom_ids": sorted(hard_closure),
        "budget_rejected_atoms": budget_rejected,
        "unsupported_shapes": unsupported,
        "trailer_projection": projection,
        "exact_source_spans": True,
    }
    return core, spans, details, projected_trailer


def _combine(core: str, trailer: str) -> str:
    if core and trailer:
        return f"{core} {trailer}"
    return core or trailer


def render_peer_attributed_prose(text: str) -> str:
    """Render selected named-peer turns as one attributed prose stream.

    This changes presentation topology, not selected evidence.  It retains the
    explicit speaker for every selected turn and leaves non-turn material
    untouched.  Curly quotation marks avoid colliding with ordinary ASCII
    quotations already present in the source text.
    """

    rendered = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        match = re.match(
            r"^([A-Za-z][A-Za-z ._-]{0,31}):\s*(.*)$", line)
        if match:
            speaker, body = match.groups()
            line = f"{speaker} said: “{body}”"
        rendered.append(line)
    return " ".join(rendered)


def _portable_span_offsets(source: str, spans: Sequence[dict]) -> list[dict]:
    """Attach explicit UTF-8 byte offsets to Python code-point spans."""

    positions = sorted({
        position for span in spans for position in (span["start"], span["end"])
    })
    utf8_offsets: dict[int, int] = {}
    previous = 0
    byte_offset = 0
    for position in positions:
        byte_offset += len(source[previous:position].encode("utf-8"))
        utf8_offsets[position] = byte_offset
        previous = position
    result = []
    for span in spans:
        item = dict(span)
        start = item["start"]
        end = item["end"]
        item["start_utf8_byte"] = utf8_offsets[start]
        item["end_utf8_byte"] = utf8_offsets[end]
        result.append(item)
    return result


def candidate_rows(record: EstateRecord) -> dict[str, dict]:
    """Generate every attributed candidate row for one estate record."""

    decision = classify_record(record.content)
    units = semantic_units(record.content, decision)
    p23_units = p23_sentence_units(record.content)
    stored_body, trailer = split_enrichment(record.distilled)
    original_bytes = len(record.content.encode("utf-8"))
    digest = source_digest(record.content)

    current = record.distilled.strip()
    core_text, core_spans, core_details = p23_core(p23_units)
    mmr_text, mmr_spans, mmr_details = freq_mmr(
        units, original_bytes, len(trailer.encode("utf-8")))
    intent_text, intent_spans, intent_details, intent_trailer = intent_span(
        record.content, trailer)
    v23_text, v23_spans, v23_details, v23_trailer = intent_span(
        record.content, trailer, peer_dialogue=True)
    attributed_text = (
        render_peer_attributed_prose(v23_text)
        if v23_details.get("mode") == "peer-dialogue" else v23_text
    )
    attributed_details = dict(v23_details)
    attributed_details["rendering"] = (
        "inline-attributed-prose"
        if v23_details.get("mode") == "peer-dialogue" else "source-exact"
    )
    variants = {
        "p23-current": (stored_body, current,
                        [{"unit_index": unit.index, "start": unit.start,
                          "end": unit.end, "kind": unit.kind} for unit in units],
                        {"selection": "stored-p23-current"}, trailer),
        "p23-core": (core_text, _combine(core_text, trailer),
                     core_spans, core_details, trailer),
        "freq-mmr": (mmr_text, _combine(mmr_text, trailer),
                     mmr_spans, mmr_details, trailer),
        "intent-span": (intent_text, _combine(intent_text, intent_trailer),
                        intent_spans, intent_details, intent_trailer),
        "intent-span-v23": (v23_text, _combine(v23_text, v23_trailer),
                            v23_spans, v23_details, v23_trailer),
        "intent-span-v23-attributed": (
            attributed_text, _combine(attributed_text, v23_trailer),
            v23_spans, attributed_details, v23_trailer,
        ),
    }
    result = {}
    for candidate, (core, combined, spans, details, applied_trailer) in variants.items():
        combined_bytes = len(combined.encode("utf-8"))
        candidate_ruleset = (
            INTENT_SPAN_VERSION if candidate == "intent-span"
            else INTENT_SPAN_V23_VERSION if candidate == "intent-span-v23"
            else INTENT_SPAN_V23_ATTRIBUTED_VERSION
            if candidate == "intent-span-v23-attributed"
            else RULESET_VERSION
        )
        result[candidate] = {
            "schema_version": 1,
            "converter_version": CONVERTER_VERSION,
            "ruleset_version": candidate_ruleset,
            # Canonical Model-Plus/Terra contract fields.  The legacy-shaped
            # aliases below remain for human inspection and converter tests.
            "converter_id": f"{candidate}@{candidate_ruleset}",
            "candidate": candidate,
            "drawer_id": record.drawer_id,
            "source_sha256": digest,
            "original": record.content,
            "event_time": record.event_time,
            "shape": decision.as_dict(),
            "span_offset_unit": "unicode-code-point",
            "span_utf8_offset_unit": "byte",
            "selected_source_spans": _portable_span_offsets(
                record.content, spans
            ),
            "compact_core": core,
            # Raw p2.3 trailer is retained for audit even when intent-span's
            # stricter source/type projection rejects some or all fields.
            "enrichment_trailer": trailer,
            "applied_enrichment_trailer": applied_trailer,
            "ai_text": combined,
            "mining_body": combined,
            "metrics": {
                "original_bytes": original_bytes,
                "original_tokens_est": estimate_tokens(record.content),
                "core_bytes": len(core.encode("utf-8")),
                # ``trailer_bytes`` is the legacy raw-trailer measurement.
                # Keep it stable and expose the actually applied size
                # separately so intent-span compression is auditable.
                "trailer_bytes": len(trailer.encode("utf-8")),
                "applied_trailer_bytes": len(
                    applied_trailer.encode("utf-8")
                ),
                "distilled_bytes": combined_bytes,
                "distilled_tokens_est": estimate_tokens(combined),
                "compression_ratio_ppm": (
                    combined_bytes * 1_000_000 // original_bytes
                    if original_bytes else 0
                ),
            },
            "selection_details": details,
        }
    return result


def _readonly_connection(path: Path) -> sqlite3.Connection:
    resolved = path.resolve(strict=True)
    uri = f"file:{quote(str(resolved), safe='/')}?mode=ro&immutable=1"
    connection = sqlite3.connect(uri, uri=True)
    connection.execute("PRAGMA query_only = ON")
    return connection


def read_estate(path: Path, bed: str,
                manifest_path: Path | None = None) -> list[EstateRecord]:
    """Read canonical drawer fields without creating SQLite sidecars."""

    with _readonly_connection(path) as connection:
        rows = connection.execute(
            "SELECT id, content, distilled, eventTime FROM drawers "
            "WHERE tombstonedAt IS NULL ORDER BY id"
        ).fetchall()
    records = [EstateRecord(str(drawer_id), content or "", distilled or "",
                            event_time)
               for drawer_id, content, distilled, event_time in rows]
    if bed == "blind200":
        if manifest_path is None:
            raise ValueError("blind200 requires --manifest")
        manifest = load_manifest(manifest_path)
        by_id = {record.drawer_id: record for record in records}
        expected_ids = [record["drawer_id"] for record in manifest["records"]]
        if len(by_id) != len(records) or set(by_id) != set(expected_ids):
            raise ValueError(
                "blind200 estate IDs do not exactly match the manifest")
        ordered = []
        for expected in manifest["records"]:
            record = by_id[expected["drawer_id"]]
            if source_digest(record.content) != expected["source_sha256"]:
                raise ValueError(
                    f"blind200 source digest mismatch for {record.drawer_id}")
            if record.event_time != expected["event_time"]:
                raise ValueError(
                    f"blind200 event time mismatch for {record.drawer_id}")
            ordered.append(record)
        records = ordered
    elif bed == "debug7":
        records = [record for record in records
                   if record.drawer_id.startswith(DEBUG7_PREFIXES)]
        if len(records) != 7:
            raise ValueError(f"Debug-7 resolved {len(records)} records, expected 7")
    elif bed not in {"sample30", "all"}:
        raise ValueError(f"unsupported bed: {bed}")
    if bed == "sample30" and len(records) != 30:
        raise ValueError(f"sample30 estate has {len(records)} live records, expected 30")
    return records


def _write_jsonl(path: Path, rows: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    descriptor = os.open(
        temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            for row in rows:
                handle.write(json.dumps(
                    row, ensure_ascii=False, sort_keys=True,
                    separators=(",", ":")))
                handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def convert_estate(estate: Path, bed: str, output: Path,
                   manifest_path: Path | None = None,
                   candidates: Sequence[str] = CANDIDATES) -> dict[str, Path]:
    """Generate one harness-ready overlay per candidate."""

    records = read_estate(estate, bed, manifest_path)
    selected_candidates = tuple(candidates)
    unknown = set(selected_candidates) - set(CANDIDATES)
    if not selected_candidates or unknown:
        raise ValueError(f"unsupported candidates: {sorted(unknown)}")
    if bed == "blind200" and selected_candidates != ("intent-span",):
        raise ValueError("blind200 is frozen to the intent-span candidate")
    by_candidate = {candidate: [] for candidate in selected_candidates}
    for record in records:
        rows = candidate_rows(record)
        for candidate in selected_candidates:
            by_candidate[candidate].append(rows[candidate])
    paths = {}
    for candidate in selected_candidates:
        path = output / f"{bed}-{candidate}.jsonl"
        _write_jsonl(path, by_candidate[candidate])
        paths[candidate] = path
    return paths


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--estate", required=True, type=Path,
                        help="SQLite estate opened with mode=ro&immutable=1")
    parser.add_argument("--bed", required=True,
                        choices=("debug7", "sample30", "blind200", "all"))
    parser.add_argument("--manifest", type=Path,
                        help="required frozen input manifest for blind200")
    parser.add_argument("--candidate", action="append", choices=CANDIDATES,
                        help="candidate to emit; repeatable (default: all)")
    parser.add_argument("--output", required=True, type=Path,
                        help="sidecar output directory; never an estate path")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    paths = convert_estate(
        args.estate, args.bed, args.output, args.manifest,
        args.candidate or CANDIDATES)
    for candidate in paths:
        print(f"{candidate}\t{paths[candidate]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

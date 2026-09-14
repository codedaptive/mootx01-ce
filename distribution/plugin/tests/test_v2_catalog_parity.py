"""Fixture-backed parity test: teaching files must only name tools, argument
keys and result fields that exist in the ARIA v2 catalog.

The fixtures under tests/fixtures/ are captured from the real v2 binaries
(Swift and Rust). Any tool name, argument key or field name used in plugin
skill, command, rule, or hook files that is absent from the fixture catalog
fails here, so drift fails a test, not a user.

Guarded shapes, exactly:

1. Inline JSON objects in the markdown files (SKILL.md, mootx01-start.md,
   mootx01-memory.mdc): every backticked `{...}` is parsed with json.loads and
   bound to the nearest preceding backticked `moot_<name>` on the same line.
2. Inline key:value fragments in the markdown files: a backticked
   `"key":value` span is wrapped in braces and parsed the same way. Objects and
   fragments on a line with no tool name bind to the unique catalog tool whose
   inputSchema.properties covers the union of their top-level keys; zero or
   several candidates is a failure naming the file and line.
   Keys are checked recursively: nested objects and array items are validated
   against the property's schema ($ref, oneOf and items are followed), so a
   dataset predicate's `col`/`op`/`val` are checked, not just counted.
3. Fenced code blocks: none of the three markdown files contains one. The
   census test scans every `{...}` in the raw text and fails on any object
   that the inline extractor did not read, so a fenced object is reported
   rather than silently skipped.
4. Prose identifiers: every backticked single identifier in the markdown files
   (pattern ^[a-z][a-z0-9_]*$, not a tool name) must be a key in some tool's
   inputSchema.properties or a field name somewhere in some tool's
   outputSchema, unless it is in the documented allowlist.
5. Hook handlers: every `tool_input.get("<key>")` inside a `mode_<word>`
   function that hooks.json binds to a `mcp__.*__moot_<name>` matcher is an
   argument key read from that tool's call. Hook-protocol objects elsewhere in
   moot_hooks.py (state files, decision/reason output) are not tool arguments
   and are never attributed.

Run with:
    cd distribution/plugin && python3 -m pytest tests -q
Add -s to see the per-file checked-keys report and the census.
"""
import ast
import json
import os
import re
import shlex
import shutil
import tempfile
import unittest
from typing import NamedTuple

_FIXTURES_DIR = os.path.join(os.path.dirname(__file__), "fixtures")
_PLUGIN_DIR = os.path.join(os.path.dirname(__file__), "..")

# Registry artifact that records the catalog identity the fixtures must match.
# Reading this file at test time (not pasting the digest literal) proves the
# fixture was captured from the server that the registry pins — not from an
# older build that happened to have the same schema.
_REGISTRY_JSON = os.path.normpath(os.path.join(
    _PLUGIN_DIR, "..", "..", "packages", "kits", "AriaMcpKit", "Registry",
    "aria-v2-selected-release.json"
))

_HOOKS_JSON = os.path.join(_PLUGIN_DIR, "hooks", "hooks.json")
_HOOKS_PY = os.path.join(_PLUGIN_DIR, "hooks", "moot_hooks.py")
_SKILL_MD = os.path.join(_PLUGIN_DIR, "skills", "mootx01-memory", "SKILL.md")

# Teaching files that are searched for `moot_*` tool name mentions and
# argument objects.
_TEACHING_FILES = [
    _SKILL_MD,
    os.path.join(_PLUGIN_DIR, "commands", "mootx01-start.md"),
    os.path.join(_PLUGIN_DIR, "rules", "mootx01-memory.mdc"),
    _HOOKS_PY,
    _HOOKS_JSON,
    os.path.join(_PLUGIN_DIR, "hooks", "moot_update_check.py"),
]

# V1-only tokens that must not appear anywhere in teaching files. These are
# substring bans: `location_prefix` has no prose use in the v2 bundle.
# The seven retired tool names are also banned from the distribution/plugin
# teaching files. TestAgentSkillsNameGate enforces the same constraint across
# the agent-skills directory via its per-file catalog-membership check.
_V1_FORBIDDEN = [
    "location_prefix",
    "moot_file_packet",
    "moot_packet_get",
    "moot_packet_lineage",
    "moot_packet_list",
    "moot_run_migration",
    "moot_confirm_migration",
    "moot_federated_search",
]
# V1-only argument keys. `id` is banned only where it is used as an argument:
# a top-level key of an extracted argument object, or a `tool_input.get("id")`
# read in a bound hook handler. Prose such as "packet `id`" is fine.
_V1_FORBIDDEN_ARGUMENT_KEYS = ["id"]
# "teachme" as an argument key or call target (not as a substring in prose).
# The v2 bundle legitimately writes "teachme is gone" as negative guidance.
_V1_FORBIDDEN_PATTERNS = [
    r'"teachme"\s*:', r"'teachme'\s*:", r"\bteachme\s*=", r"\bteachme\s*\(",
]

_BACKTICK_SPAN = re.compile(r"`([^`]+)`")
# A bare tool name: must end in a letter so `moot_lens_*` is not matched.
_TOOL_NAME = re.compile(r"^moot_(?:[a-z]+_)*[a-z]+$")
# The tool name at the end of a hooks.json matcher such as `mcp__.*__moot_file_memory`.
_MATCHER_TOOL = re.compile(r"__(moot_(?:[a-z]+_)*[a-z]+)$")
# A backticked key:value fragment such as `"where":{...}`; wrapped in braces it is an object.
_FRAGMENT = re.compile(r'^"[A-Za-z_][A-Za-z0-9_]*"\s*:')
# A backticked prose identifier such as `memory_id` or `has_more`.
_PROSE_IDENTIFIER = re.compile(r"^[a-z][a-z0-9_]*$")
# Backticked prose words that are neither an argument key nor a result field.
# Each entry states why the word is legitimate teaching text.
_PROSE_IDENTIFIER_ALLOWLIST = {
    "teachme": "the removed v1 argument, named only as negative guidance (SKILL.md)",
    "retryable": "error-envelope recovery field named in SKILL.md recovery guidance; "
                 "no tool outputSchema in the fixtures declares it",
    "mootx01": "the binary and Homebrew formula name (mootx01-start.md)",
    "full": "a valid enum value of the moot_memory_get `depth` parameter; "
            "it is a depth level name, not a schema property key",
}
# Hook-protocol fields written by moot_hooks.py that are never tool arguments.
_HOOK_PROTOCOL_FIELDS = frozenset({"decision", "reason", "fired", "compacted", "stop_nagged"})

_NON_TOOL_NAMES = frozenset({
    # Python hook module and script names, not MCP tool calls.
    "moot_hooks",
    "moot_update_check",
    # `moot_lens_*` appears in prose as a wildcard pattern for the lens family.
    # The bare `moot_lens` is not a real tool; the catalog has moot_lens_<name> entries.
    "moot_lens",
})


def _load_catalog(fixture_name: str) -> dict:
    """Load a tools/list fixture and return a mapping of tool name to tool entry."""
    path = os.path.join(_FIXTURES_DIR, fixture_name)
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    result = data.get("result", data)
    tools = result.get("tools", [])
    return {t["name"]: t for t in tools}


def _schema_properties(tool_entry: dict) -> dict:
    """Return inputSchema.properties for a catalog tool entry (empty if absent)."""
    schema = tool_entry.get("inputSchema") or tool_entry.get("input_schema") or {}
    return schema.get("properties", {})


def _teaching_text() -> str:
    """Return concatenated content of all teaching files."""
    parts = []
    for p in _TEACHING_FILES:
        with open(p, encoding="utf-8") as f:
            parts.append(f.read())
    return "\n".join(parts)


def _extract_moot_tool_names(text: str) -> list[str]:
    """Return all distinct `moot_*` tool name candidates found in `text`.

    Only considers identifiers that end with a letter (not underscore), to
    avoid matching wildcard patterns like `moot_lens_*` that appear in prose.
    Known non-tool names (Python script names) are excluded.
    """
    candidates = set(re.findall(r"\bmoot_(?:[a-z]+_)*[a-z]+", text))
    return sorted(candidates - _NON_TOOL_NAMES)


class ArgumentUse(NamedTuple):
    """One argument object attributed to one tool at one file line.

    `obj` is the parsed object (for a hook read, {key: None}); `span` is the
    source text the object came from, used by the census to prove coverage.
    """
    file: str
    line: int
    tool: str
    obj: dict
    span: str


def _markdown_argument_uses(path: str, catalog: dict):
    """Extract argument objects from a markdown teaching file.

    Walks each line's backticked spans in order. A span that is a bare
    `moot_<name>` sets the current tool for the rest of the line. A span that
    is a `{...}` object, or a `"key":value` fragment (wrapped in braces), is
    parsed with json.loads. Placeholder values such as "<question>" are
    ordinary JSON strings and `{}` is a valid object with no keys. Other spans
    (`fetch.arguments`, `memory_id`) yield nothing here.

    An object seen after a tool name on its line binds to that tool. Objects
    seen with no tool name on their line bind, together, to the unique catalog
    tool whose inputSchema.properties covers the union of their top-level
    keys. Returns (uses, errors): an object that does not parse, or that
    cannot be bound to exactly one tool, is an error naming the file and line.
    """
    uses, errors = [], []
    base = os.path.basename(path)
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    for lineno, line in enumerate(lines, 1):
        tool = None
        unbound = []
        for m in _BACKTICK_SPAN.finditer(line):
            span = m.group(1)
            if _TOOL_NAME.match(span) and span not in _NON_TOOL_NAMES:
                tool = span
                continue
            if span.startswith("{") and span.endswith("}"):
                text = span
            elif _FRAGMENT.match(span):
                text = "{" + span + "}"
            else:
                continue
            try:
                obj = json.loads(text)
            except json.JSONDecodeError as exc:
                errors.append(
                    f"{base}:{lineno}: argument object does not parse as JSON "
                    f"({exc.msg}): {span}")
                continue
            if tool is None:
                unbound.append((span, obj))
            else:
                uses.append(ArgumentUse(base, lineno, tool, obj, span))
        if unbound:
            keys = set()
            for _, obj in unbound:
                keys |= set(obj.keys())
            candidates = sorted(
                name for name, entry in catalog.items()
                if keys and keys <= set(_schema_properties(entry)))
            if len(candidates) == 1:
                for span, obj in unbound:
                    uses.append(ArgumentUse(base, lineno, candidates[0], obj, span))
            else:
                errors.append(
                    f"{base}:{lineno}: argument object with no tool name on its line; "
                    f"key set {sorted(keys)} matches {candidates or 'no tool'}: "
                    + "; ".join(span for span, _ in unbound))
    return uses, errors


def _hook_bound_modes(hooks_json_path: str) -> dict[str, str]:
    """Return {mode word: tool name} for every hooks.json entry whose matcher
    ends in `__moot_<name>` and whose command runs `moot_hooks.py <mode>`.

    hooks.json is read with json.load; the matcher and command values are
    plain strings and are inspected as strings.
    """
    with open(hooks_json_path, encoding="utf-8") as f:
        hooks = json.load(f)
    bound = {}
    for entries in hooks.get("hooks", {}).values():
        for entry in entries:
            tm = _MATCHER_TOOL.search(entry.get("matcher", ""))
            if not tm:
                continue
            for hook in entry.get("hooks", []):
                parts = shlex.split(hook.get("command", ""))
                for i, part in enumerate(parts[:-1]):
                    if os.path.basename(part) == "moot_hooks.py":
                        bound[parts[i + 1]] = tm.group(1)
    return bound


def _hook_argument_uses(hooks_json_path: str, hooks_py_path: str):
    """Extract `tool_input.get("<key>")` reads from bound hook handlers.

    For each mode that hooks.json binds to a `moot_<name>` matcher, the
    `def mode_<word>` function (hyphens become underscores) in moot_hooks.py is
    located with the ast module and every `tool_input.get("<literal>")` call in
    its body is an argument key read from that tool's call. Only calls on a
    name spelled `tool_input` count, so state-file and decision/reason objects
    elsewhere in the module are never attributed.

    Returns (uses, errors) in the same shape as _markdown_argument_uses. A bound
    mode with no matching function is an error.
    """
    bound = _hook_bound_modes(hooks_json_path)
    base = os.path.basename(hooks_py_path)
    with open(hooks_py_path, encoding="utf-8") as f:
        tree = ast.parse(f.read(), filename=hooks_py_path)
    funcs = {node.name: node for node in tree.body if isinstance(node, ast.FunctionDef)}
    uses, errors = [], []
    for mode, tool in sorted(bound.items()):
        fname = "mode_" + mode.replace("-", "_")
        func = funcs.get(fname)
        if func is None:
            errors.append(
                f"{base}: hooks.json binds mode '{mode}' to {tool} but no "
                f"`def {fname}` exists")
            continue
        for node in ast.walk(func):
            if (isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "get"
                    and isinstance(node.func.value, ast.Name)
                    and node.func.value.id == "tool_input"
                    and node.args
                    and isinstance(node.args[0], ast.Constant)
                    and isinstance(node.args[0].value, str)):
                key = node.args[0].value
                uses.append(ArgumentUse(base, node.lineno, tool, {key: None},
                                        f'tool_input.get("{key}")'))
    return uses, errors


def _argument_uses(path: str, catalog: dict):
    """Dispatch argument extraction by file type.

    Markdown files go through _markdown_argument_uses; moot_hooks.py goes
    through _hook_argument_uses against the shipped hooks.json; every other
    teaching file (hooks.json itself, moot_update_check.py) carries tool names
    only and yields no argument uses.
    """
    base = os.path.basename(path)
    if base.endswith((".md", ".mdc")):
        return _markdown_argument_uses(path, catalog)
    if base == "moot_hooks.py":
        return _hook_argument_uses(_HOOKS_JSON, path)
    return [], []


def _expand_schema(schema, root: dict) -> list[dict]:
    """Flatten a JSON schema node into the plain object schemas it may denote,
    following `$ref` (local `#/$defs/...`), `oneOf`, `anyOf` and `allOf`."""
    if not isinstance(schema, dict):
        return []
    if "$ref" in schema:
        target = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            target = target.get(part, {}) if isinstance(target, dict) else {}
        return _expand_schema(target, root)
    out = [schema]
    for combinator in ("oneOf", "anyOf", "allOf"):
        for branch in schema.get(combinator, []) or []:
            out.extend(_expand_schema(branch, root))
    return out


def _unknown_keys(value, schemas: list[dict], root: dict, prefix: str) -> list[str]:
    """Return dotted paths of keys in `value` that none of `schemas` declares.

    Objects are checked against the union of `properties` across the candidate
    schemas; a value whose schemas declare no properties is unconstrained.
    Array items are checked against the union of `items` schemas.
    """
    unknown = []
    if isinstance(value, dict):
        declared = {}
        for s in schemas:
            for key, sub in (s.get("properties") or {}).items():
                declared.setdefault(key, []).append(sub)
        if not declared:
            return unknown
        for key, child in value.items():
            path = f"{prefix}.{key}" if prefix else key
            if key not in declared:
                unknown.append(path)
                continue
            subs = [x for sub in declared[key] for x in _expand_schema(sub, root)]
            unknown.extend(_unknown_keys(child, subs, root, path))
    elif isinstance(value, list):
        items = [x for s in schemas for x in _expand_schema(s.get("items"), root)]
        for i, child in enumerate(value):
            unknown.extend(_unknown_keys(child, items, root, f"{prefix}[{i}]"))
    return unknown


def checked_keys_by_file(paths=None, catalog=None) -> dict[str, dict[str, list[str]]]:
    """Return {file basename: {tool name: sorted distinct top-level keys}} for
    the argument keys the schema check reads from each teaching file."""
    catalog = catalog if catalog is not None else _load_catalog("swift_tools_list.json")
    report = {}
    for path in (paths or _TEACHING_FILES):
        uses, _ = _argument_uses(path, catalog)
        per_tool = report.setdefault(os.path.basename(path), {})
        for use in uses:
            per_tool[use.tool] = sorted(set(per_tool.get(use.tool, [])) | set(use.obj.keys()))
    return report


def _all_depth_keys(value, acc: set) -> set:
    """Collect every object key in `value` at any depth into `acc`."""
    if isinstance(value, dict):
        for key, child in value.items():
            acc.add(key)
            _all_depth_keys(child, acc)
    elif isinstance(value, list):
        for child in value:
            _all_depth_keys(child, acc)
    return acc


def _argument_key_failures(path: str, catalogs: dict[str, dict]) -> list[str]:
    """Check every argument key extracted from `path` against each catalog of
    {port label: catalog}, recursively through nested objects and arrays.

    Returns failure strings: extraction errors, tools absent from a catalog,
    and key paths absent from the tool's inputSchema. Empty means clean.
    """
    failures = []
    for port, catalog in catalogs.items():
        uses, errors = _argument_uses(path, catalog)
        failures.extend(f"{port}: {e}" for e in errors)
        for use in uses:
            entry = catalog.get(use.tool)
            if entry is None:
                failures.append(f"{use.file}:{use.line}: tool '{use.tool}' is not in the {port} catalog")
                continue
            schema = entry.get("inputSchema") or entry.get("input_schema") or {}
            for key_path in _unknown_keys(use.obj, _expand_schema(schema, schema), schema, ""):
                failures.append(
                    f"{use.file}:{use.line}: tool '{use.tool}' argument key '{key_path}' "
                    f"not in {port} inputSchema.properties")
    return failures


def _forbidden_argument_key_uses(path: str, catalog: dict) -> list[str]:
    """Return one string per v1-only top-level argument key used in `path`."""
    uses, _ = _argument_uses(path, catalog)
    return [
        f"{use.file}:{use.line}: tool '{use.tool}' uses v1 argument key '{key}'"
        for use in uses
        for key in use.obj if key in _V1_FORBIDDEN_ARGUMENT_KEYS
    ]


def _brace_objects(text: str) -> list[tuple[int, str]]:
    """Census: every brace-balanced `{...}` in `text` at nesting depth zero of
    the scan, as (line number, object text). Reads raw text, so it sees objects
    inside and outside backticks and inside fenced code blocks alike."""
    objects = []
    i = 0
    while i < len(text):
        if text[i] != "{":
            i += 1
            continue
        depth, j = 0, i
        while j < len(text):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        objects.append((text.count("\n", 0, i) + 1, text[i:j + 1]))
        i = j + 1
    return objects


def _unread_brace_objects(path: str, catalog: dict) -> list[str]:
    """Return every brace object in `path` that no ArgumentUse span contains."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    uses, _ = _argument_uses(path, catalog)
    base = os.path.basename(path)
    return [
        f"{base}:{lineno}: {obj}"
        for lineno, obj in _brace_objects(text)
        if not any(use.line == lineno and obj in use.span for use in uses)
    ]


def _catalog_field_union(catalog: dict) -> set[str]:
    """Every tool's inputSchema.properties keys, plus every `properties` key
    found at any depth of every tool's outputSchema."""
    union = set()
    for entry in catalog.values():
        union |= set(_schema_properties(entry))
        stack = [entry.get("outputSchema")]
        while stack:
            node = stack.pop()
            if isinstance(node, dict):
                props = node.get("properties")
                if isinstance(props, dict):
                    union |= set(props.keys())
                stack.extend(node.values())
            elif isinstance(node, list):
                stack.extend(node)
    return union


def _unresolved_prose_identifiers(path: str, fields: set[str]) -> list[str]:
    """Return file:line strings for every backticked single identifier in a
    markdown file that is not a tool name, not allowlisted, and not in `fields`."""
    base = os.path.basename(path)
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    unresolved = []
    for lineno, line in enumerate(lines, 1):
        for m in _BACKTICK_SPAN.finditer(line):
            word = m.group(1)
            if not _PROSE_IDENTIFIER.match(word) or word.startswith("moot_"):
                continue
            if word in _PROSE_IDENTIFIER_ALLOWLIST or word in fields:
                continue
            unresolved.append(
                f"{base}:{lineno}: `{word}` is not an argument key or result field of any v2 tool")
    return unresolved


def _pair_count(per_tool: dict[str, list[str]]) -> int:
    """Number of distinct (tool, key) pairs in one file's report row."""
    return sum(len(keys) for keys in per_tool.values())


class TestV2CatalogParity(unittest.TestCase):
    """Every tool name and argument key used in teaching files must exist in the
    v2 catalog fixture, and v1-only names must be absent.

    Checks performed:
    - Every moot_* tool name in teaching files exists in both port catalogs.
    - Every taught argument key exists in that tool's inputSchema.properties in both ports.
    - The v1 substring `location_prefix` is absent.
    - `id` is not used as an argument key.
    - "teachme" as an argument key or call target is absent (prose mentions are fine).
    """

    @classmethod
    def setUpClass(cls):
        cls.swift_catalog = _load_catalog("swift_tools_list.json")
        cls.rust_catalog = _load_catalog("rust_tools_list.json")
        cls.catalogs = {"swift": cls.swift_catalog, "rust": cls.rust_catalog}
        cls.text = _teaching_text()
        cls.tool_names = _extract_moot_tool_names(cls.text)

    def test_catalogs_have_tools(self):
        """Sanity: fixtures must contain exactly 80 tools each (v2 post-int9 count).

        An exact count catches both directions: a fixture that regained the
        four retired packet operations (84 tools) passes a >=80 floor but
        fails here. The Swift twin already pins this value exactly in
        PermissionsWriterTests.swift (realTools.count == 80).
        """
        self.assertEqual(len(self.swift_catalog), 80,
            f"Swift fixture has {len(self.swift_catalog)} tools, expected exactly 80; "
            "re-capture the fixture from the current server build")
        self.assertEqual(len(self.rust_catalog), 80,
            f"Rust fixture has {len(self.rust_catalog)} tools, expected exactly 80; "
            "re-capture the fixture from the current server build")

    def test_catalogs_are_identical(self):
        """Swift and Rust fixtures must expose the same tool names, and for every
        tool the same inputSchema and the same description."""
        swift_names = set(self.swift_catalog)
        rust_names = set(self.rust_catalog)
        only_swift = swift_names - rust_names
        only_rust = rust_names - swift_names
        self.assertEqual(only_swift, set(),
            f"Tools in Swift but not Rust: {sorted(only_swift)}")
        self.assertEqual(only_rust, set(),
            f"Tools in Rust but not Swift: {sorted(only_rust)}")
        differences = []
        for name in sorted(swift_names):
            sw, rs = self.swift_catalog[name], self.rust_catalog[name]
            if sw.get("inputSchema") != rs.get("inputSchema"):
                sw_props = sorted(_schema_properties(sw))
                rs_props = sorted(_schema_properties(rs))
                differences.append(
                    f"{name}: inputSchema differs (swift properties {sw_props}, "
                    f"rust properties {rs_props})")
            if sw.get("description") != rs.get("description"):
                differences.append(
                    f"{name}: description differs\n  swift: {sw.get('description')!r}\n"
                    f"  rust:  {rs.get('description')!r}")
        self.assertEqual(differences, [],
            "Port parity: tool contracts differ between fixtures:\n" + "\n".join(differences))

    def test_every_teaching_tool_name_exists_in_catalog(self):
        """Every moot_* name in teaching files must be in both v2 catalogs."""
        missing = [n for n in self.tool_names
                   if n not in self.swift_catalog or n not in self.rust_catalog]
        self.assertEqual(missing, [],
            f"Teaching files reference tool names not in the v2 catalog: {missing}\n"
            f"Fix the teaching file or update the fixture if the catalog changed.")

    def test_v1_forbidden_names_absent(self):
        """V1-only substrings must not appear in teaching files."""
        found = [tok for tok in _V1_FORBIDDEN if tok in self.text]
        self.assertEqual(found, [],
            f"V1-only names found in teaching files: {found}\n"
            "Remove v1 guidance from skill/command/rule/hook files.")

    def test_v1_id_argument_key_absent(self):
        """`id` must not be taught as an argument key: not as a top-level key of a
        backticked argument object, not as a tool_input.get("id") in a bound hook.
        Prose mentions such as packet `id` are not argument uses."""
        found = []
        for path in _TEACHING_FILES:
            found.extend(_forbidden_argument_key_uses(path, self.swift_catalog))
        self.assertEqual(found, [],
            "V1 argument keys used in teaching files:\n" + "\n".join(found))

    def test_teachme_not_used_as_argument_or_call(self):
        """'teachme' must not appear as an argument key or call target.
        Prose such as 'teachme is gone' is legitimate v2 negative guidance;
        only 'teachme': or teachme() patterns are banned."""
        violations = []
        for pattern in _V1_FORBIDDEN_PATTERNS:
            matches = re.findall(pattern, self.text)
            if matches:
                violations.extend(matches)
        self.assertEqual(violations, [],
            f"'teachme' used as argument key or call in teaching files: {violations}\n"
            "Remove v1 argument key usage; prose 'teachme is gone' is allowed.")

    def test_every_argument_key_exists_in_catalog_schema(self):
        """Every argument key the teaching text uses must exist in that tool's
        inputSchema.properties in both port catalogs.

        Keys come from backticked argument objects in the markdown files and
        from tool_input.get reads in bound hook handlers (see module docstring).
        A non-emptiness floor guards the check itself: SKILL.md must yield at
        least 10 (tool, key) pairs and all files together at least 12, so the
        test cannot pass because extraction found nothing.
        """
        failures = []
        for path in _TEACHING_FILES:
            failures.extend(_argument_key_failures(path, self.catalogs))
        self.assertEqual(failures, [],
            "Unknown argument keys in teaching files:\n" + "\n".join(failures))
        report = checked_keys_by_file()
        skill_pairs = _pair_count(report["SKILL.md"])
        total_pairs = sum(_pair_count(row) for row in report.values())
        self.assertGreaterEqual(skill_pairs, 10,
            f"SKILL.md yielded only {skill_pairs} (tool, key) pairs; the extractor "
            f"is not reading the call-pattern table")
        self.assertGreaterEqual(total_pairs, 12,
            f"All teaching files yielded only {total_pairs} (tool, key) pairs")

    def test_checked_keys_report_is_nonempty_per_markdown_file(self):
        """Print the per-file checked-keys report (visible with pytest -s):
        objects read, (tool, key) pairs, distinct keys at all depths, and keys
        per tool. Assert every markdown teaching file has a row. SKILL.md
        carries the call-pattern table and must have keys; mootx01-start.md
        and mootx01-memory.mdc teach tool names without argument objects, so
        their rows are present and empty."""
        report = checked_keys_by_file()
        print("\nChecked argument keys per teaching file:")
        for path in _TEACHING_FILES:
            base = os.path.basename(path)
            uses, _ = _argument_uses(path, self.swift_catalog)
            row = report.get(base, {})
            depth_keys = set()
            for use in uses:
                _all_depth_keys(use.obj, depth_keys)
            print(f"  {base}: {len(uses)} argument objects, {_pair_count(row)} (tool, key) pairs, "
                  f"{len(depth_keys)} distinct keys at all depths")
            if depth_keys:
                print(f"    distinct keys: {', '.join(sorted(depth_keys))}")
            for tool, keys in sorted(row.items()):
                print(f"    {tool}: {', '.join(keys) if keys else '(no keys)'}")
        for path in _TEACHING_FILES:
            base = os.path.basename(path)
            if base.endswith((".md", ".mdc")):
                self.assertIn(base, report, f"{base}: missing from checked-keys report")
        self.assertGreater(_pair_count(report["SKILL.md"]), 0,
            "SKILL.md must contribute checked argument keys")

    def test_census_every_brace_object_is_read(self):
        """Every `{...}` in the raw text of each markdown teaching file, inside
        or outside backticks or code fences, must be inside a span the
        extractor turned into an ArgumentUse. Prints the census (pytest -s)
        and fails listing any object the extractor skipped."""
        skipped = []
        print("\nBrace-object census per markdown file:")
        for path in _TEACHING_FILES:
            base = os.path.basename(path)
            if not base.endswith((".md", ".mdc")):
                continue
            with open(path, encoding="utf-8") as f:
                objects = _brace_objects(f.read())
            print(f"  {base}: {len(objects)} brace objects at lines "
                  f"{sorted({lineno for lineno, _ in objects})}")
            skipped.extend(_unread_brace_objects(path, self.swift_catalog))
        self.assertEqual(skipped, [],
            "Brace objects the extractor did not read:\n" + "\n".join(skipped))

    def test_prose_identifiers_resolve_to_catalog_fields(self):
        """Every backticked single identifier in the three markdown files that
        is not a tool name must be an inputSchema.properties key of some tool
        or a field name at any depth of some tool's outputSchema, in both
        ports, unless it is in _PROSE_IDENTIFIER_ALLOWLIST."""
        unresolved = []
        for port, catalog in self.catalogs.items():
            fields = _catalog_field_union(catalog)
            for path in _TEACHING_FILES:
                if os.path.basename(path).endswith((".md", ".mdc")):
                    unresolved.extend(f"{port}: {u}" for u in _unresolved_prose_identifiers(path, fields))
        self.assertEqual(unresolved, [],
            "Prose identifiers not in any tool contract:\n" + "\n".join(unresolved))

    def test_file_memory_keys_are_pinned(self):
        """The keys attributed to moot_file_memory are exactly content,
        location and subject from SKILL.md and location from moot_hooks.py.
        The hook-protocol fields moot_hooks.py writes to its state file and
        decision output (decision, reason, fired, compacted, stop_nagged) are
        present in the module source and are never attributed to any tool."""
        report = checked_keys_by_file()
        self.assertEqual(report["SKILL.md"].get("moot_file_memory"),
                         ["content", "location", "subject"])
        self.assertEqual(report["moot_hooks.py"], {"moot_file_memory": ["location"]})
        for base, row in report.items():
            if base not in ("SKILL.md", "moot_hooks.py"):
                self.assertNotIn("moot_file_memory", row,
                    f"{base}: unexpected moot_file_memory argument keys {row.get('moot_file_memory')}")
        attributed = set()
        for row in report.values():
            for keys in row.values():
                attributed |= set(keys)
        self.assertEqual(attributed & _HOOK_PROTOCOL_FIELDS, set(),
            "hook-protocol fields attributed as tool arguments")
        with open(_HOOKS_PY, encoding="utf-8") as f:
            source = f.read()
        for field in sorted(_HOOK_PROTOCOL_FIELDS):
            self.assertIn(f'"{field}"', source,
                f"moot_hooks.py no longer writes \"{field}\"; the exclusion is untested")

    def _mutated_skill_copy(self, tmpdir: str, original: str, replacement: str) -> str:
        """Copy SKILL.md into tmpdir with one table cell replaced. Asserts the
        original text was present so the mutation is known to have applied."""
        with open(_SKILL_MD, encoding="utf-8") as f:
            content = f.read()
        self.assertIn(original, content, "mutation anchor not found in SKILL.md")
        copy = os.path.join(tmpdir, "SKILL.md")
        with open(copy, "w", encoding="utf-8") as f:
            f.write(content.replace(original, replacement, 1))
        return copy

    def test_mutation_unknown_key_in_table_cell_fails(self):
        """The production check must report an unknown key written into a
        SKILL.md table cell. The moot_memory_search row is mutated in a temp
        copy and checked through the same helper the real test uses."""
        with tempfile.TemporaryDirectory() as tmpdir:
            clean = os.path.join(tmpdir, "clean.md")
            shutil.copy(_SKILL_MD, clean)
            self.assertEqual(_argument_key_failures(clean, self.catalogs), [],
                "control: the unmutated copy must be clean")
            mutated = self._mutated_skill_copy(
                tmpdir,
                '`moot_memory_search` | `{"query":"<question>"}`',
                '`moot_memory_search` | `{"query":"<question>","bogus_key":1}`')
            failures = _argument_key_failures(mutated, self.catalogs)
        hits = [f for f in failures if "bogus_key" in f and "moot_memory_search" in f]
        self.assertEqual(len(hits), 2,
            f"expected bogus_key reported against moot_memory_search for both ports, got: {failures}")

    def test_mutation_id_argument_key_fails(self):
        """`id` written as an argument key in a SKILL.md table cell must be
        reported by the v1 key check and by the schema check."""
        with tempfile.TemporaryDirectory() as tmpdir:
            mutated = self._mutated_skill_copy(
                tmpdir,
                '`{"memory_id":"<memory UUID>"}`',
                '`{"id":"<memory UUID>"}`')
            forbidden = _forbidden_argument_key_uses(mutated, self.swift_catalog)
            failures = _argument_key_failures(mutated, self.catalogs)
        self.assertTrue(any("moot_memory_get" in f and "'id'" in f for f in forbidden),
            f"v1 key check did not report id: {forbidden}")
        self.assertTrue(any("moot_memory_get" in f and "'id'" in f for f in failures),
            f"schema check did not report id: {failures}")

    def test_mutation_unparseable_object_fails(self):
        """A backticked object that is not valid JSON is a failure naming the
        file and line, not a silently skipped example."""
        with tempfile.TemporaryDirectory() as tmpdir:
            mutated = self._mutated_skill_copy(
                tmpdir,
                '`{"query":"<question>"}`; relevance',
                '`{"query":<question>}`; relevance')
            failures = _argument_key_failures(mutated, self.catalogs)
        self.assertTrue(any("does not parse as JSON" in f and "SKILL.md:22" in f for f in failures),
            f"parse failure not reported with file and line: {failures}")

    def test_mutation_nested_predicate_key_fails(self):
        """A wrong nested key inside the dataset `where` fragment on SKILL.md
        L48 must be reported with its dotted path, proving the fragment shape
        is validated through $ref and oneOf, not merely counted."""
        with tempfile.TemporaryDirectory() as tmpdir:
            mutated = self._mutated_skill_copy(
                tmpdir,
                '`"where":{"col":"status","op":"eq","val":"ready"}`',
                '`"where":{"column":"status","op":"eq","val":"ready"}`')
            failures = _argument_key_failures(mutated, self.catalogs)
        hits = [f for f in failures if "'where.column'" in f and "moot_dataset_query" in f
                and "SKILL.md:48" in f]
        self.assertEqual(len(hits), 2,
            f"expected where.column reported against moot_dataset_query for both ports, got: {failures}")

    def test_mutation_prose_identifier_rename_fails(self):
        """Renaming `intent` on SKILL.md L12 to a word no tool contract carries
        must be reported by the prose identifier check naming SKILL.md:12.

        The substitute is `intention`: `intents` cannot serve because it is a
        real field of moot_help's outputSchema and resolves cleanly. Both facts
        are asserted so the gate's premise is checked, not assumed."""
        fields = _catalog_field_union(self.swift_catalog)
        self.assertIn("intents", fields, "intents is expected as a moot_help output field")
        self.assertNotIn("intention", fields, "the mutation word must be absent from every contract")
        with tempfile.TemporaryDirectory() as tmpdir:
            clean = os.path.join(tmpdir, "clean.md")
            shutil.copy(_SKILL_MD, clean)
            self.assertEqual(_unresolved_prose_identifiers(clean, fields), [],
                "control: the unmutated copy must be clean")
            mutated = self._mutated_skill_copy(tmpdir, "`intent`", "`intention`")
            unresolved = _unresolved_prose_identifiers(mutated, fields)
        self.assertTrue(any(u.startswith("SKILL.md:12:") and "`intention`" in u for u in unresolved),
            f"prose check did not report SKILL.md:12 `intention`: {unresolved}")

    def test_hook_binding_reads_file_memory_location(self):
        """hooks.json binds plan-filed to moot_file_memory, and mode_plan_filed
        reads tool_input.get("location"); that pair must be what the hook
        extractor yields."""
        self.assertEqual(_hook_bound_modes(_HOOKS_JSON), {"plan-filed": "moot_file_memory"})
        self.assertEqual(checked_keys_by_file([_HOOKS_PY], self.swift_catalog)["moot_hooks.py"],
                         {"moot_file_memory": ["location"]})

    def test_moot_update_memory_uses_memory_id_not_id(self):
        """Any teaching of moot_update_memory must use `memory_id`, not `id`."""
        # Only enforce this in sections that also mention moot_update_memory.
        # A bare `"id"` elsewhere (e.g. JSON-RPC id) is fine; the pattern
        # guards against teaching the wrong argument name.
        for path in _TEACHING_FILES:
            with open(path, encoding="utf-8") as f:
                content = f.read()
            if "moot_update_memory" not in content:
                continue
            # Within lines that teach moot_update_memory arguments, "id" as a
            # standalone argument key is forbidden.
            for lineno, line in enumerate(content.splitlines(), 1):
                if re.search(r'\bid\s*[=:]', line) and "memory_id" not in line:
                    self.fail(
                        f"{path}:{lineno}: uses `id` argument near moot_update_memory; "
                        f"use `memory_id` (v2 schema). Line: {line.strip()}"
                    )

    def test_moot_memory_list_uses_wing_not_location_prefix(self):
        """Any teaching of moot_memory_list must use `wing`, not `location_prefix`."""
        for path in _TEACHING_FILES:
            with open(path, encoding="utf-8") as f:
                content = f.read()
            self.assertNotIn("location_prefix", content,
                f"{path}: contains v1 `location_prefix` key; use `wing` (v2 schema)")


class TestFixtureProvenance(unittest.TestCase):
    """Smoke-check the fixture files themselves."""

    def _assert_present(self, name: str):
        path = os.path.join(_FIXTURES_DIR, name)
        self.assertTrue(os.path.exists(path), f"Missing fixture: {path}")

    def _load(self, name: str) -> dict:
        with open(os.path.join(_FIXTURES_DIR, name), encoding="utf-8") as f:
            data = json.load(f)
        return data.get("result", data)["structuredContent"]["data"]

    def test_swift_fixture_present(self):
        self._assert_present("swift_tools_list.json")

    def test_rust_fixture_present(self):
        self._assert_present("rust_tools_list.json")

    def test_swift_help_fixture_present(self):
        self._assert_present("swift_moot_help.json")

    def test_rust_help_fixture_present(self):
        self._assert_present("rust_moot_help.json")

    def test_swift_memory_list_fixture_present(self):
        self._assert_present("swift_memory_list.json")

    def test_rust_memory_list_fixture_present(self):
        self._assert_present("rust_memory_list.json")

    def test_swift_memory_get_fixture_present(self):
        self._assert_present("swift_memory_get.json")

    def test_rust_memory_get_fixture_present(self):
        self._assert_present("rust_memory_get.json")

    def test_swift_memory_list_page1_fixture_present(self):
        self._assert_present("swift_memory_list_page1.json")

    def test_rust_memory_list_page1_fixture_present(self):
        self._assert_present("rust_memory_list_page1.json")

    def test_swift_memory_list_page2_fixture_present(self):
        self._assert_present("swift_memory_list_page2.json")

    def test_rust_memory_list_page2_fixture_present(self):
        self._assert_present("rust_memory_list_page2.json")

    def test_swift_memory_get_batch_fixture_present(self):
        self._assert_present("swift_memory_get_batch.json")

    def test_rust_memory_get_batch_fixture_present(self):
        self._assert_present("rust_memory_get_batch.json")

    def test_swift_file_memory_fixture_present(self):
        self._assert_present("swift_file_memory.json")

    def test_rust_file_memory_fixture_present(self):
        self._assert_present("rust_file_memory.json")

    def test_paging_fixtures_shape(self):
        """For both ports: page1 has has_more true and a next_cursor string,
        page2 has has_more false, and the get batch holds 50 records each with
        placement.room, content and state."""
        for port in ("swift", "rust"):
            page1 = self._load(f"{port}_memory_list_page1.json")
            self.assertIs(page1.get("has_more"), True, f"{port} page1: has_more must be true")
            self.assertIsInstance(page1.get("next_cursor"), str,
                f"{port} page1: next_cursor must be a string")
            page2 = self._load(f"{port}_memory_list_page2.json")
            self.assertIs(page2.get("has_more"), False, f"{port} page2: has_more must be false")
            batch = self._load(f"{port}_memory_get_batch.json")["memories"]
            self.assertEqual(len(batch), 50, f"{port} batch: expected 50 records")
            for i, record in enumerate(batch):
                self.assertIn("room", record.get("placement", {}),
                    f"{port} batch[{i}]: placement.room missing")
                self.assertIn("content", record, f"{port} batch[{i}]: content missing")
                self.assertIn("state", record, f"{port} batch[{i}]: state missing")

    # ------------------------------------------------------------------
    # Finding A: bind fixture digests to the authoritative registry pin
    # ------------------------------------------------------------------

    def _help_digest(self, fixture_name: str) -> str:
        """Return result.structuredContent.meta.capability_digest from a help fixture."""
        with open(os.path.join(_FIXTURES_DIR, fixture_name), encoding="utf-8") as f:
            data = json.load(f)
        return data["result"]["structuredContent"]["meta"]["capability_digest"]

    def _registry_identity(self) -> str:
        """Return catalogIdentity from the authoritative registry artifact."""
        with open(_REGISTRY_JSON, encoding="utf-8") as f:
            reg = json.load(f)
        return reg["catalogIdentity"]

    def _help_operations(self, fixture_name: str) -> dict:
        """Return {operation name: operation entry} from a moot_help fixture.

        Each entry carries input_schema (the help fixture's spelling of the
        key that tools_list fixtures call inputSchema).
        """
        with open(os.path.join(_FIXTURES_DIR, fixture_name), encoding="utf-8") as f:
            data = json.load(f)
        ops = data["result"]["structuredContent"]["data"].get("operations", [])
        return {o["name"]: o for o in ops}

    def test_swift_tools_list_names_match_help_names(self):
        """swift_tools_list.json and swift_moot_help.json must describe the same catalog:
        identical name sets and identical per-operation inputSchema.

        The name check catches a rename in one fixture but not the other. The
        schema check catches an added or renamed argument key: the digest gate
        names the help fixture, so if the catalog moves and only the help
        fixture is recaptured, the tools_list schema stays stale. All 80 input
        schemas match today; this assertion goes red if one fixture is
        recaptured and the other is not. When either check fails, recapture
        both swift_tools_list.json AND swift_moot_help.json from the same server.
        """
        tl = _load_catalog("swift_tools_list.json")
        ops = self._help_operations("swift_moot_help.json")
        self.assertEqual(
            set(tl.keys()),
            set(ops.keys()),
            "swift_tools_list.json tool names do not match swift_moot_help.json "
            "operation names. Recapture both fixtures from the same server.",
        )
        # Per-operation schema comparison. tools_list carries inputSchema; help
        # carries input_schema. Report the operation name, not just a boolean.
        mismatches = [
            name for name in tl
            if tl[name].get("inputSchema") != ops[name].get("input_schema")
        ]
        self.assertEqual(
            mismatches,
            [],
            "inputSchema mismatch between swift_tools_list.json and "
            "swift_moot_help.json for operations: "
            + ", ".join(mismatches)
            + ". Recapture both fixtures from the same server.",
        )

    def test_rust_tools_list_names_match_help_names(self):
        """rust_tools_list.json and rust_moot_help.json must describe the same catalog:
        identical name sets and identical per-operation inputSchema.

        See test_swift_tools_list_names_match_help_names for the rationale.
        When either check fails, recapture both rust_tools_list.json AND
        rust_moot_help.json from the same server.
        """
        tl = _load_catalog("rust_tools_list.json")
        ops = self._help_operations("rust_moot_help.json")
        self.assertEqual(
            set(tl.keys()),
            set(ops.keys()),
            "rust_tools_list.json tool names do not match rust_moot_help.json "
            "operation names. Recapture both fixtures from the same server.",
        )
        mismatches = [
            name for name in tl
            if tl[name].get("inputSchema") != ops[name].get("input_schema")
        ]
        self.assertEqual(
            mismatches,
            [],
            "inputSchema mismatch between rust_tools_list.json and "
            "rust_moot_help.json for operations: "
            + ", ".join(mismatches)
            + ". Recapture both fixtures from the same server.",
        )

    def test_swift_help_digest_matches_registry(self):
        """swift_moot_help.json capability_digest must equal catalogIdentity in the registry.

        When the catalog moves and the fixture is not recaptured, this digest
        changes in the registry but not in the fixture, making the test go red.
        The fix is to recapture the fixture from a server advertising the
        new catalog, not to update the literal in this file. Recapture both
        swift_moot_help.json AND swift_tools_list.json so both fixtures reflect
        the same catalog (test_swift_tools_list_names_match_help_names gates that).
        """
        self.assertEqual(
            self._help_digest("swift_moot_help.json"),
            self._registry_identity(),
            "swift_moot_help.json capability_digest does not match catalogIdentity in "
            f"{_REGISTRY_JSON}. Recapture both swift_moot_help.json and "
            "swift_tools_list.json from a server at the registered catalog.",
        )

    def test_rust_help_digest_matches_registry(self):
        """rust_moot_help.json capability_digest must equal catalogIdentity in the registry.

        Recapture both rust_moot_help.json AND rust_tools_list.json so both
        fixtures reflect the same catalog.
        """
        self.assertEqual(
            self._help_digest("rust_moot_help.json"),
            self._registry_identity(),
            "rust_moot_help.json capability_digest does not match catalogIdentity in "
            f"{_REGISTRY_JSON}. Recapture both rust_moot_help.json and "
            "rust_tools_list.json from a server at the registered catalog.",
        )

    def test_both_ports_help_digests_equal(self):
        """Swift and Rust help fixtures must carry the same capability_digest.

        A mismatch means one port was recaptured from a different catalog than
        the other; the teaching is tracking two different server builds at once.
        """
        self.assertEqual(
            self._help_digest("swift_moot_help.json"),
            self._help_digest("rust_moot_help.json"),
            "Swift and Rust moot_help fixtures carry different capability_digest values; "
            "both must be recaptured from the same catalog.",
        )


class TestV2MemoryEnvelope(unittest.TestCase):
    """Parser contract tests: both port fixtures must expose the v2 envelope shape."""

    def _load_fixture(self, name: str) -> dict:
        path = os.path.join(_FIXTURES_DIR, name)
        with open(path, encoding="utf-8") as f:
            return json.load(f)

    def _unwrap(self, fixture: dict) -> dict:
        """Strip the JSON-RPC envelope; return the result object."""
        return fixture.get("result", fixture)

    def _check_memory_list_envelope(self, fixture_name: str):
        data = self._load_fixture(fixture_name)
        result = self._unwrap(data)
        structured = result.get("structuredContent", {})
        d = structured.get("data", {})
        memories = d.get("memories")
        self.assertIsNotNone(memories,
            f"{fixture_name}: must have result.structuredContent.data.memories")
        self.assertIsInstance(memories, list)
        self.assertGreater(len(memories), 0, f"{fixture_name}: memories list must not be empty")
        for mem in memories:
            self.assertIn("memory_id", mem, f"{fixture_name}: row must have memory_id")
            self.assertIn("fetch", mem, f"{fixture_name}: row must have fetch reference")
            self.assertNotIn("location", mem,
                f"{fixture_name}: v2 list row must NOT have location; use moot_memory_get")
            self.assertNotIn("content", mem,
                f"{fixture_name}: v2 list row must NOT have content; use moot_memory_get")
            self.assertNotIn("superseded", mem,
                f"{fixture_name}: v2 list row must NOT have superseded; use state from moot_memory_get")

    def _check_memory_get_envelope(self, fixture_name: str):
        data = self._load_fixture(fixture_name)
        result = self._unwrap(data)
        structured = result.get("structuredContent", {})
        d = structured.get("data", {})
        memories = d.get("memories", [])
        self.assertGreater(len(memories), 0,
            f"{fixture_name}: must have at least one record at result.structuredContent.data.memories")
        mem = memories[0]
        self.assertIn("memory_id", mem, f"{fixture_name}: record must have memory_id")
        placement = mem.get("placement", {})
        self.assertIn("room", placement,
            f"{fixture_name}: placement must have room (= full original location string)")
        self.assertIn("wing", placement, f"{fixture_name}: placement must have wing")
        self.assertEqual(placement.get("wing"), "Agentic Memory",
            f"{fixture_name}: wing must be 'Agentic Memory' for harness-import locations")
        self.assertIn("content", mem, f"{fixture_name}: record must have content")
        self.assertIn("event_time", mem, f"{fixture_name}: record must have event_time")
        self.assertIn("state", mem, f"{fixture_name}: record must have state (active/superseded)")

    def test_swift_memory_list_v2_envelope(self):
        """Swift fixture must expose result.structuredContent.data.memories with v2 row shape."""
        self._check_memory_list_envelope("swift_memory_list.json")

    def test_rust_memory_list_v2_envelope(self):
        """Rust fixture must expose result.structuredContent.data.memories with v2 row shape."""
        self._check_memory_list_envelope("rust_memory_list.json")

    def test_swift_memory_get_v2_envelope(self):
        """Swift fixture must expose placement.room at result.structuredContent.data.memories[0]."""
        self._check_memory_get_envelope("swift_memory_get.json")

    def test_rust_memory_get_v2_envelope(self):
        """Rust fixture must expose placement.room at result.structuredContent.data.memories[0]."""
        self._check_memory_get_envelope("rust_memory_get.json")

    def test_both_ports_memory_list_have_same_row_keys(self):
        """Both port list fixtures must have the same key sets in their memory rows."""
        swift = self._load_fixture("swift_memory_list.json")
        rust = self._load_fixture("rust_memory_list.json")
        sw_mems = self._unwrap(swift)["structuredContent"]["data"]["memories"]
        rs_mems = self._unwrap(rust)["structuredContent"]["data"]["memories"]
        sw_keys = set(sw_mems[0].keys())
        rs_keys = set(rs_mems[0].keys())
        self.assertEqual(sw_keys, rs_keys,
            f"Port parity: Swift row keys {sw_keys} != Rust row keys {rs_keys}")


# ---------------------------------------------------------------------------
# Paths used by the new gate tests
# ---------------------------------------------------------------------------

_REPO_ROOT = os.path.abspath(os.path.join(_PLUGIN_DIR, "..", ".."))

# The embedded Rust install bundle that is the canonical source of the skill.
_INSTALL_BUNDLE_V2 = os.path.join(
    _REPO_ROOT, "apps", "mootx01", "rust", "src", "embedded", "install-bundle-v2.json"
)

_AGENT_SKILLS_ROOT = os.path.join(_REPO_ROOT, "apps", "moot-agent-skills")

# The Swift packager source that enumerates the files composing the v2 skill bundle.
_LOADER_SWIFT = os.path.normpath(os.path.join(
    _PLUGIN_DIR, "..", "..", "tools", "moot-packager", "Sources", "MootPackagerCore",
    "Loader.swift"
))


def _derive_loader_paths() -> set:
    """Extract the file paths that Loader.swift reads to compose the v2 skill bundle.

    Matches two constructs in the loader source:
    1. try read("literal-path") calls — the v2 shared body and the generic wrapper
       (lines with string interpolation, such as the v1 try read("shared/\\($0)"),
       are excluded by refusing backslash in the captured group).
    2. wrapperPaths dictionary values — "kebab-host": "relative/path" entries
       at the wrapperPaths literal.

    Returns a set of paths prefixed with apps/moot-agent-skills/ using os.path.join,
    so the result compares cleanly with the os.path.join entries in _PACKAGER_FILES.
    """
    with open(_LOADER_SWIFT, encoding="utf-8") as f:
        source = f.read()
    prefix = os.path.join("apps", "moot-agent-skills")
    # Construct 1: try read("literal-path") — backslash excluded to skip
    # Swift string interpolation calls such as try read("shared/\($0)").
    read_paths = re.findall(r'try read\("([^"\\]+)"\)', source)
    # Construct 2: wrapperPaths dictionary values — "host-id": "path/value".
    # The key class is wider than the six host ids in use, all of which are
    # kebab-case: a wrapper keyed camelCase or with a single character would
    # otherwise leave the derived set at eight, and the equality assertion
    # below would pass while the new wrapper went ungated — silently, in the
    # one case this derivation exists to catch. A key shape this does not
    # match reduces the derived set and trips the floor instead.
    wrapper_values = re.findall(r'"[A-Za-z][A-Za-z0-9-]*"\s*:\s*"([^"]+)"', source)
    return {os.path.join(prefix, p) for p in read_paths + wrapper_values}


class TestSkillDriftGate(unittest.TestCase):
    """The shipped plugin skill must match the embedded Rust install bundle.

    In normal operation both files are generated by tools/moot-packager from the
    same composed teaching source
    (apps/moot-agent-skills/shared/aria-v2/HOW_TO_USE_MOOTX01.md plus host
    wrappers). When the two strings differ it means one was hand-edited or a
    packager run was not committed.

    When the two copies have already diverged, the embedded copy inside the Rust
    install bundle is the one to trust: it is the copy the installer actually
    ships to the user's machine. A divergence is repaired by editing the teaching
    source and running tools/moot-packager/regen.sh to regenerate both files, then
    committing the result.

    Comparison is rstripped so a trailing newline difference does not cause
    a spurious failure.
    """

    def test_skill_md_matches_embedded_bundle(self):
        """SKILL.md rstripped must equal the skillMarkdown string in
        install-bundle-v2.json rstripped."""
        with open(_INSTALL_BUNDLE_V2, encoding="utf-8") as f:
            bundle = json.load(f)
        embedded = bundle.get("skillMarkdown", "")
        self.assertNotEqual(embedded, "",
            f"install-bundle-v2.json at {_INSTALL_BUNDLE_V2} has no 'skillMarkdown' key")

        with open(_SKILL_MD, encoding="utf-8") as f:
            shipped = f.read()

        self.assertEqual(
            shipped.rstrip("\n"),
            embedded.rstrip("\n"),
            "distribution/plugin/skills/mootx01-memory/SKILL.md does not match "
            "the skillMarkdown string in apps/mootx01/rust/src/embedded/install-bundle-v2.json. "
            "Both are generated from the teaching source in "
            "apps/moot-agent-skills/shared/aria-v2/HOW_TO_USE_MOOTX01.md. "
            "Edit the teaching source and run tools/moot-packager/regen.sh to "
            "regenerate both files, then commit the result.",
        )


class TestAgentSkillsNameGate(unittest.TestCase):
    """Every moot_* token in the agent-skills teaching files must be a valid
    catalog member.

    This catches stale tool names (retired packet operations, old migration
    and federation names) that an agent reading the file would try to call
    and fail on. The catalog source of truth is the Swift tools/list fixture,
    which is the int9 tag-gate capture of 80 operations.

    The failure message names the file, the line, and the offending token so
    the author knows exactly where to update.
    """

    # Token names that are Python module filenames or hook identifiers,
    # not real MCP tool names. Same set as _NON_TOOL_NAMES above.
    _NON_TOOL = frozenset({
        "moot_hooks",         # Python hook module filename (moot_hooks.py)
        "moot_update_check",  # Python hook module filename (moot_update_check.py)
        "moot_lens",          # prose wildcard prefix, not a tool name
    })

    @classmethod
    def setUpClass(cls):
        cls.catalog = _load_catalog("swift_tools_list.json")

    def test_agent_skills_tool_names_are_catalog_members(self):
        """Every moot_[a-z_]+ token in every file under apps/moot-agent-skills
        must be one of the 80 names in the fixture catalog.

        The gate walks the full tree so that new files cannot introduce stale
        names without a test failure. Files that cannot be decoded as UTF-8
        (binary assets) are skipped silently.

        Failures name the file, the line, and the offending token.
        """
        pattern = re.compile(r"\bmoot_(?:[a-z]+_)*[a-z]+")
        violations = []
        # A moved or renamed teaching directory would make os.walk yield
        # nothing, and the gate would pass having inspected no bytes. The
        # counts below (file count and token count) are what make an empty
        # violations list mean something. The named-file assertion below is a
        # second belt: the count catches the whole tree moving, and naming
        # all eight packager-composed files catches any one of them going
        # missing without the count falling enough to trip the floor.
        files_read = 0
        tokens_seen = 0
        files_walked: set[str] = set()
        for dirpath, _dirnames, filenames in os.walk(_AGENT_SKILLS_ROOT):
            for fname in filenames:
                path = os.path.join(dirpath, fname)
                try:
                    with open(path, encoding="utf-8") as f:
                        lines = f.read().splitlines()
                except (UnicodeDecodeError, PermissionError):
                    continue
                files_read += 1
                rel = os.path.relpath(path, _REPO_ROOT)
                files_walked.add(rel)
                for lineno, line in enumerate(lines, 1):
                    for m in pattern.finditer(line):
                        token = m.group(0)
                        tokens_seen += 1
                        if token in self._NON_TOOL:
                            continue
                        if token not in self.catalog:
                            violations.append(
                                f"{rel}:{lineno}: '{token}' is not in the v2 catalog"
                            )

        self.assertGreater(files_read, 50,
            f"only {files_read} readable files under {_AGENT_SKILLS_ROOT}; the "
            "teaching tree moved and this gate inspected almost nothing")
        self.assertGreater(tokens_seen, 500,
            f"only {tokens_seen} moot_ tokens found across {files_read} files; "
            "the teaching files no longer name operations and this gate is vacuous")

        # The packager composes eight files under apps/moot-agent-skills for v2:
        # the shared body and one wrapper per supported host. The full list is at
        # tools/moot-packager/Sources/MootPackagerCore/Loader.swift:185-199.
        # Every one ships to a user and every one names operations, so all eight
        # must be in the walk. A count floor alone cannot catch a single file
        # going missing; naming each path here makes the gate exhaustive.
        _PACKAGER_FILES = [
            os.path.join("apps", "moot-agent-skills", "shared", "aria-v2", "HOW_TO_USE_MOOTX01.md"),
            os.path.join("apps", "moot-agent-skills", "generic", "custom-instructions.md"),
            os.path.join("apps", "moot-agent-skills", "claude", "CLAUDE.md"),
            os.path.join("apps", "moot-agent-skills", "cline", ".clinerules", "00-mootx01-memory.md"),
            os.path.join("apps", "moot-agent-skills", "codex", "AGENTS.md"),
            os.path.join("apps", "moot-agent-skills", "cursor", ".cursorrules"),
            os.path.join("apps", "moot-agent-skills", "gemini", "GEMINI.md"),
            os.path.join("apps", "moot-agent-skills", "github-copilot", ".github", "copilot-instructions.md"),
        ]

        # Derive the expected set from Loader.swift so that a new host wrapper
        # added to the loader fails this test until _PACKAGER_FILES is updated too.
        # The extraction reads try read("literal-path") calls (the shared body and
        # the generic wrapper) and wrapperPaths dictionary values; both construct
        # sets are narrow literal-quoting matches that fail loudly if the loader's
        # shape changes rather than silently matching the wrong strings.
        derived = _derive_loader_paths()
        self.assertGreaterEqual(
            len(derived), 8,
            f"Only {len(derived)} paths derived from Loader.swift "
            "(tools/moot-packager/Sources/MootPackagerCore/Loader.swift); "
            "the try read() call structure or the wrapperPaths shape has changed "
            "and _derive_loader_paths() needs updating to match the new constructs."
        )
        packager_set = set(_PACKAGER_FILES)
        extra = sorted(derived - packager_set)
        missing_from_list = sorted(packager_set - derived)
        self.assertEqual(
            derived,
            packager_set,
            "Paths derived from Loader.swift do not match _PACKAGER_FILES. "
            "If a host wrapper was added to Loader.swift, add it to _PACKAGER_FILES "
            "in this test so the walk assertion remains exhaustive.\n"
            "In Loader.swift but not in _PACKAGER_FILES: " + str(extra) + "\n"
            "In _PACKAGER_FILES but not in Loader.swift: " + str(missing_from_list)
        )

        missing = [p for p in _PACKAGER_FILES if p not in files_walked]
        self.assertEqual(
            missing,
            [],
            "One or more packager-composed teaching files were not found in the walk "
            f"of {_AGENT_SKILLS_ROOT}. Missing paths (relative to repo root):\n"
            + "\n".join(missing)
            + "\n\nThe expected paths mirror tools/moot-packager/Sources/MootPackagerCore/"
            "Loader.swift:185-199. If a host wrapper was added there, add it to "
            "_PACKAGER_FILES in this test.",
        )

        self.assertEqual(violations, [],
            "Agent-skills files reference tool names not in the v2 catalog:\n"
            + "\n".join(violations)
            + "\n\nThe exact wrong answers guarded here are: "
            "moot_file_packet, moot_packet_get, moot_packet_lineage, "
            "moot_packet_list, moot_run_migration, moot_confirm_migration, "
            "moot_federated_search. Update or remove the offending entries.")


class TestSkimDepthGate(unittest.TestCase):
    """The packaged skill must document depth:"skim" on moot_memory_get.

    All shipped copies are checked:
    - distribution/plugin/skills/mootx01-memory/SKILL.md (the installed plugin skill)
    - apps/mootx01/rust/src/embedded/install-bundle-v2.json: the bundle's
      skillMarkdown, every skillMarkdownByHost entry, and every packaged
      packages/*/mootx01-memory/SKILL.md entry (derived from the bundle's
      own structure, so new hosts are automatically included)
    - apps/mootx01/Sources/MootInstallerCore/Generated/EmbeddedArtifactsV2.swift
      (the copy the macOS installer writes, checked independently because a
      partial regen can update the JSON without updating the Swift copy)

    The assertion is structural: 'skim' must appear in the same paragraph as
    'moot_memory_get'. A bare substring match would pass on any stray occurrence
    and is not sufficient. The paragraph must also name the two contract flags,
    'complete' and 'budgetHonored', that describe the skim response shape.

    To repair: edit the teaching source at
    apps/moot-agent-skills/shared/aria-v2/HOW_TO_USE_MOOTX01.md, then run
    tools/moot-packager/regen.sh to regenerate all files and commit the result.

    TEST_SKILL_MD_PATH, TEST_INSTALL_BUNDLE_PATH, and TEST_SWIFT_EMBED_PATH
    redirect the inputs to arbitrary paths so this gate can be proved red
    against base copies (via `git show <sha>:<path>`) without mutating the
    working tree. Do not remove them.
    """

    _SWIFT_EMBED = os.path.join(
        _REPO_ROOT,
        "apps", "mootx01", "Sources", "MootInstallerCore", "Generated",
        "EmbeddedArtifactsV2.swift",
    )

    @staticmethod
    def _extract_swift_bundle_skill(swift_path):
        """Return the skillMarkdown string embedded in EmbeddedArtifactsV2.swift.

        The Swift file stores the install bundle as a single-line string literal
        assigned to `installBundleJSON`. The JSON content is encoded using
        standard C/JSON escape sequences (backslash-quote for double-quote,
        backslash-backslash for a literal backslash, backslash-n for newline).
        Decoding is done in two passes: wrap the raw string body in quotes and
        use json.loads to unescape one layer of string encoding, then json.loads
        a second time to parse the JSON object.
        """
        with open(swift_path, encoding="utf-8") as f:
            for line in f:
                if "installBundleJSON" in line and "public static let" in line:
                    eq = line.index("=")
                    start = line.index('"', eq) + 1
                    end = line.rindex('"')
                    raw = line[start:end]
                    # One layer of Swift/JSON string unescaping, then parse object.
                    inner = json.loads('"' + raw + '"')
                    bundle = json.loads(inner)
                    return bundle.get("skillMarkdown", "")
        return ""

    @staticmethod
    def _enumerate_bundle_copies(bundle):
        """Return (label, text) pairs for every skill-text copy inside the bundle.

        Enumerates:
        - skillMarkdown (the canonical copy)
        - every value under skillMarkdownByHost (per-host compiled copies)
        - every packages entry whose key ends with
          'mootx01-memory/SKILL.md' (per-host packaged files)

        The set is derived from the bundle's own structure so new hosts are
        automatically included when the packager adds them.
        """
        copies = []
        sm = bundle.get("skillMarkdown", "")
        copies.append(("install-bundle-v2.json:skillMarkdown", sm))
        for host, text in bundle.get("skillMarkdownByHost", {}).items():
            copies.append(
                (f"install-bundle-v2.json:skillMarkdownByHost/{host}", text)
            )
        for key, text in bundle.get("packages", {}).items():
            if key.endswith("mootx01-memory/SKILL.md") and isinstance(text, str):
                copies.append((f"install-bundle-v2.json:packages/{key}", text))
        return copies

    def test_packaged_skill_documents_skim_depth_on_memory_get(self):
        """All packaged skill copies must contain a paragraph naming skim,
        moot_memory_get, complete, and budgetHonored in the same paragraph."""
        skill_md_path = os.environ.get("TEST_SKILL_MD_PATH", _SKILL_MD)
        with open(skill_md_path, encoding="utf-8") as f:
            skill_text = f.read()

        install_bundle_path = os.environ.get(
            "TEST_INSTALL_BUNDLE_PATH", _INSTALL_BUNDLE_V2
        )
        with open(install_bundle_path, encoding="utf-8") as f:
            bundle = json.load(f)

        # Derive every skill-text copy from the bundle structure, not a
        # hardcoded count, so a new host added to the packager is automatically
        # included.
        bundle_copies = self._enumerate_bundle_copies(bundle)
        # The expected count is 1 (skillMarkdown) + N (skillMarkdownByHost) + N
        # (packages/*/mootx01-memory/SKILL.md), where N is the number of hosts.
        # The packages entries are one-to-one with skillMarkdownByHost, so the
        # total is always 2*N+1. A missing key or wrong-type value signals a
        # packager regression — a host shipping no skill text is a worse defect
        # than a host shipping stale text.
        n_hosts = len(bundle.get("skillMarkdownByHost", {}))
        self.assertGreater(
            n_hosts, 0,
            "install-bundle-v2.json:skillMarkdownByHost is empty — the packager "
            "emitted no per-host skill copies.",
        )
        expected_copies = 2 * n_hosts + 1
        self.assertEqual(
            len(bundle_copies), expected_copies,
            f"Expected {expected_copies} skill-text copies from the install bundle "
            f"(1 skillMarkdown + {n_hosts} skillMarkdownByHost + {n_hosts} packages "
            f"entries), got {len(bundle_copies)}. "
            f"A host with missing or wrong-type text means a host is shipping no "
            f"skill text — inspect install-bundle-v2.json:skillMarkdownByHost and "
            f":packages and update _enumerate_bundle_copies to match.",
        )
        for label, text in bundle_copies:
            self.assertNotEqual(
                text, "",
                f"install-bundle-v2.json: copy '{label}' is empty — "
                f"this host is shipping no skill text.",
            )

        # The Swift installer artifact embeds the same bundle and is checked
        # independently: a partial regen can update the JSON without updating
        # the Swift copy.
        swift_embed_path = os.environ.get("TEST_SWIFT_EMBED_PATH", self._SWIFT_EMBED)
        swift_skill_text = self._extract_swift_bundle_skill(swift_embed_path)
        self.assertNotEqual(
            swift_skill_text, "",
            f"Could not extract skillMarkdown from {swift_embed_path}. "
            f"Check that the file contains a 'public static let installBundleJSON' "
            f"assignment with the bundle JSON as a single-line string literal.",
        )

        copies = [
            ("distribution/plugin/skills/mootx01-memory/SKILL.md", skill_text),
        ]
        copies.extend(bundle_copies)
        copies.append((
            "apps/mootx01/Sources/MootInstallerCore/Generated/"
            "EmbeddedArtifactsV2.swift:skillMarkdown",
            swift_skill_text,
        ))

        for label, text in copies:
            paragraphs = [p for p in text.split("\n\n") if p.strip()]
            matching = [
                p for p in paragraphs
                if "moot_memory_get" in p and "skim" in p
            ]
            self.assertTrue(
                len(matching) >= 1,
                f"{label}: no paragraph contains both 'moot_memory_get' and 'skim'. "
                f"The teaching source at "
                f"apps/moot-agent-skills/shared/aria-v2/HOW_TO_USE_MOOTX01.md must "
                f"document depth:\"skim\" in the moot_memory_get section; "
                f"run tools/moot-packager/regen.sh to regenerate.",
            )
            para = matching[0]
            for token in ("complete", "budgetHonored"):
                self.assertIn(
                    token, para,
                    f"{label}: the paragraph containing 'moot_memory_get' and 'skim' "
                    f"does not mention '{token}'. "
                    f"Edit apps/moot-agent-skills/shared/aria-v2/HOW_TO_USE_MOOTX01.md "
                    f"and run tools/moot-packager/regen.sh.",
                )


if __name__ == "__main__":
    unittest.main()

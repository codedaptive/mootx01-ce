---
title: MOOTx01 Plugin Distribution Specification
version: 0.1.0
status: active
date: 2026-06-23
description: "Behavioral specification for the MOOTx01 plugin packaging and distribution system: the canonical source, the packager, the three install modes, the platform family taxonomy, and conformance requirements for generated packages."
spec_type: protocol
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/INSTALLER_INTERFACE.md     # the installer that consumes generated packages
  - tools/moot-packager/                      # the generator this spec governs
  - apps/moot-agent-skills/                   # the per-host adapter library
  - docs_internal/specs/PLUGIN_PACKAGING_SPEC_v0.1.md  # internal detailed spec
---

# MOOTx01 Plugin Distribution Specification

The MOOTx01 plugin system is how the ARIA MCP server and its companion skill
reach agentic coding hosts. A single canonical source drives a matrix-driven
generator (`tools/moot-packager`) that emits a distinct, host-compliant package
for each supported host. The `mootx01` installer binary embeds the generated
packages and materializes them at install time according to the user's chosen
depth.

## § 1 — What this spec defines

- The canonical source schema (`capability.json`, `platform-matrix.json`, body files)
- The platform family taxonomy and what each family requires in a conforming package
- The three install modes and their behavioral contracts
- The packager's generation invariants
- Conformance requirements for the generator and the installer

This specification does NOT define:

- Type signatures — those live in the packager source (`Sources/MootPackagerCore/`)
- Per-host submission procedures or external marketplace policies
- Installer CLI flags — see `INSTALLER_INTERFACE.md`

## § 2 — Position in the system

```
Data/canonical/                    ← single source of truth (EE-only)
    capability.json                   capability + marketplace metadata
    platform-matrix.json              one row per host
    skill-mootx01-memory.body.md      skill body
    command-mootx01-start.body.md     command body
    rule-mootx01-memory.body.mdc      rule body (Cursor-specific frontmatter)
        │
        ▼ tools/moot-packager (EE-only, deterministic)
.out/
    skills/<host-id>/SKILL.md         Mode-2 skill drops (all hosts)
    packages/<host-id>/...            Mode-3 native packages (manifestBundle + ideConfig)
    install-map.json                  destination map consumed by the installer
        │
        ▼ EE→CE sync gate
apps/mootx01/Sources/MootInstallerCore/Generated/
    EmbeddedArtifacts.swift           serialized install-bundle.json baked into the binary
        │
        ▼ mootx01 install (at user machine)
~/<host-config>/                   Mode 1: MCP wired only
~/<host-skills>/mootx01-memory/    Mode 2: + skill drop
~/<host-plugin>/                   Mode 3: + full package materialized
```

**Depends on:** `tools/moot-packager`, `MootInstallerCore`, `LatticeLib` (FDC)

**Consumed by:** all nine supported host environments via the installer

## § 3 — Canonical source

All generated output derives exclusively from three files in `Data/canonical/`
and the body files they reference. No generation logic may introduce content
that is not traceable to the canonical source.

`capability.json` — One object describing the MOOTx01 capability:
`name`, `version`, `displayName`, `description`, `namespace`, marketplace
metadata (`homepage`, `repository`, `license`, `keywords`), `author`,
`server` (launch descriptor), `skill` (with `body` ref), `command` (with
`body` ref), `rule` (with `body` ref).

`platform-matrix.json` — An array of host rows, one per supported host.
Each row carries: `id`, `displayName`, `family` (one of the three families
in § 4), `manifest` (nil for hosts with no manifest concept), `mcp`
(package and user targets), `skill` (packagePath + userPath), optional
`command` (packagePath), optional `rules` (packagePath), `distribution`,
`verification`, and `roadmap` (`"1.0"` | `"1.1"`).

Body files — Referenced by filename from the canonical dir. The skill body
must not contain YAML frontmatter (the packager composes frontmatter per
host). The command body is plain markdown. The rule body includes
host-specific frontmatter (Cursor `.mdc` format).

## § 4 — Platform family taxonomy

Three families govern what a conforming Mode-3 package must contain.

**`manifestBundle`** — The host's plugin system is file-based: a manifest
file plus content directories discovered by the host tooling. Conforming
packages MUST contain: the manifest at `manifest.filename`, the MCP config
at `mcp.package.path` (unless `inlineMCP: true`, in which case the MCP map
is embedded in the manifest), the skill at `skill.packagePath`, the command
at `command.packagePath` (when `command` is present in the matrix row),
rules at `rules.packagePath` (when `rules` is present), `CHANGELOG.md`,
and `README.md`. Current manifestBundle hosts: `claude-code`, `cursor`,
`codex`, `gemini-cli`, `antigravity`, `github-copilot` (roadmap 1.1),
`xcode` (roadmap 1.1).

**`moduleCode`** — The host's plugin system requires a host-native code
module (Python `register(ctx)`, TypeScript `AgentPlugin`, or JS module) in
addition to content files. The packager emits the Mode-2 skill drop and a
`SHIM_TODO.md` explaining the gap; it does NOT emit a fake code shim.
Mode-2 fully delivers skill + MCP for these hosts without code. Current
moduleCode hosts: `cline`, `hermes`, `opencode`.

**`ideConfig`** — The host reads configuration from an IDE-managed path
rather than a git-installable package structure. Packages are emitted for
future use but distribution is IDE-mediated (`plugin-import`), not git or
marketplace. Current ideConfig hosts: `xcode` (roadmap 1.1).

## § 5 — Three install modes

The installer supports three install depths, selected interactively or via
`--mode`. The embedded `install-bundle.json` carries the full package tree
for every host.

**Mode 1 — `server`:** Wire the MCP server entry into the host's config
file and write `MOOT.md` to the working directory. No skill or plugin
content is copied. MCP tools are immediately available to the AI client.

**Mode 2 — `skills`:** Everything in Mode 1, plus copy the canonical
`SKILL.md` to the host's user skill directory (`skill.userPath` from the
install map). The skill activates implicit invocation in the host based on
the description field.

**Mode 3 — `plugin`:** Everything in Mode 1, plus materialize the full
Mode-3 package tree from the embedded bundle to the host's plugin directory.
For `manifestBundle` hosts this delivers the manifest, MCP config, skill,
command, rules, changelog, and README as a complete plugin package. For
`moduleCode` hosts the installer falls back to Mode 2 automatically (no
code shim available) and prints an explanation. The package is materialized
at the path derived from `skill.userPath` (three levels up, `mootx01-plugin`
subdirectory).

Mode 3 is the default. The installer detects host presence and applies the
deepest supported mode for each detected host.

## § 6 — Invariants

**I-1:** Generation is deterministic. Identical canonical source inputs
produce byte-identical output trees across runs and machines.

**I-2:** All generated content traces to the canonical source. No generation
logic may introduce data (strings, paths, metadata) not present in
`capability.json`, `platform-matrix.json`, or the referenced body files.

**I-3:** The embedded install bundle is a faithful copy of the most recent
packager output. The EE→CE sync gate is the only path by which bundle
content changes.

**I-4:** The packager never emits a code shim for `moduleCode` hosts. A
`SHIM_TODO.md` is emitted instead.

**I-5:** Mode-2 fallback for `moduleCode` hosts is silent at the MCP/skill
level — the user receives a full skill experience without requiring the
unimplemented shim.

**I-6:** Manifest JSON fields are emitted with deterministic key ordering
(sorted keys, pretty-printed, no escaped slashes).

## § 7 — Behavioral contracts

**B-1:** Adding a new host requires only a new row in `platform-matrix.json`
and a re-run of the packager. No Swift or Rust code changes are required in
the generator for hosts that fit an existing family.

**B-2:** A `roadmap: "1.1"` host row is generated by the packager but not
embedded in the installer bundle until the roadmap milestone ships. The
packager emits it to `.out/` as a design-time artifact.

**B-3:** The packager regeneration step (Stage 3 in § 2) is a required
prerequisite before any CE-side bundle update. The EE→CE sync gate blocks
bundle updates that were not produced by the packager from the canonical
source.

**B-4:** `CHANGELOG.md` and `README.md` are emitted for every
`manifestBundle` and `ideConfig` package. They are not emitted for
`moduleCode` packages (which receive `SHIM_TODO.md` instead).

## § 8 — Conformance requirements

**C-1:** The packager MUST load `capability.json`, `platform-matrix.json`,
and all referenced body files and fail with `PackagerError.missingFile` if
any are absent.

**C-2:** For every host row where `manifest.inlineMCP` is `true`, the
generated manifest MUST embed the MCP server map and a standalone MCP config
file MUST NOT be written.

**C-3:** For every host row where `command` is non-nil and `commandBody` is
loaded, `commands/<commandId>.md` MUST be present in the generated package.

**C-4:** For every host row where `rules` is non-nil and `ruleBody` is
loaded, `rules/<ruleId>.mdc` (or the path in `rules.packagePath`) MUST be
present in the generated package.

**C-5:** The install-map MUST contain one entry per host row, and each entry
MUST include `skillUserPath`, `mcpUserPath`, `mcpUserFormat`, `mcpMapKey`,
and `roadmap`.

**C-6:** The determinism test (`generationIsDeterministic`) MUST pass: two
sequential runs of `Generator.generate(into:)` with identical inputs MUST
produce byte-identical file trees.

**C-7:** Marketplace metadata fields (`homepage`, `repository`, `license`,
`keywords`) from `capability.json` MUST be present in every JSON manifest
for `manifestBundle` hosts where those fields are non-nil.

## § 9 — Out of scope

- Per-host marketplace submission procedures → external to this repo
- Installer CLI command surface → see `INSTALLER_INTERFACE.md`
- Mode-3 platform CLI registration (e.g. `claude plugin install`) → tracked
  as a gap in `INSTALLER_INTERFACE.md`; out of scope for the packager
- `moduleCode` native shim generation → future work, tracked in
  `PLUGIN_PACKAGING_SPEC_v0.1.md § 3.3`

---

*End of MOOTx01 Plugin Distribution Specification.*

# EideticLib Reference Data

The reference data the deterministic lookup pipeline reads. Pure JSON, committed to the kit, frozen at the data version recorded in each file's manifest.

EideticLib grounds a term against the default **MDCC** scheme: `lookup` resolves the term to an entry in the MDCC canon (supplied by LatticeKit) and returns that entry's MDCC code together with its CC0 Wikidata Q-ID. The classification source — the MDCC canon — is CC0/public-domain, so the default scheme ships complete and resolves offline with no licensing obligation. No foreign-licensed (CC-BY-SA) corpus ships in this package.

## Files

### `WikidataSubset.json`

Curated subset of Wikidata Q-IDs used to confirm and enrich the Q-ID carried by a resolved MDCC canon entry. Each entry: a Q-ID (fact), the canonical lowercased label, and a list of aliases (including stemmed forms).

**Licensing:** CC0 1.0 Universal, matching Wikidata's own dedication. No attribution required, no share-alike clause; the file ships freely.

### `SnowballEnglish.json`

Reference input-output pairs for the Snowball English stemmer's Porter2 algorithm. Used by the conformance harness to verify both ports produce byte-identical stemmed output. Derived from the canonical Snowball test corpus published by the Snowball project under BSD-3-Clause.

## Schema versioning

Each file carries `schema_version` and `data_version` at the root. Schema changes require a version bump; data expansion within the schema does not. The EideticLib code pins to the schema version it understands and rejects files with unrecognized schema versions.

## Single source of truth

These files are the canonical reference data for both the Swift and Rust ports. The Swift port loads them via `Bundle.module`. The Rust port loads them at compile time via `include_str!` from this directory. There are no copies, no symlinks, and no duplicate sources. The conformance harness depends on this property.

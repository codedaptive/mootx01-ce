#!/bin/bash
# Regenerates the shared MemPalace fixture palace exercised by BOTH test
# suites (Swift MemPalaceChromaAdapterTests + Rust mem_palace_adapter.rs).
#
# The fixture mirrors the real ~/.mempalace layout:
#   palace/chroma.sqlite3      — ChromaDB subset (collections, segments,
#                                embeddings, embedding_metadata — exactly
#                                the tables/columns the adapter queries)
#   tunnels.json               — two explicit tunnels (one unlabeled)
#   knowledge_graph.sqlite3    — two entities + two triples (one minimal)
#
# Five chroma rows: three drawers (one diary_entry, one with entities +
# float source_mtime, one minimal with the SQLite CURRENT_TIMESTAMP date
# shape) and two closets. Any change here must keep both suites green in
# the same commit — the expected values are asserted literally in both.
set -euo pipefail
cd "$(dirname "$0")"

rm -f palace/chroma.sqlite3 knowledge_graph.sqlite3
mkdir -p palace

sqlite3 palace/chroma.sqlite3 <<'SQL'
CREATE TABLE collections (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    dimension INTEGER,
    database_id TEXT NOT NULL,
    config_json_str TEXT,
    schema_str TEXT
);
CREATE TABLE segments (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    scope TEXT NOT NULL,
    collection TEXT NOT NULL
);
CREATE TABLE embeddings (
    id INTEGER PRIMARY KEY,
    segment_id TEXT NOT NULL,
    embedding_id TEXT NOT NULL,
    seq_id BLOB NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (segment_id, embedding_id)
);
CREATE TABLE embedding_metadata (
    id INTEGER REFERENCES embeddings(id),
    key TEXT NOT NULL,
    string_value TEXT,
    int_value INTEGER,
    float_value REAL,
    bool_value INTEGER,
    PRIMARY KEY (id, key)
);

INSERT INTO collections (id, name, dimension, database_id) VALUES
  ('c-drawers', 'mempalace_drawers', 384, 'db-default'),
  ('c-closets', 'mempalace_closets', 384, 'db-default');

INSERT INTO segments (id, type, scope, collection) VALUES
  ('seg-vec-drawers',  'urn:chroma:segment/vector/hnsw-local-persisted', 'VECTOR',   'c-drawers'),
  ('seg-meta-drawers', 'urn:chroma:segment/metadata/sqlite',             'METADATA', 'c-drawers'),
  ('seg-vec-closets',  'urn:chroma:segment/vector/hnsw-local-persisted', 'VECTOR',   'c-closets'),
  ('seg-meta-closets', 'urn:chroma:segment/metadata/sqlite',             'METADATA', 'c-closets');

INSERT INTO embeddings (id, segment_id, embedding_id, seq_id) VALUES
  (1, 'seg-meta-drawers', 'drawer_alpha_0001', x'01'),
  (2, 'seg-meta-drawers', 'diary_fulcrum_0002', x'02'),
  (3, 'seg-meta-drawers', 'drawer_min_0003',   x'03'),
  (4, 'seg-meta-closets', 'closet_clarity_0004', x'04'),
  (5, 'seg-meta-closets', 'closet_entities_0005', x'05');

-- Row 1: full drawer — entities, float mtime, int chunk index.
INSERT INTO embedding_metadata (id, key, string_value, int_value, float_value) VALUES
  (1, 'chroma:document', 'Alpha decision content with detail.', NULL, NULL),
  (1, 'wing', 'mootx01', NULL, NULL),
  (1, 'hall', 'hall_general', NULL, NULL),
  (1, 'room', 'decisions', NULL, NULL),
  (1, 'filed_at', '2026-05-04T19:58:47.837740', NULL, NULL),
  (1, 'source_file', 'notes/alpha.md', NULL, NULL),
  (1, 'source_mtime', NULL, NULL, 1746678432.25),
  (1, 'chunk_index', NULL, 0, NULL),
  (1, 'added_by', 'skippy', NULL, NULL),
  (1, 'normalize_version', NULL, 3, NULL),
  (1, 'entities', 'Fleet;Skippy', NULL, NULL);

-- Row 2: diary entry (type=diary_entry, hall_diary).
INSERT INTO embedding_metadata (id, key, string_value) VALUES
  (2, 'chroma:document', 'SESSION:2026-05-08 diary body.'),
  (2, 'wing', 'fulcrum'),
  (2, 'hall', 'hall_diary'),
  (2, 'room', 'diary'),
  (2, 'filed_at', '2026-05-08T04:27:12.542283'),
  (2, 'date', '2026-05-08'),
  (2, 'agent', 'skippy'),
  (2, 'topic', 'handoff'),
  (2, 'type', 'diary_entry'),
  (2, 'added_by', 'skippy');

-- Row 3: minimal drawer — no hall; SQLite CURRENT_TIMESTAMP date shape.
INSERT INTO embedding_metadata (id, key, string_value) VALUES
  (3, 'chroma:document', 'Minimal drawer.'),
  (3, 'wing', 'mootx01'),
  (3, 'room', 'storage'),
  (3, 'filed_at', '2026-04-28 02:48:07');

-- Row 4: closet summary with drawer_count.
INSERT INTO embedding_metadata (id, key, string_value, int_value) VALUES
  (4, 'chroma:document', 'clarity|Fleet|summary of twelve drawers', NULL),
  (4, 'wing', 'mootx01', NULL),
  (4, 'room', 'decisions', NULL),
  (4, 'filed_at', '2026-05-04T19:58:47.837740', NULL),
  (4, 'drawer_count', NULL, 12);

-- Row 5: closet with entities.
INSERT INTO embedding_metadata (id, key, string_value, int_value) VALUES
  (5, 'chroma:document', 'Closet five summary.', NULL),
  (5, 'wing', 'fulcrum', NULL),
  (5, 'room', 'diary', NULL),
  (5, 'filed_at', '2026-05-01T00:00:00.000001', NULL),
  (5, 'drawer_count', NULL, 1),
  (5, 'entities', 'Not;Skippy', NULL);
SQL

sqlite3 knowledge_graph.sqlite3 <<'SQL'
CREATE TABLE entities (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    type TEXT DEFAULT 'unknown',
    properties TEXT DEFAULT '{}',
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE triples (
    id TEXT PRIMARY KEY,
    subject TEXT NOT NULL,
    predicate TEXT NOT NULL,
    object TEXT NOT NULL,
    valid_from TEXT,
    valid_to TEXT,
    confidence REAL DEFAULT 1.0,
    source_closet TEXT,
    source_file TEXT,
    source_drawer_id TEXT,
    adapter_name TEXT,
    extracted_at TEXT DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO entities (id, name, type, properties, created_at) VALUES
  ('fleet',  'Fleet',  'unknown', '{}',              '2026-04-28 02:48:07'),
  ('skippy', 'Skippy', 'agent',   '{"role": "ai"}',  '2026-04-28 02:50:08');

INSERT INTO triples (id, subject, predicate, object, valid_from, valid_to,
                     confidence, source_closet, source_file, source_drawer_id,
                     adapter_name, extracted_at) VALUES
  ('t_fleet_works_with_skippy_0001', 'fleet', 'works_with', 'skippy',
   '2026-04-27', NULL, 1.0, 'closet_clarity_0004', 'notes/alpha.md',
   'drawer_alpha_0001', 'general', '2026-04-28 02:48:07'),
  ('t_minimal_0002', 'skippy', 'knows', 'fleet',
   NULL, NULL, 0.75, NULL, NULL, NULL, NULL, NULL);
SQL

cat > tunnels.json <<'JSON'
[
  {
    "id": "aaaa000011112222",
    "source": { "wing": "mootx01", "room": "decisions" },
    "target": { "wing": "fulcrum", "room": "diary" },
    "label": "Decision informs diary handoff",
    "created_at": "2026-05-29T08:38:47.205501+00:00"
  },
  {
    "id": "bbbb000011112222",
    "source": { "wing": "fulcrum", "room": "diary" },
    "target": { "wing": "mootx01", "room": "storage" },
    "label": ""
  }
]
JSON

echo "fixture palace regenerated"

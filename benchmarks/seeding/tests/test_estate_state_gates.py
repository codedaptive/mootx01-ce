"""Gate tests for import_units.estate_state:

G1 — schema version below 20 must be refused, not classified as "verified".
G2 — span coverage predicate must require kind=2 and generation match.

These tests build minimal in-process SQLite fixtures (no estate binary,
no migration) and assert the state returned by estate_state(). They are
designed to FAIL against the unmodified import_units.py and PASS after
changes C1 and C2 land.
"""

import os
import sqlite3
import sys
import tempfile
import unittest

# import_units calls parse_args() at module level (requires --estates-dir) and
# checks MOOTX01_BINARY. Patch both before the import so it loads cleanly.
_saved_argv = sys.argv
sys.argv = ["import_units", "--estates-dir", "/tmp/unused-gate-test"]
_had_binary = "MOOTX01_BINARY" in os.environ
if not _had_binary:
    os.environ["MOOTX01_BINARY"] = "/tmp/unused-gate-binary"

# Reach the seeding package from any working directory.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import import_units  # noqa: E402

sys.argv = _saved_argv
if not _had_binary:
    del os.environ["MOOTX01_BINARY"]


# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

def _make_estate(tmpdir, schema_version=20, n_drawers=3,
                 kind=2, generation_match=True, n_vectors=None):
    """Write a minimal estate.sqlite into tmpdir and return the dir.

    Creates just the tables estate_state() queries:
      drawers, corpus_index_state, vectors, encoder_models,
      vector_generations, _storagekit_migrations.

    All drawers are live (non-tombstoned) with non-empty content.
    All corpus_index_state rows correspond to drawers (encode complete).

    kind=2 is the span-vector kind; kind=1 is a different kind.
    generation_match controls whether v.generation equals the row in
    vector_generations for that model.

    n_vectors defaults to n_drawers (full coverage).
    """
    if n_vectors is None:
        n_vectors = n_drawers

    db_path = os.path.join(tmpdir, "estate.sqlite")
    con = sqlite3.connect(db_path)
    con.executescript("""
        CREATE TABLE drawers (
            id TEXT PRIMARY KEY,
            tombstonedAt TEXT,
            content TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE corpus_index_state (
            drawer_id TEXT PRIMARY KEY
        );
        CREATE TABLE encoder_models (
            model_id TEXT PRIMARY KEY,
            is_active INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE vectors (
            item_id TEXT NOT NULL,
            model_id TEXT NOT NULL,
            kind INTEGER NOT NULL DEFAULT 2,
            generation INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE vector_generations (
            model_id TEXT PRIMARY KEY,
            serving_generation INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE _storagekit_migrations (
            kit_id TEXT NOT NULL,
            version INTEGER NOT NULL
        );
    """)

    # Insert n_drawers live drawers with content.
    for i in range(n_drawers):
        did = f"drawer-{i}"
        con.execute("INSERT INTO drawers VALUES (?, NULL, ?)",
                    (did, f"content {i}"))
        con.execute("INSERT INTO corpus_index_state VALUES (?)", (did,))

    # One active encoder.
    con.execute("INSERT INTO encoder_models VALUES ('model-1', 1)")

    # serving_generation = 1 in vector_generations.
    serving_gen = 1
    con.execute("INSERT INTO vector_generations VALUES ('model-1', ?)",
                (serving_gen,))

    # Insert n_vectors span-vector rows.
    for i in range(n_vectors):
        did = f"drawer-{i}"
        gen = serving_gen if generation_match else serving_gen - 1
        con.execute(
            "INSERT INTO vectors (item_id, model_id, kind, generation) "
            "VALUES (?, 'model-1', ?, ?)",
            (did, kind, gen))

    # Schema version row.
    if schema_version is not None:
        con.execute(
            "INSERT INTO _storagekit_migrations VALUES ('LocusKit', ?)",
            (schema_version,))

    con.commit()
    con.close()
    return tmpdir


# ---------------------------------------------------------------------------
# G1 — schema version gate
# ---------------------------------------------------------------------------

class SchemaVersionGateTests(unittest.TestCase):
    """C1: an estate with LocusKit schema version below 20 must be refused."""

    def test_schema_19_is_refused_not_verified(self):
        """An otherwise-complete estate at schema 19 must NOT return 'verified'.

        At d8f6d322e (before C1) estate_state ignores the migrations table and
        returns ('verified', 3, 3) for this fixture. After C1 it must return
        'schema-old'.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            _make_estate(tmpdir, schema_version=19)
            state, _, _ = import_units.estate_state(tmpdir, 3)
            self.assertNotEqual(
                state, "verified",
                f"schema-19 estate must not be classified as 'verified'; got {state!r}")
            self.assertEqual(
                state, "schema-old",
                f"schema-19 estate must be classified as 'schema-old'; got {state!r}")

    def test_schema_20_is_verified(self):
        """An estate at schema 20 with full coverage returns 'verified'."""
        with tempfile.TemporaryDirectory() as tmpdir:
            _make_estate(tmpdir, schema_version=20)
            state, _, _ = import_units.estate_state(tmpdir, 3)
            self.assertEqual(
                state, "verified",
                f"schema-20 estate with full coverage must be 'verified'; got {state!r}")


# ---------------------------------------------------------------------------
# G2 — span-coverage predicate gate
# ---------------------------------------------------------------------------

class SpanCoveragePredicateTests(unittest.TestCase):
    """C2: estate_state must use the same span predicate as wait_span_drain.

    The predicate requires kind=2 AND generation matching vector_generations.
    Vectors with kind=1 or a stale generation must not count as covered.
    """

    def test_kind1_vectors_not_counted_as_span_coverage(self):
        """An estate whose vectors are kind=1 must return 'span-short'.

        At d8f6d322e estate_state's predicate ignores kind, so it reads
        kind=1 vectors as covered and returns 'verified'. After C2 it must
        return 'span-short'.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            _make_estate(tmpdir, schema_version=20, kind=1)
            state, _, _ = import_units.estate_state(tmpdir, 3)
            self.assertNotEqual(
                state, "verified",
                "estate with kind=1 vectors must not be 'verified'; span predicate "
                f"must require kind=2. got {state!r}")
            self.assertEqual(
                state, "span-short",
                f"estate with kind=1 vectors must be 'span-short'; got {state!r}")

    def test_stale_generation_vectors_not_counted_as_span_coverage(self):
        """Vectors from a superseded generation must not count as covered.

        generation_match=False means v.generation is one less than
        vector_generations.serving_generation — a prior-generation vector
        that the active encoder has superseded.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            _make_estate(tmpdir, schema_version=20, kind=2, generation_match=False)
            state, _, _ = import_units.estate_state(tmpdir, 3)
            self.assertNotEqual(
                state, "verified",
                "estate with stale-generation vectors must not be 'verified'; "
                f"got {state!r}")
            self.assertEqual(
                state, "span-short",
                "estate with stale-generation vectors must be 'span-short'; "
                f"got {state!r}")


# ---------------------------------------------------------------------------
# G3 — span predicate locality gate (D1)
# ---------------------------------------------------------------------------

class SpanPredicateLocalityTests(unittest.TestCase):
    """G3: the span-coverage SQL must live exclusively in artifact_layout.SPAN_COVERED_SQL.

    Exactly one occurrence of COUNT(DISTINCT v.item_id) must exist across
    artifact_layout.py, import_units.py, and smoke_verify.py combined — the
    one inside artifact_layout.SPAN_COVERED_SQL — so estate_state,
    wait_span_drain, and smoke_verify all share the same predicate and cannot
    drift independently.  Both import_units.py and smoke_verify.py must import
    artifact_layout to reach the shared constant rather than carrying their own
    copy.
    """

    def _seeding_dir(self):
        return os.path.join(os.path.dirname(__file__), "..")

    def test_span_predicate_appears_exactly_once_across_consumers(self):
        """COUNT(DISTINCT v.item_id) must appear exactly once across the three files.

        The predicate must live in artifact_layout.SPAN_COVERED_SQL only.
        Inline copies in import_units.py or smoke_verify.py will drift from
        the shared constant and re-introduce the divergence this refactor fixed.
        """
        seeding = self._seeding_dir()
        needle = "COUNT(DISTINCT v.item_id)"
        total = 0
        for name in ("artifact_layout.py", "import_units.py", "smoke_verify.py"):
            path = os.path.join(seeding, name)
            with open(path, encoding="utf-8") as fh:
                src = fh.read()
            count = src.count(needle)
            total += count
        self.assertEqual(
            total, 1,
            f"Expected exactly 1 occurrence of {needle!r} across "
            "artifact_layout.py, import_units.py, and smoke_verify.py; "
            f"found {total}. "
            "The span predicate must live in artifact_layout.SPAN_COVERED_SQL "
            "only — inline copies in consumers will drift from the gate.")

    def test_span_predicate_defined_by_name_in_artifact_layout(self):
        """artifact_layout.py must define SPAN_COVERED_SQL by that name.

        Renaming the constant without updating this gate would leave the
        locality test passing on a name that callers do not actually import.
        """
        seeding = self._seeding_dir()
        path = os.path.join(seeding, "artifact_layout.py")
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn(
            "SPAN_COVERED_SQL",
            src,
            "artifact_layout.py must define SPAN_COVERED_SQL so consumers "
            "can import it by that name.")

    def test_import_units_imports_artifact_layout(self):
        """import_units.py must import artifact_layout to reach SPAN_COVERED_SQL.

        An inline copy of the SQL in import_units.py is a second definition
        that can diverge; the import is structural proof that there is only one.
        """
        seeding = self._seeding_dir()
        path = os.path.join(seeding, "import_units.py")
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn(
            "import artifact_layout",
            src,
            "import_units.py must import artifact_layout so it shares "
            "SPAN_COVERED_SQL from the single definition in that module.")

    def test_smoke_verify_imports_artifact_layout(self):
        """smoke_verify.py must import artifact_layout to reach SPAN_COVERED_SQL.

        An inline copy of the SQL in smoke_verify.py is the second definition
        that historically drifted; the import is structural proof it is gone.
        """
        seeding = self._seeding_dir()
        path = os.path.join(seeding, "smoke_verify.py")
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn(
            "import artifact_layout",
            src,
            "smoke_verify.py must import artifact_layout so it shares "
            "SPAN_COVERED_SQL from the single definition in that module.")


# ---------------------------------------------------------------------------
# G4 — absent migrations row classification gate (D2)
# ---------------------------------------------------------------------------

def _make_estate_no_schema_row(tmpdir, n_drawers=0):
    """Estate with _storagekit_migrations table present but no LocusKit row.

    Simulates an estate whose serve was killed after SQLiteBackend created the
    migrations table but before it stamped the LocusKit version row (the last
    step in applyMigrations).  When n_drawers=0 this is a fresh-install abort;
    when n_drawers>0 it is a structurally inconsistent estate.
    """
    db_path = os.path.join(tmpdir, "estate.sqlite")
    con = sqlite3.connect(db_path)
    con.executescript("""
        CREATE TABLE drawers (
            id TEXT PRIMARY KEY,
            tombstonedAt TEXT,
            content TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE corpus_index_state (
            drawer_id TEXT PRIMARY KEY
        );
        CREATE TABLE encoder_models (
            model_id TEXT PRIMARY KEY,
            is_active INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE vectors (
            item_id TEXT NOT NULL,
            model_id TEXT NOT NULL,
            kind INTEGER NOT NULL DEFAULT 2,
            generation INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE vector_generations (
            model_id TEXT PRIMARY KEY,
            serving_generation INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE _storagekit_migrations (
            kit_id TEXT NOT NULL,
            version INTEGER NOT NULL
        );
    """)
    # Intentionally NO row for 'LocusKit' in _storagekit_migrations.
    for i in range(n_drawers):
        did = f"drawer-{i}"
        con.execute("INSERT INTO drawers VALUES (?, NULL, ?)", (did, f"content {i}"))
    con.commit()
    con.close()
    return tmpdir


class AbsentMigrationsRowTests(unittest.TestCase):
    """G4: absent LocusKit migrations row must not always map to 'schema-old'.

    When the migrations table exists but the LocusKit row is absent AND the
    estate has zero drawers, the estate is self-healing: it should be
    classified 'absent' so the import path re-creates it cleanly.

    When the migrations table exists, the LocusKit row is absent, AND drawers
    ARE present, the estate is structurally inconsistent (cannot have been
    imported without a schema stamp).  It must NOT be classified 'absent'
    (that would trigger a re-import that would violate the strict-append
    contract against existing rows).
    """

    def test_absent_row_zero_drawers_classifies_as_absent(self):
        """Migrations table present, no LocusKit row, zero drawers must be 'absent'.

        A self-healing fresh-install abort with no rows to lose must classify
        as absent so the import path re-creates the estate, not as schema-old
        which would tell the operator to run upgrade on an empty estate.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            _make_estate_no_schema_row(tmpdir, n_drawers=0)
            state, drawers, _ = import_units.estate_state(tmpdir, 3)
            self.assertEqual(
                state, "absent",
                f"Migrations table present, no LocusKit row, zero drawers must "
                f"classify as 'absent' (self-healing import path); got {state!r}. "
                "Running 'mootx01 upgrade' on an empty estate is wrong advice.")

    def test_absent_row_with_drawers_classifies_as_interrupted(self):
        """Migrations table present, no LocusKit row, drawers present must be 'interrupted'.

        An estate with drawer rows but no schema stamp is structurally
        inconsistent: it cannot have been imported without the stamp.  It must
        NOT be classified 'absent' (which would trigger a strict-append
        re-import against existing rows) and must NOT be classified 'schema-old'
        (which tells the operator to run upgrade, but upgrade requires a valid
        schema version to work from).  'interrupted' is correct: the estate is
        unresumable and must be deleted before the import can proceed.

        n_drawers equals expected_records (3) so the generic drawers<expected
        tail branch cannot produce 'interrupted' for this fixture — only the
        structurally-inconsistent branch can, which pins the classification.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            _make_estate_no_schema_row(tmpdir, n_drawers=3)
            state, _, _ = import_units.estate_state(tmpdir, 3)
            self.assertEqual(
                state, "interrupted",
                f"Migrations table present, no LocusKit row, drawers present must "
                f"classify as 'interrupted' (structurally inconsistent — not safe "
                f"to re-import or upgrade); got {state!r}.")


# ---------------------------------------------------------------------------
# G5 — never-initialised database gate (D2)
# ---------------------------------------------------------------------------

def _make_empty_db(tmpdir):
    """SQLite file with no tables — opened but never written to."""
    db_path = os.path.join(tmpdir, "estate.sqlite")
    con = sqlite3.connect(db_path)
    con.close()
    return tmpdir


class NeverInitialisedTests(unittest.TestCase):
    """G5: a database with no tables at all must classify as 'absent'.

    An empty SQLite file was never initialised — no migration step ran, no
    tables were created, no rows exist.  The import path must re-create it;
    'absent' is the correct classification.  'interrupted' is wrong: it
    implies a partial import that cannot be resumed, but nothing was ever
    written.
    """

    def test_empty_db_no_tables_classifies_as_absent(self):
        """A valid SQLite file with no tables must classify as 'absent'.

        A never-initialised estate must not be confused with one whose import
        was interrupted.  'absent' allows the import path to re-create the
        estate cleanly; 'interrupted' would block it with a delete instruction
        for a directory that has no data to protect.
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            _make_empty_db(tmpdir)
            state, drawers, _ = import_units.estate_state(tmpdir, 3)
            self.assertEqual(
                state, "absent",
                f"An empty database (no tables) must classify as 'absent' "
                f"(never initialised, safe to re-create); got {state!r}. "
                "At 9350913f2 this returned ('interrupted', -1, -1) because "
                "the missing drawers table raised OperationalError which the "
                "outer sqlite3.Error handler caught.")


# ---------------------------------------------------------------------------
# G6 — unreadable/corrupt database gate (D2)
# ---------------------------------------------------------------------------

def _make_corrupt_db(tmpdir):
    """A file named estate.sqlite containing non-SQLite bytes.

    sqlite3.DatabaseError is raised on the first PRAGMA execution, which
    the outer except sqlite3.Error handler catches.
    """
    db_path = os.path.join(tmpdir, "estate.sqlite")
    with open(db_path, "wb") as fh:
        fh.write(b"NOT A SQLITE DATABASE\x00\xff\xfe")
    return tmpdir


class UnreadableDbTests(unittest.TestCase):
    """G6: an unreadable database must classify as 'interrupted', not 'absent'.

    G5 and G6 together pin the two distinct states apart so a future change
    cannot collapse them back into one branch.  A never-initialised estate
    (G5) is safe to re-create; an unreadable estate (G6) must be manually
    inspected before deletion.
    """

    def test_corrupt_file_classifies_as_interrupted(self):
        """A non-SQLite file named estate.sqlite must classify as 'interrupted'.

        sqlite3 raises DatabaseError (a subclass of sqlite3.Error) on the
        first PRAGMA call, which estate_state catches and maps to 'interrupted'
        with the -1 sentinel.  This pins the unreadable path separately from
        the never-initialised path (G5).
        """
        with tempfile.TemporaryDirectory() as tmpdir:
            _make_corrupt_db(tmpdir)
            state, drawers, _ = import_units.estate_state(tmpdir, 3)
            self.assertEqual(
                state, "interrupted",
                f"An unreadable database must classify as 'interrupted' "
                f"(not 'absent'); got {state!r}. "
                "sqlite3.DatabaseError is a subclass of sqlite3.Error and "
                "must be caught by the outer error handler.")
            self.assertEqual(
                drawers, -1,
                f"An unreadable database must report the -1 error sentinel "
                f"for drawers; got {drawers!r}.")


if __name__ == "__main__":
    unittest.main(verbosity=2)

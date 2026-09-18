---
version: v0.12
status: draft
date: 2026-09-17
description: The artifact builder. How benchmark estates are laid out, built, catalogued, encoded and smoke-tested. Rulings from Bob, 2026-09-07.
---

# Artifact Builder

## 1. Purpose

The artifact builder turns a published benchmark dataset into the estates the
benchmark harness measures. It owns the seeders, the layout, the catalog, the
wave import, the watcher and the smoke test. It does not own the harness, the
labs, or any mootx01 shipping code; the product is reached only through the seam (§11).

Every estate is built fresh. There is no in-place surgery and no drift check.

## 2. Storage rules

R1. Base folders come from a target map, a machine-local JSON file named by
    the environment variable MOOTX01_BENCH_TARGET_MAP, set in the operator's
    shell dotfiles. The map is never checked in; no checked-in file carries a
    base folder path. The builder stops loud when the variable is unset, the
    file is missing, or it has no entry for the requested port and dataset.
    Every path under a base folder is relative. The smoke test ignores the
    variable and uses its own map inside the scratch folder.

R1a. The target map lists, per port per dataset, an ordered list of base
    folders: primary first, then secondary, and so on. The builder fills the
    primary until it is full, then continues in the secondary. "Full" is the
    disk floor of §6 on that volume. A set is never split across base folders;
    the set that would cross the floor starts in the next base folder.

R1b. The catalog (§3) records the base folder of every set, so an estate is
    always found through the catalog whichever volume it landed on.

R2. Layout under the base folder:

    <port>/<dataset>/estate_set<N>/<unit>/

    port     = swift | rust
    dataset  = locomo | lme_s | convomem | membench
    N        = 1, 2, 3 ... in build order
    unit     = the dataset's unit id, filesystem safe

R3. A set holds at most 100 estates. No directory holds more than 1000 files.

R4. The aggregate estate for a dataset is a set of one:

    <port>/<dataset>/aggregate/<dataset>/

R5. An estate directory holds the nine product files plus the builder ledger
    (§5). Nothing else is written there.

R6. Seed projections (§4 step 1) are temporary. They live under the marked
    benchmark work root, `seeding/`, and are removed by
    `make clean-seed-projections`. They are never stored beside artifacts.

R7. Scripts, code, logs and results never live under the base folder or on an
    artifact volume. They live in the repo worktree or the marked work root.

## 3. Card catalog

The catalog is the source of truth for where every estate is and what state it
is in. The harness reads the catalog, never the directory tree.

C1. `<port>/<dataset>/catalog.json`, one per dataset per port, written in the
    primary base folder. Lists every set with its base folder, relative path and
    state.

C2. `<port>/<dataset>/estate_set<N>/partition_map.json`, one per set. Lists the
    set's estates: unit id, relative path, record count. Written LAST, after
    every estate in the set is imported. Its appearance is the wave signal.

C3. `<unit>/address.json`, one per estate. Fields: unit id, dataset, port, set,
    record count, size in bytes after encode, state, timestamps per state.

    state = laid_out | provisioned | imported | encoded | failed

C4. State moves forward only. A failed estate stays failed with the error text
    in its address file's `error` field; no other file is written. The set is
    not complete until it is rebuilt.

## 4. Build pipeline

One pass per dataset, per port, smallest dataset first: locomo, lme_s,
convomem, membench. A dataset finishes 100% before the next starts.

1. Project. Read the raw dataset once into a seed projection under the work
   root (`seeding/out-<dataset>/projection/`, written by the dataset's seeder
   through seed_projection.emit_projection). The projection is one JSONL per
   unit, one record per drawer with id, body, room, shape and the gold
   relation per question of the unit, plus dataset.json with the room rule
   in words and the overlap flag. Question ids are `<unit>/q<n>`.

2. Lay out. Create the empty tree of R2 and R4. Directories only. Write every
   address file at state laid_out.

3. Provision once, clone. Provision one empty estate: schema, indexes, encoder
   row, activation key. Copy-on-write it into every estate directory. State
   provisioned.

4. Import in waves. For each set, for each unit: read the unit's records once,
   write them into the unit's estate and into the aggregate estate. Room
   assignment follows the seeder's rule. Write the ledger (§5) beside the
   estate. State imported. When the last unit of the set is imported, write the
   partition map. No encode happens in this step. After the last set, write
   the end-of-dataset marker `<port>/<dataset>/import.done`. Before the first
   import the builder flips the `BENCHMARK_PREFERENCES_OFF` estate preferences
   off through `mootx01 preference set --db`, after a first serve materialises
   the estate (create, flip, import — the same order in both ports);
   A build may name further keys in `MOOTX01_BENCH_PREFERENCES_OFF_EXTRA`
   (comma-separated). Artifact builds set `fact_extraction` there on both
   ports (ruling 2026-09-17: the lane is experimental and slow; it is run
   later on a chosen copy of an artifact, such as a wing estate), so artifacts
   carry no extracted facts; `FACTS=1` keeps the lane on for one build.

   For datasets whose haystacks overlap (lme_s), the aggregate write skips a
   record already present. For datasets with no overlap (membench), it is a
   straight second write.

5. Watch and drain. N watchers per port (§6) claim partition maps as they
   appear. For each claimed set a watcher:
   a. checks free disk on the current base folder against the encoded size of
      the previous set; if the next set would cross the floor it moves to the
      next base folder in the target map, and stops with a message only when
      the map is exhausted;
   b. hands the set's estate paths to the seam's batch-drain (§7);
   c. records size and state encoded into each address file as the drain
      reports each estate idle.

6. Aggregate drain. After the last set, the aggregate goes through the same
   batch-drain as a set of one. This is the one large drain and the one place
   core utilisation is measured.

7. Done check. Every address file at state encoded. Record count per estate
   equals the seed. Aggregate count equals the union. Catalog written.

## 5. Builder ledger

Beside every estate, `ledger.json`, written at import time because nothing
downstream can recover it:

- room_rule: the seeder's room assignment rule for this dataset, verbatim.
- records: per record id, its gold relation to each question of the dataset
  (gold | distractor | absent), and its shape.
- source: dataset name, unit id, seed projection digest, builder version.

The ledger serves the hierarchy lab, the TokenSaver lab and the cross-encoder
lab. It is the only builder output those labs read besides the estate itself.

## 6. Watchers

- N watchers per port, N a parameter. Each holds one resident model while
  draining, so N is bounded by memory and by cores.
- Input: the target map, the dataset's catalog path, the seam executable
  path, the disk floor.
- Trigger: an unclaimed partition_map.json.
- Coordination is the filesystem. No daemon, no queue service, no database.
  The partition map is the work item; the builder writes it last, so a set is
  claimable the moment the file exists.
- Claim: atomic rename of `partition_map.json` to
  `partition_map.<watcher-id>.claimed`. Exactly one watcher wins; the others
  get not-found and move to the next set. A set is one batch; the batch-drain
  binary drains its estates one at a time in one process. Parallelism is N sets
  in flight, not N estates within a set.
- Progress: each estate's address file moves to encoded as it drains. The
  claimed file's modification time is touched per estate as the heartbeat.
- Reclaim: a claimed file untouched for longer than the stale limit is renamed
  back to `partition_map.json` by whichever watcher notices. The next claim
  resumes from the first estate not yet at state encoded.
- Done: rename to `partition_map.done.json` with the set's encoded size added.
- Loop: list the dataset's sets, try to claim one, drain it, mark done, repeat
  until no maps remain and the builder's end-of-dataset marker exists.
- Disk floor: a parameter in bytes; when omitted the watcher uses twice the
  previous set's encoded size. Checked on the set's base folder before a
  claim. A base folder carrying `.capacity_bytes` (written by the layout when
  the target map gave a capacity) is measured against that cap, else against
  the volume's free space. A set below the floor is skipped, not claimed;
  sets on other base folders keep draining. The watcher exits 3 only when
  every remaining claimable set is below the floor and nothing is in flight.
- Output: address file updates and the partition map renames only. Never
  writes into an estate.
- Failure: a set that fails to drain is marked failed in the catalog; the
  watcher continues with the next set and the build reports failed sets at the
  end.

## 7. Batch-drain: the product finisher

No shipping code. The product's finisher, `mootx01 drain --db <estate>`
(GeniusLocusKit § DUTY_LIFECYCLE), is the batch-drain: it runs attached, pays
the encode queue and every row-debt lane (span encode, subject backfill,
anomaly sweep, fact extraction) until each owes nothing or a batch pays
nothing, and exits with nothing it started still running. The seam (§11)
runs it once per listed estate, one at a time, then reads `moot_drain_status`
once over a stdio serve (a stdio serve spawns nothing) and prints the idle
line only when every lane reads idle with nothing pending. Both ports; the
product binaries come from `make binaries`.

## 8. Smoke test

The smoke test proves the assembly line, never the content.

- Input: a checked-in config per port naming a two-entry target map inside the
  scratch folder with a floor low enough that the second set lands in the
  secondary, two sets
  of three units, a few one-line records per unit, one aggregate. Nothing shaped
  like a benchmark dataset. A trivial pass-through source stands in for the
  seeder.
- Scratch: a fixed, gitignored folder inside the worktree. Emptied at the start
  of every run and by `make clean-smoke`. Nothing else writes there.
- Runs every station of §4 with the small numbers, both ports, with two
  watchers so the claim path is exercised.
- Asserts: tree matches R2 to R5; every estate has nine files plus ledger; every
  address file reaches encoded with non-zero size; each partition map lists
  exactly its estates; record counts match the source; aggregate count equals
  the union; drain status idle everywhere; both ports produce the same tree and
  the same catalog fields.
- No recall, no scores, no quality claims.
- Runtime one to five minutes end to end including the two binary launches.
- With `PRODUCT=1` it depends on `make binaries`; the product line is proven when both ports stamp.
- It is the gate before any real dataset build and after any change to the
  builder.

## 9. Make targets

    make batch-drain-binary            the product binaries (= make binaries)
    make smoke-builder PORT= [PRODUCT=1]                       §8
    make build-dataset DS= PORT= [PRODUCT=1] [LIMIT=N] [UNITS="a b"] [TARGET_MAP=] [FLOOR=]   §4 for one dataset
    make proof-unit DS= PORT= UNIT=    one unit through the product line into a scratch base under the work root
    make setup / make teardown         the work root's whole life: fetch, binaries, seeds / emptied and removed
    make config                        write the target-map template into the config peer (benchmark-config/)
    make stash-artifacts DS= PORT= EXTERNAL=     move a built dataset out to an external base folder
    make restore-artifacts DS= PORT= EXTERNAL=   copy it back under the work root for a run
    make logs                          every log in the work root into benchmark-logs/logs-<stamp>.zip

`PRODUCT=1` runs the line on the port's product binary through the seam;
without it the faker runs. `LIMIT=N` builds the first N units by sorted id
and `UNITS` names exact units (the 2026-09-16 artifact subset was locomo all
10, lme-s first 80, convomem first 100). The Makefile sets `MOOTX01_BINARY`,
`IMPORT_DRAIN_TIMEOUT` and the fact-extraction-off preference (§4 step 4).
Storage is one config file, `benchmark-config/storage.json` beside the work
root, with three roles: `internal_primary` (every artifact is built and
served there), `external_storage_1` and `external_storage_2` (finished sets
are stashed out to the first with room and restored from either). The
builder lays every set out under the internal primary; `TARGET_MAP=` keeps
the R1 map form for one run. The work root and the artifact cache are
created by `make setup` and erased by `make teardown`; nothing in either is
hand-made.
    make clean-seed-projections        remove seeding/ under the work root
    make clean-smoke                   empty the smoke scratch folder

## 10. Out of scope

The harness, the labs, recall quality, the benchmark run list, any product
change other than §7.

## 11. Product seam and the faker

The builder touches mootx01 at exactly three calls, behind one parameter, the
path to the executable:

    provision  <estate-dir>                 create one empty estate
    import     <estate-dir> <records-file>  import records, print the count
    batch-drain <list-file>                 §7; print one line per estate as it
                                            reaches idle, with its size

`mootx01_faker` answers the same three calls with the same arguments, exit
codes and output lines, and does fake work: provision writes ten empty files
of the right names; import appends record ids to a text file in the estate and
prints the count; batch-drain touches each listed estate in turn, sleeps a
configurable few milliseconds per estate, writes a fake size, prints the idle
line. Faults on demand through its config: fail a named set, die after K
estates, sleep past the stale limit.

Build order: the builder and smoke test are built and proven on the faker
first. The real binary then replaces the faker one role at a time, provision,
then import, then batch-drain, each proven before the next. Once all three run
on the real binary the faker stays as the fast smoke path and the fault
injector.

The faker lives in the suite's `seeding/` directory beside this specification, writes only into the scratch
folder, and never ships in the product.

`mootx01_seam` (same directory) is the real-binary side of the seam. Provision
creates the directory only: the product materialises the estate on the
importer's first serve (create, flip preferences, import). Import runs
`import_units.py` once per estate on a unit file assembled from the seeder's
records for the rows in the projection file (the projection carries id, body
and room; the seed record adds subject, wing and event time). The aggregate is
the one exception: the importer is strict-append, one file per estate, so the
aggregate's rows are staged beside it and imported as one unit file when
batch-drain reaches it. Batch-drain is §7.

## Changelog

### v0.12 — 2026-09-17

§7 batch-drain is the product finisher behind the seam; the gated mode is not
built. §11 adds `mootx01_seam`. §9 adds `PRODUCT=1`, `LIMIT=`, `UNITS=`,
`proof-unit`, `setup`/`teardown`, `config`, `stash-artifacts`/`restore-artifacts`
and `logs`; the work root and cache are make-made and make-erased, and the
target map lives in a config peer that teardown never touches. The importer
exits non-zero on a refused import and skips its waits. The fact lane counts as
settled when nothing it holds is runnable (blocked and rejected sources are
settled work).

- v0.11 (2026-09-16): §4 — `MOOTX01_BENCH_PREFERENCES_OFF_EXTRA` names further
  keys to flip off; the Rust artifact build turns `fact_extraction` off.
- v0.10 (2026-09-15): §4 — the builder materialises each estate through a first
  serve before flipping preferences, so both ports create, then flip, then import
  (the Rust CLI refuses to write preferences into an empty directory).
- v0.9 (2026-09-15): §4 documents that the builder flips BENCHMARK_PREFERENCES_OFF
  through `mootx01 preference set --db` before the first import; fact_extraction
  stays on (ruling 2026-09-14).
- v0.8 (2026-09-08): the pre-consolidation draft (v0.1 and v0.2, written under the
  old seeding directory before it moved here) is folded in. Every clause it carried
  already appears above in its later form; the text is otherwise unchanged.
- v0.6 (2026-09-07): all four seeders write the projection (locomo, lme-s, convomem,
  membench). Entity drawers and tunnels (convomem) and kgfacts (membench) exist
  only in the seed files, not in the projection; ruling pending on carrying them.
- v0.6→v0.7 (2026-09-08): R5 counts nine product files; the estate no longer
  carries a posture marker file, the scratch posture is the serve flag.
- v0.5 (2026-09-07): §4 step 1 names the projection writer and its shape; LoCoMo
  is the first seeder wired to it.
- v0.4 (2026-09-07): C4 error field, §6 floor default and skip semantics, §9
  TARGET_MAP and FLOOR forwarding; from the first cold post-flight.
- v0.3 (2026-09-07): R1 target map resolved from MOOTX01_BENCH_TARGET_MAP.
- v0.2 (2026-09-07): §11 product seam and mootx01_faker; build order faker first,
  real binary one role at a time.
- v0.1 (2026-09-07): first draft from the 2026-09-07 rulings: target map with
  failover, card catalog, wave import with ledger, N claiming watchers over
  atomic renames, gated batch-drain mode, assembly-line smoke test.

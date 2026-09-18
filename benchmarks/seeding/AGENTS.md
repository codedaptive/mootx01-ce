# AI Knowledge for Public Seeding Tools

These tools deterministically project source corpora into versioned import
seeds, fleet manifests, and complete-estate inputs. They receive fixture and
output paths explicitly from the Makefile; they never discover or create a
repository-local runtime directory.

The same declared inputs must produce the same canonical bytes. Preserve stable
ordering, IDs, timestamps, namespaces, annotation mappings, and provenance.
Generated seeds and estates belong beneath `$BENCH_WORK_ROOT` and are not
committed.

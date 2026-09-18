# AI Knowledge for Committed Fixtures

This directory contains only small, reviewable fixtures required by unit and
conformance tests. Full external datasets are fetched beneath
`$BENCH_WORK_ROOT/fixtures` and never committed.

Treat fixture bytes as protocol evidence. Record why a fixture exists, keep it
minimal, and update tests in both ports when shared semantics change. Do not add
raw reports, estates, model output, or downloaded corpora.

# AI Knowledge for Public Harness Scripts

These scripts fetch pinned source data, validate the external work root, render
runtime configuration, and package external bundles. They are public operator
instruments and must be self-contained.

Every mutating script requires `BENCH_WORK_ROOT`, validates it with
`work-root.py`, and writes only beneath that marked root. Fetchers verify their
declared artifacts. Scripts must work in a source archive without `.git` or a
configured remote and must fail closed on missing tools, invalid checksums, or
unsafe paths.

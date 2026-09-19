# AI Knowledge for Public Benchmark Configuration

Committed files in this directory are portable templates and declarative
instrument configuration. Machine-specific paths, model locations, secrets,
and writable destinations are rendered into runtime copies beneath
`BENCH_WORK_ROOT`.

Configuration changes alter benchmark identity when they affect corpus,
retrieval, scoring, or model behavior. Update the owning protocol and
provenance fields with such a change.

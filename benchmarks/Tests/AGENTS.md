# AI Knowledge for Swift Benchmark Tests

Tests prove Swift protocol behavior, deterministic generation, report schemas,
failure propagation, external-path handling, and cross-port conformance. They
must not depend on a developer's installed product, home-directory fixtures,
network service, or repository-local writable path.

Use committed minimal fixtures for unit semantics and environment-provided
external fixtures for optional full-corpus checks. Keep expected values literal
and traceable to the owning protocol rule.

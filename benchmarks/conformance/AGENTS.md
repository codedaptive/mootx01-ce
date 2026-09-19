# AI Knowledge for Conformance Vectors

Each subdirectory groups vectors for one protocol family. Swift and Rust tests
must consume the same committed bytes and assert the same observable result.
Do not create port-specific expected outputs.

Vectors should be minimal, named for the rule they prove, deterministic, and
human-inspectable. A behavioral change updates the normative protocol first,
then the vector, then both port implementations and tests. External work and
generated output remain outside the repository.

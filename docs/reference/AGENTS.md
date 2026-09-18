# Reference — What The Surfaces Are

Per-package interface and specification documents, one pair per kit: what the
API is, what it guarantees, what it refuses. This is the authority a caller
checks against, so precision outranks readability here.

Filenames carry no version number — the version lives in front matter, per
VERSIONING.md. A revision bumps that field; it never renames the file, because a
rename breaks every citation from code comments, cookbooks and decision records.

`vectors/` is not documentation. It holds an encryption conformance fixture that
the tests read from that exact path in both editions — do not move it, do not
archive it, do not tidy it.

This directory publishes.

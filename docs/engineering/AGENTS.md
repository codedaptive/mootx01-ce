# Engineering — How To Build Against The Substrate

Implementation guidance: cookbooks, integration notes, the release runbook, the
reasoning a developer needs to write correct code against these interfaces.
Between `reference/` saying what a surface is and `concepts/` saying why it
exists, this says how to use it without getting it wrong.

An API signature belongs in `reference/`; a ruling belongs in `decisions/`.

This directory publishes, and the release runbook is the file most likely to
tempt a maintainer into describing the publication machinery. It must not: what
a release CONTAINS is public, how it is produced is not.

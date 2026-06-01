# EideticLib Reference Data

EideticLib ships no classification reference data of its own. Lookup
delegates to LatticeLib's FDC (Frame-Directed Classification) engine,
which owns and bundles the pinned FDC artifacts (lexicon, frame, and
signatures). EideticLib grounds a term by calling `FDC.encodeAnchor`:
the term is canonicalized to a concept bag and matched against those
pinned signatures to produce an FDC code and the dominant concept's
CC0 Wikidata Q-ID. Network is never consulted.

This directory exists so the package's `.process("Resources")` rule
has a target; it intentionally carries no data files.

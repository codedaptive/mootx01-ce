# HMMTaggerModel.json — Attribution Notice

## License

Creative Commons Attribution 3.0 United States (CC BY 3.0 US)
https://creativecommons.org/licenses/by/3.0/us/

## Attribution

American National Corpus (ANC) Project / MASC
Open American National Corpus — Manually Annotated Sub-Corpus (MASC)
http://www.anc.org/ (archived; TLS cert expired as of 2026-06-17 —
the ANC download page should be added to the release packet by the
maintainer from the live archive)

## Corpus Details

- Corpus name:    MASC 3.0.0 Penn Treebank constituency annotation
- Corpus version: MASC 3.0.0
- Annotation:     Penn Treebank bracket-tree (PTB) format, .mrg files
- Source zip:     penn-treebank.zip
- SHA-256:        ef1c97151e15701155dee18b04433b2ade1c22aeea04542983b34d894858a492
- Generated:      2026-06-17
- Token count:    103,333 preterminal tokens in the corpus (excluding empty
                  traces); the model is estimated from the 5,230 RARE (hapax,
                  frequency 1) tokens — the standard unknown-word proxy, since
                  the HMM only ever tags novel out-of-vocabulary tokens

## What Is Shipped

Only the DERIVED integer weight table (`HMMTaggerModel.json`) is shipped
with this software. The raw corpus text is NOT shipped. The weight table
contains no verbatim corpus text — only aggregate counts converted to
Laplace-smoothed log-probabilities, scaled and rounded to integers.

The ETL script that produced this artifact is committed at:
  the HMM-training ETL (EE build tooling)

This script, combined with the source corpus at the SHA-256 above and the
formulas documented in the script header, fully reproduces the artifact
deterministically.

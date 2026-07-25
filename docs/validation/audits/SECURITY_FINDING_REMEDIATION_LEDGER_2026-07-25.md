---
status: recorded
created: 2026-07-25
review_window: 2026-07-24 through 2026-07-25
base_revision: c9f4945d (develop/1.0.x)
findings_closed: 6
---

# CE 1.0.35 Security Remediation Record — July 24 to 25, 2026

Findings closed by the CE 1.0.35 work, prepared on `develop/1.0.x` at
`c9f4945d`. Reported-in names the commit that introduced the condition.

## Closed

| # | Severity | Issue | Reported in | Fix commits |
|---:|---|---|---|---|
| 1 | High | Release OIDC environment trusted by manual Windows jobs | `cc79b547` | `c6c868d1`, `5a9b067b` |
| 2 | Medium | By-id retrieval did not apply provenance sensitivity redaction | not reported | `9be92ef3`, `8fd44eab`, `72dc7b97` |
| 3 | Medium | Apple-platform estates created without at-rest encryption | `b13cfbd6` (partial) | `195bcfb2`, `4a3ba1b9`, `9a36c6f5`, `72b7e458`, `81488665`, `e31d69c2`, `5abf892b`, `3714d29f`, `38961256`, `17eb6571` |
| 4 | Medium | Parall configs ignored direct-stdio and vault-off | `53ad6c43` | `cd24de66`, `0d0fdc2e` |
| 5 | Low | PyPI publish job reachable from manual runs | not reported | `11e334d0` |
| 6 | Informational | Plugin artifacts left at 1.0.18 after binary bump | `fb576161` | closed by later version bumps |

## Suite counts

| Suite | Count |
|---|---:|
| `apps/mootx01` Swift | 279 |
| `AriaMcpKit` Swift | 515 |
| `AriaMcpKit` Rust | 454 |
| `LocusKit` Swift | 818 |
| `LocusKit` Rust | 885 |
| `mootx01` Rust | 225 |

Rust counts are unchanged from the baseline and serve as the cross-language
parity check.

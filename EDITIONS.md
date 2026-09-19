# Editions

*Open Community product, personal Pro product, organizational Enterprise product. Same substrate; different operational surfaces.*

---

MOOTx01 ships as an open source substrate under the Apache License,
Version 2.0, with a commercial lane for the organizations and use cases
that need Codedaptive standing behind a deployment. The substrate is the
product. The commercial lane is the promise.

The source ships through two repository editions. The native application ships
at three product levels. Those are different axes and their names must not be
used interchangeably.

- **Community Edition (CE repository)** publishes the open substrate and the
  open **MOOTx01 Community** desktop application.
- **Enterprise Edition (EE repository)** is the private canonical workshop and
  carries **MOOTx01 Pro** and **MOOTx01 Enterprise**, plus the Community source
  used to prove curated CE publications.

The open core is the substrate itself, available to anyone, runnable on any
hardware, under the user's control. The commercial products make that substrate
convenient on personal Apple devices or operational in environments that need a
contract behind it.

Both repository editions share the same substrate code. The open core makes the
substrate exist. Pro makes it convenient across one person's Apple devices;
Enterprise makes it operational where unsupported software alone cannot go.

## Native application product levels

The product boundary is capability-based and monotonic: Pro contains every
Community capability; Enterprise contains every Pro capability. An interface
preference may simplify navigation within a product, but it never unlocks a
higher product level.

| Capability family | Community | Pro | Enterprise |
|---|:---:|:---:|:---:|
| Local encrypted estate; Capture, Recall, Review; Quick Capture | ✓ | ✓ | ✓ |
| ARIA/MCP, Product Dock, portable LAN, import/export | ✓ | ✓ | ✓ |
| Transparent engine, tool, and edge diagnostics | ✓ | ✓ | ✓ |
| macOS desktop application | ✓ | ✓ | ✓ |
| Windows desktop application | Planned | — | Deployment-dependent |
| iPhone and iPad applications | — | ✓ | ✓ |
| On-device Intelligence and Apple system surfaces | — | ✓ | ✓ |
| Personal iCloud sync, federation, miners, and work packets | — | ✓ | ✓ |
| Organization identity, policy, federation, and remote administration | — | — | ✓ |
| Managed deployment, audit/compliance assurance, certified integrations | — | — | ✓ |

Trust, individual import/export, and the ability to leave the product remain in
Community. Enterprise capabilities add organizational control above the
single-owner model; they do not take ownership of a person's estate away from
that person.

The application stays beside the substrate in each repository. It is not a
third repository. EE is the development and security-validation workshop. A
curated app publication moves from an EE worktree into CE only after review;
the CE backporter never merges the noisy EE development history and never
copies the private app directory wholesale.

---

## The open substrate

Everything in the Community Edition repository (`mootx01-ce`) is
Apache-2.0: the twenty-four foundation
libraries and kits, the composition layer (GeniusLocusKit — estates,
grants, federation composition, composed recall), the Brain layers
(NeuronKit and CognitionKit) — all three of which also publish as the
`moot-cognition` venue — VaultKit, the ARIA interface surfaces, the
conformance harness, the architecture specification, and the MOOTx01
Community application.

It runs where the user puts it. Laptop, phone, home server, machine in a
closet, a tenant the user runs themselves. There is no cloud requirement,
no vendor account, no licensing meter, and no use restriction of any
kind. Commercial embedding, hosted services, and managed offerings are
all permitted by the license.

The four foundation venue repositories (`moot-core`, `moot-semantics`,
`moot-system`, `moot-memory`) remain live as Apache-2.0 publication
venues. With the product core now under the same license, the venue and
the main repository grant identical rights; the venues persist as stable,
narrow dependency surfaces for downstream builders.

The open substrate has no service level agreement, no supported builds,
no indemnification, and no compliance documentation. The user is
responsible for their own deployment. That is appropriate for most users.
It is not appropriate for everyone.

## The applications

One application family, three products, one capability hierarchy:

```text
Community ⊂ Pro ⊂ Enterprise
```

**MOOTx01 Community** lives in the Community Edition repository and is
Apache-2.0. It is
the complete single-owner desktop loop: local encrypted estate, Capture,
Recall, Review, Quick Capture, ARIA/MCP, Product Dock, portable LAN
serving, individual import and export, and transparent engine, tool, and
edge diagnostics. macOS today; a Windows implementation is planned.

## Commercial products

**MOOTx01 Pro** is the commercial personal application for macOS, iPhone,
and iPad. It adds the personal Apple layer: on-device Intelligence, Apple
system surfaces (Siri, Shortcuts, App Intents, Share Sheet, widgets,
Spotlight), iCloud sync, personal federation, attended miners, and work
packets. Pro is distributed through the App Store; its source is not
published.

**MOOTx01 Enterprise** is the commercial organizational application. It
adds organizational identity, managed policy and federation, remote
administration, managed deployment, audit and compliance assurance, and
certified integrations. A named Enterprise capability is not a claim that
its surface has shipped; absent surfaces remain absent until their
implementation passes its own release gates.

Pro does not add organizational ownership or administration to a person's
estate. Every capability in Community stays in Community. The commercial
products add layers; they never take the open application hostage.

## Enterprise Edition: the assurance lane

Enterprise is not a different substrate. It is the Community and Pro capability
set plus the organizational identity, policy, federation, deployment, and
assurance layer that enterprise environments require.

Some organizations cannot deploy unsupported open source software.
Regulated industries, large enterprises, organizations whose legal or
compliance posture demands a contract behind the software they run.
These are not failures of the model. They are operational realities.

Enterprise Edition is the same substrate with the operational layer those
environments require:

- **Supported builds** — hardened, tested, packaged for production, with
  response and maintenance commitments.
- **Compliance material** — the evidence packages FedRAMP- and
  CMMC-aligned deployments require, stated per agreement rather than
  implied by an edition name.
- **FIPS Sponsorship Program** — the substrate is built FIPS-ready: the
  cryptography is our own conformance-gated code and already-validated
  cryptographic modules. Full CMVP validation is a lab-and-fee process
  measured in months; we undertake it with a sponsoring organization,
  which funds the validation and receives a multi-year support and
  maintenance agreement in return.
- **Certified integrations and indemnification.**
- **Language editions** — the Go implementation for financial-sector use
  and the planned maximum-portability C edition ship in Enterprise
  Edition. Swift (Apple Silicon) and Rust (PC/Linux) are the open
  reference implementations; the standalone Python build arrives in the
  open substrate at v1.0 and remains single-machine by design, for the
  supply-chain reasons documented in the engineering references.

Two further artifacts are available to enterprise clients under NDA: the
mathematical treatment of the substrate's algorithms, and the
knowledge-sharing RFC ahead of its public release. The NDA period on the
RFC is a review window before an open release, not a wall around a
proprietary standard.

## Why this structure

We relicensed the product core from FSL-1.1-ALv2 to Apache-2.0,
retroactively, in August 2026 ([`RELICENSE.md`](./RELICENSE.md)). We are
plain about the reasoning.

Pro makes the substrate convenient for an individual across Apple devices.
Enterprise makes the substrate deployable at organizational scale. The
organizations that need a contract are the organizations that move serious
workloads.

All three products reinforce each other. Community adoption creates ecosystem
gravity, Pro funds a polished personal product, and Enterprise funds the
operational work required by organizations. None undermines the others.

The FSL protected against a competitor reselling our code. That is not
the competition that exists. In a field where working memory substrates
are rebuilt from scratch in months, a use restriction taxes every
good-faith adopter while restraining no rival. The value that cannot be
regenerated is not the source: it is the estate a user accrues, the
assurance a vendor stands behind, the products on top, and the trademark.
So the code is free, and the business is everything a license cannot copy.

The durable rule is: **The code is free. Assurance is Enterprise.** A
MOOT is always free — at home, at work, embedded, hosted, at any scale.
Commercial agreements exist where organizations want commitments:
supported builds, compliance evidence, certified integrations, the
commercial applications, and sponsored validation programs.

This is the posture Red Hat proved: not the only way to use the
substrate, but the credible way to deploy it where deployment is
hardest. RHEL never won by restricting Linux. It won on operational
credibility and a trademark a rebuild could not use. Our protection now
rests where theirs did — and the ARIA portability commitment stands
unchanged and non-negotiable: the interface specification, the grammar,
and the conformance vectors are free for everyone, so anyone can
implement MOOTx01, conform to it, and reach their own estate. The user's
memory belongs to the user.

Trademark rights in MOOTx01, MOOT, and ARIA remain separate from the
source grant ([`TRADEMARKS.md`](./TRADEMARKS.md)).

---

*The binding grant is the repository [`LICENSE`](./LICENSE).
[`LICENSING.md`](./LICENSING.md) gives the plain-language model.*

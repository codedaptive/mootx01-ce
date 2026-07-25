# Licensing

MOOTx01 ships under a three-layer licensing model. The ARIA interface specification is free for everyone, forever. The foundation libraries of the MOOTx01 Framework are open source under the Apache License, Version 2.0, published through dedicated public repositories. The MOOTx01 product core in this repository is source-available under the Functional Source License, Version 1.1, with Apache 2.0 as the future license (FSL-1.1-ALv2). The full FSL grant is in the LICENSE file at the repository root. This note states the model in plain language and records the tier ladder.

## In short

> **People are free. Systems are licensed. Assurance is Enterprise.**

The boundary is the deployment, not the employer and not the number of
individual installations:

- A one-person MOOT is always free, at home or at work.
- One person can use their personal MOOT across their personal devices without
  turning it into a multiuser system.
- A company can install a separate personal MOOT on every employee's desktop
  without buying a license. Each remains that person's MOOT.
- Individuals and companies can compile, sign, and deploy their own
  single-user MOOTx01-App builds without buying a license.
- Compiling or connecting the MOOTx01 product core into a multiuser enterprise
  system or a client-facing application requires a commercial license.
- Hosting MOOTs for clients for a fee requires a service-provider license.
- Support, hardened deployments, and FedRAMP/CMMC-oriented security work are
  Enterprise Edition offerings.

The [`LICENSE`](LICENSE) file is the binding grant. This document explains the
product and commercial model in plain language; it does not replace the license
or a signed commercial agreement.

## The Apache-licensed foundation

The foundation of the MOOTx01 Framework is open source today, not on a timer. Seventeen libraries and kits are published under Apache-2.0 through four public venue repositories, generated from the canonical MOOTx01 source tree with full provenance recorded per release:

- [`moot-core`](https://github.com/codedaptive/moot-core) — SubstrateTypes, SubstrateKernel, SubstrateML, SubstrateLib, EngramLib, IntellectusLib
- [`moot-semantics`](https://github.com/codedaptive/moot-semantics) — AriaLexiconLib, LatticeLib, EideticLib
- [`moot-system`](https://github.com/codedaptive/moot-system) — PersistenceKit, QueueKit, ConvergenceKit, ObserverSink, LoopbackHTTP
- [`moot-memory`](https://github.com/codedaptive/moot-memory) — LocusKit, VectorKit, CorpusKit

Which license governs is determined by where you obtain the code. Code obtained from a venue repository is Apache-2.0, with everything that license permits, including commercial and hosted use, and no Competing Use restriction. The same package source obtained as part of this repository is governed by this repository's FSL grant. This is deliberate multi-licensing by the copyright owner, not a conflict.

What remains under the FSL in this repository is the product core: GeniusLocusKit (the composition layer, estates, grants, and composed recall), NeuronKit and CognitionKit (the Brain layers), VaultKit, and the applications (the ARIA MCP server, the management console, and the installer).

## The grant

The FSL grant governs the product-core code in this repository. Running a
personal, one-person MOOT is always free. Commercial agreements cover system
integration: compiling or connecting that product core into a shared
enterprise system, a client-facing application, or a paid hosted service.

Two years after a version is released, that version converts to the Apache License, Version 2.0, automatically. The relicensing is built into the license itself, not a separate promise. The foundation libraries above did not wait for the timer; they are Apache now.

## What is free

- One person using one personal MOOT for life or work.
- That person using their personal MOOT across their personal devices.
- That person connecting their MOOT to any supported AI or MCP-capable tool.
- A company installing separate personal MOOTs for its employees, including
  every developer in the organization.
- An individual or company compiling, signing, and deploying its own
  single-user MOOTx01-App builds.
- Non-paid experimentation, modification, and shared community work within the
  binding license.

Personal means one owner and one person's MOOT. It does not stop being personal
because the computer belongs to an employer or because the person uses it while
doing paid work. It is an ownership boundary, not a one-device limit.

## Official Apple App Store distribution

The official MOOTx01-App in Apple's App Store is planned as an optional
convenience purchase, currently expected to cost about three dollars per major
`x.0.0` release. That purchase pays for the maintained, signed App Store
distribution. It is not a fee for the right to run a personal MOOT.

An individual may instead compile and sign a personal app build. A company may
do the same for separate, isolated single-user installations for its employees.
Those deployments remain free under the personal model.

This is distinct from the client-facing application tier. That commercial tier
applies when someone compiles or connects the MOOTx01 product core into an
application offered to clients or customers.

## What needs a license

A commercial agreement is required for the MOOTx01 product core when it is:

- compiled into or connected to a multiuser internal enterprise system;
- compiled into or connected to a client-facing public application; or
- hosted for clients as a paid service.

Installing separate personal MOOTs for many employees does not create a
multiuser system. Connecting those personal installations to a shared
enterprise application does.

These commercial boundaries apply to the FSL-licensed product core. The
Apache-licensed foundation repositories carry no Competing Use restriction.

## What Enterprise Edition adds

A commercial deployment license and Enterprise Edition answer different
questions:

- The commercial license covers the authorized system or application
  deployment.
- Enterprise Edition adds paid support, hardened builds, deployment
  assurances, compliance material, and negotiated FedRAMP/CMMC-oriented
  security hardening.
- A Go implementation is planned for Enterprise Edition, including
  financial-sector use.

Enterprise Edition does not imply that every personal MOOT used inside a
company needs a paid seat. It is the supported and hardened path for systems
whose deployment, regulatory, or operational requirements exceed a personal
installation.

## The tier ladder

- Personal one-person MOOT, at home or work: forever free.
- Official Apple App Store build: optional convenience purchase, currently
  expected to be about three dollars per major `x.0.0` release.
- Building and sharing non-paid work: free.
- Client-facing mobile app: five hundred dollars, lifetime, per app.
- Multiuser enterprise system: five thousand dollars, lifetime. Internal-facing
  only; not for hosting MOOTs as a service for third parties.
- Service provider: five thousand dollars, annually.
- Enterprise Edition support and security hardening: negotiated.
- FedRAMP / CMMC-oriented deployments: negotiated.

A lifetime tier covers every point release within a major version. The next major version is a new purchase.

## The mechanism

A dual license on a source-available core, beside an open foundation. The public license, the FSL above, states the free-to-build, no-selling grant that everyone receives for this repository. The paid tiers are separate agreements alongside it, not changes to the public license. The foundation venues are governed solely by Apache-2.0 and need no agreement at all.

---

_Current as of MOOTx01 stable/1.0.x and MOOTx01 Framework venue releases v1.0.5._

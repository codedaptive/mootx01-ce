# Licensing

MOOTx01 ships under a three-layer licensing model. The ARIA interface specification is free for everyone, forever. The foundation libraries of the MOOTx01 Framework are open source under the Apache License, Version 2.0, published through dedicated public repositories. The MOOTx01 product core in this repository is source-available under the Functional Source License, Version 1.1, with Apache 2.0 as the future license (FSL-1.1-ALv2). The full FSL grant is in the LICENSE file at the repository root. This note states the model in plain language and records the tier ladder.

## The Apache-licensed foundation

The foundation of the MOOTx01 Framework is open source today, not on a timer. Seventeen libraries and kits are published under Apache-2.0 through four public venue repositories, generated from the canonical MOOTx01 source tree with full provenance recorded per release:

- [`moot-core`](https://github.com/codedaptive/moot-core) — SubstrateTypes, SubstrateKernel, SubstrateML, SubstrateLib, EngramLib, IntellectusLib
- [`moot-semantics`](https://github.com/codedaptive/moot-semantics) — AriaLexiconLib, LatticeLib, EideticLib
- [`moot-system`](https://github.com/codedaptive/moot-system) — PersistenceKit, QueueKit, ConvergenceKit, ObserverSink, LoopbackHTTP
- [`moot-memory`](https://github.com/codedaptive/moot-memory) — LocusKit, VectorKit, CorpusKit

Which license governs is determined by where you obtain the code. Code obtained from a venue repository is Apache-2.0, with everything that license permits, including commercial and hosted use, and no Competing Use restriction. The same package source obtained as part of this repository is governed by this repository's FSL grant. This is deliberate multi-licensing by the copyright owner, not a conflict.

What remains under the FSL in this repository is the product core: GeniusLocusKit (the composition layer, estates, grants, and composed recall), NeuronKit and CognitionKit (the Brain layers), VaultKit, and the applications (the ARIA MCP server, the management console, and the installer).

## The grant

The FSL grant below governs the code in this repository. Free to build and share, pay to profit. Make something new and free, go forward, no permission needed. Profit from what you built with it, get a license. The blocked act is offering for money what you built with the code, not who you are. Running your own instance for the free uses below is always free.

Two years after a version is released, that version converts to the Apache License, Version 2.0, automatically. The relicensing is built into the license itself, not a separate promise. The foundation libraries above did not wait for the timer; they are Apache now.

## What is free

Use by an individual for their own life. Use by an organization inside its own internal-facing applications and the tools it uses to deliver services to its clients. Embedding MOOTx01 inside an application that the organization's own clients use. These are not competing uses and need no paid license.

## What needs a license

Offering MOOTx01, or a service whose value is MOOTx01, to third parties as a hosted platform they build on. Selling the code as the product. These are the paid tiers. The Competing Use restriction applies to the FSL-licensed product core in this repository; the Apache-licensed foundation libraries carry no such restriction.

## The tier ladder

- Personal use: forever free.
- Building and sharing non-paid work: free.
- Mobile app: five hundred dollars, lifetime, per app.
- Corporate internal: five thousand dollars, lifetime. Internal-facing only, not for hosting MOOTs as a service for third parties; support contracts available.
- Service provider: five thousand dollars, annually.
- FedRAMP / CMMC: negotiated.

A lifetime tier covers every point release within a major version. The next major version is a new purchase.

## The mechanism

A dual license on a source-available core, beside an open foundation. The public license, the FSL above, states the free-to-build, no-selling grant that everyone receives for this repository. The paid tiers are separate agreements alongside it, not changes to the public license. The foundation venues are governed solely by Apache-2.0 and need no agreement at all.

---

_Current as of MOOTx01 stable/1.0.x and MOOTx01 Framework venue releases v1.0.5._

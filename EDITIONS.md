# Editions

*Open core, commercial edition. Same substrate. Different deployment surface.*

---

MOOTx01 ships in two editions. The open core is the substrate itself, available to anyone, runnable on any hardware, under the user's control. The commercial edition is what makes the substrate deployable in environments that need a contract behind it.

Both editions share the same substrate code. The open core makes the substrate exist. The commercial edition makes it operational where the open core alone cannot go.

---

## Open core

The open core is the substrate. The eleven kits, the ARIA interface, the reference implementations in Swift and Rust, the conformance test harness, the architecture specification.

It runs where the user puts it. Laptop, phone, home server, machine in a closet, a tenant the user runs themselves. There is no cloud requirement. There is no vendor account. There is no licensing meter.

The open core is what makes MOOTx01 portable. ARIA is consistent across implementations because the open core is the reference every implementation conforms to. The user's memory belongs to the user because the substrate is theirs to run.

The open core has no service level agreement. No supported builds. No indemnification. No compliance documentation. The user is responsible for their own deployment.

That is appropriate for most users. It is not appropriate for everyone.

---

## Commercial edition

Some organizations cannot deploy unsupported source-available software. Regulated industries, large enterprises, organizations with legal or compliance requirements that demand a contract behind the software they use. These are not failures of the model. They are operational realities.

The commercial edition exists for those organizations. It is the same substrate, with:

- **Supported builds**: hardened, tested, packaged for production deployment.
- **Certified integrations**: verified compatibility with specific AI clients, storage backends, and deployment environments.
- **Indemnification**: legal protection for organizations that need it.
- **Compliance documentation**: the paper trail regulated environments require.
- **Support contract**: a commitment to respond, fix, and maintain.

The commercial edition is not a different product. It is the same substrate with the operational layer that enterprise environments require. Anything you can do with the open core, you can do with the commercial edition. The commercial edition adds nothing the open core lacks at the substrate level; it adds what enterprises need to deploy the substrate in their environment.

---

## For enterprise clients, under NDA

Two further artifacts are available to enterprise clients under NDA.

**The mathematical treatment.** The formal documentation of the substrate's algorithms and the analysis establishing their validity, the rigorous account of why the core's mathematics does what it claims. This is the depth behind the source-available core, provided to clients who need to evaluate the substrate at that level.

**The knowledge-sharing RFC.** A proposed common protocol and knowledge-signature scheme for sharing AI knowledge between systems, verifiably and portably. It is pending public release. Until then it is open for review by commercial clients, specifically so that those betting on the protocol can raise concerns about its future openness and have a hand in the result before it is finalized. The NDA period is a review window ahead of an open release, not a wall around a proprietary standard.

Contact us for access to either.

---

## Language implementations

The substrate is one design with several implementations, conformance-gated against shared test vectors. They do not all have the same reach, and that is deliberate.

**Swift** (Apple Silicon) and **Rust** (PC/Linux) are the full reference implementations and ship in the community edition. They implement the whole substrate, federation included, and they set the provenance standard the other builds are measured against: the federation-critical core is our own code, specified line-by-line in the engineering cookbook, proven byte-exact against the conformance vectors, with a dependency surface small enough to audit and pin.

**Python** arrives in the community edition at v1.0, auto-generated from the stable core and matured through community testing and validation. It is a standalone, single-machine build by design: the Python build does not federate, and will not. We like Python and use it; the issue is not the language, it is the supply chain. Federation is trust-critical — every node must be able to prove its integrity to the peers it shares data with — and our federating builds make that proof through the provenance standard above. A practical Python deployment inverts it: it stands on the third-party ecosystem — the interpreter, the packaging tooling, and the numeric libraries that make Python productive — a dependency surface that is not ours to pin and too large to audit to that standard. That same standard is what the Enterprise Edition's hardened and certified builds are sold on, so the line is drawn deliberately: the standalone Python build serves the single-machine uses where the provenance bar does not apply. Performance tells the same story: in our cross-language benchmarks pure Python runs the SimHash core two to three orders of magnitude slower than the compiled builds, and the standalone build recovers that with a native fast path that is our own Rust, byte-identical to the Python core — the speed problem is solved with our code, not by widening the third-party surface. The standalone port is a deliberate middle ground, not a federation client in waiting. Contributions that exercise and validate the standalone port are welcome.

**Go** becomes available shortly after v1.0 and ships in the Enterprise Edition only. Contact us for details.

**C**, the "DOOM edition," is planned for v1.5 or v2.0 and ships in the Enterprise Edition only. It is built for maximum portability, meant to run on effectively any hardware. Availability will be announced.

**Further targets — JavaScript, Julia, and C#.** The non-reference builds are not hand-maintained ports. They are produced by our generation-and-gate pipeline: a coding model trained against the substrate's conformance vectors, where only byte-exact output survives the gate. That pipeline is being trained toward JavaScript, Julia, and C# today. Each becomes available when it clears the same gate the reference implementations answer to; edition placement and timing are announced per language.

The substrate capability set is one thing; a given implementation may expose a subset of it. Where this document says the editions share one substrate, that is the level it means: the same design and the same guarantees, realized to different extents by different builds.

---

## Why this structure

The open core creates ecosystem gravity. Every developer who learns ARIA, every application that integrates MOOTx01, every AI client that speaks the protocol, every port to a new language, each of these strengthens the substrate. The source-available core makes that growth possible while the Competing Use restriction keeps the one use we mean to reserve, hosting MOOTs as a service for third parties, from being taken for free.

The commercial edition makes the substrate deployable at scale. The organizations that need a contract are the organizations that move serious workloads. The commercial edition is how MOOTx01 reaches those workloads.

Both editions reinforce each other. The open core's adoption makes the commercial edition the natural enterprise choice. The commercial edition's revenue funds the open core's continued development. Neither edition undermines the other.

The commercial edition follows the strategy Red Hat proved: Red Hat did not win Linux by restricting it, RHEL was GPL, and anyone could rebuild the source. Red Hat won by being the most operationally credible distributor of it, and by owning the trademark that a rebuild could not use. MOOTx01's commercial edition takes the same posture: not the only way to use the substrate, but the credible way to deploy it where deployment is hardest. We differ from Red Hat in one deliberate respect, covered next: our core is source-available rather than fully open, so part of our protection lives in the license itself and not only in the operational layer.

---

## Licensing and the relicensing plan

We have not shipped. We own this choice rather than inherit it, and we state it in the open.

The ARIA language stays open. The interface specification, the grammar, and the conformance test vectors are free for everyone, so anyone can implement MOOTx01, conform to it, and reach their own estate. This is the portability commitment and it is not negotiable: the user's memory belongs to the user.

The substrate code ships source-available under the Functional Source License, Version 1.1, with Apache 2.0 as the future license (FSL-1.1-ALv2). Source-available is the accurate term and the one we use: during its initial term the core is not open source under the OSI definition, because it carries a use restriction. FSL is in the lineage of the Business Source License, stewarded by Sentry and used in production by companies including Sentry, Codecov, and Convex. We chose it as the proven precedent that does what we want with the least custom drafting. It permits every use except Competing Use on the day it ships, and each released version converts to a named open license on a fixed timer written into the license itself. We chose it deliberately over a permissive license, which would not stop the free-riding we care about, and over SSPL or AGPL, whose network-copyleft triggers on the act of serving and would sweep in uses we want to allow.

The free uses are the non-competing uses. Permitted without a commercial license: an individual using MOOTx01 for their own life; a company using it inside its own internal-facing applications; a company embedding it in an application its own clients use. Reserved for a commercial license as Competing Use: offering MOOTx01, or a service whose value is MOOTx01, to third parties as a hosted platform they build on, that is, hosting MOOTs as a service for a fee. Running your own MOOT is always free.

The relicensing commitment is published, not implied. The timer and the open license the substrate converts to are stated in the LICENSE itself, so anyone can see today what the code becomes tomorrow. Under FSL-1.1, each released version converts to the Apache License, Version 2.0, on the second anniversary of the date that version is made available, two years, per version, automatically and irrevocably. We make that commitment knowingly: the code we publish today is code we are content to see under Apache 2.0 in two years.

Our protection therefore rests on two things, not one. The license reserves the hosted-resale case directly, for two years per version. The commercial edition earns the rest the way Red Hat's did, by being the operationally credible path to deployment, together with the trademark in MOOTx01 and ARIA, which a permitted fork or a future Apache-licensed rebuild may not use to pass itself off as ours. Commercial-edition capabilities are scoped per agreement and may include supported and hardened builds, certified integrations, indemnification, compliance documentation, and a support contract; availability is stated in each contract rather than promised in the abstract here. The FedRAMP / CMMC edition is commercial, and the hardening that certification requires is part of what it sells and is not contributed back to the open core. That regulation layer lives outside the public repository and is available after v1.1. You cannot resell what you were never given, so the out-of-repo commercial layer protects the work alongside the license text.

The model above is the position, not a placeholder. The license is in the repository now.

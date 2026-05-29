# Start Here

Three orientation guides at three depths. Pick the one that matches
why you arrived.

## The three guides

**[`SUBSTRATE_FOR_USERS.md`](SUBSTRATE_FOR_USERS.md)** — plain
language. What MOOTx01 is, what the machinery does under the floor,
and what you can trust. Names a couple of techniques (locality-
sensitive hashing, CRDT) so you know they are not made up, leaves
the rest to the technical docs. No prerequisites; written for a
non-technical reader who wants to know what they are trusting.

**[`SUBSTRATE_FOR_DEVELOPERS.md`](SUBSTRATE_FOR_DEVELOPERS.md)** —
for developers evaluating MOOTx01, embedding it in an application,
or integrating with ARIA. Thirteen short sections, one per layer.
Names the technique and points at the kit. Roughly two minutes per
section. Reading this is enough to build on top of MOOTx01 with
confidence; it is not enough to maintain the substrate itself.

**[`SUBSTRATE_FOR_MAINTAINERS.md`](SUBSTRATE_FOR_MAINTAINERS.md)** —
for port maintainers, contributors, and engineers reading the kit
code. Same thirteen layers as the developer guide, but each section
answers three questions: what it is, why we chose it, where it
lives in the code. Adds failure modes, performance numbers, and
conformance notes the developer guide omits.

## Reading order

Pick one. They are not a series; each is complete on its own.
The developer and maintainer guides derive from the same shared
substance — the maintainer version is more detailed, not different
in shape.

After reading the guide that matches your role, the next step
depends on what you came for:

- **Build on top of MOOTx01** → [`../reference/`](../reference/)
  for the kit-level specs you will integrate against.
- **Maintain or port the substrate** → [`../engineering/`](../engineering/)
  for the cookbook and methodology, then [`../decisions/`](../decisions/)
  for the record of every kernel and architecture selection.
- **Understand the design rationale** → [`../concepts/`](../concepts/)
  for the topology, the canon, the case studies, and the paper.

## Conventions

These files are evergreen. They do not carry version stamps or
date suffixes because the substance is meant to stay correct as
the substrate evolves. Material changes happen by rewriting in
place, not by versioning.

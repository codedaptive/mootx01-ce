# Contributing to MOOTx01

Thank you for your interest in MOOTx01. This document explains how to
contribute, and how that changes at the 1.0 release.

The short version: **before 1.0, contribute by opening an issue. After
1.0, contribute by opening a pull request.** The reason for the split
is below.

---

## Where we are: before 1.0

MOOTx01 has not reached 1.0. The substrate is under active, rapid
development, and a great deal of the underlying mathematics is still
being tied out and validated. Development happens in our enterprise
codebase and lands in this community edition as soon as each change
tests out. The community edition is downstream of that work: it moves
when a change has been validated, not before.

While the substrate is moving this fast, **we are not accepting pull
requests.** A pull request written against today's code would often be
stale against a moving target before it could be reviewed and merged,
which is frustrating for a contributor and unfair to the work they put
in. We would rather not put anyone in that position.

**What we ask instead: if you know something, open an issue.**

That genuinely means anyone who knows anything. If you have spotted an
error in the mathematics, found a bug, seen a correctness problem, have
a suggestion, or know something about a technique or a reference that
bears on the work, open an issue and tell us. Issues are the right
channel during this phase precisely because they let your knowledge
reach us without being tied to a specific line of a fast-changing
codebase. A clear issue describing a problem or an idea is, right now,
more useful to the project than a patch.

Good issues tend to include: what you observed or are proposing, why it
matters, and — where it applies — a pointer to the relevant part of the
substrate, a reference, or a worked example. You do not need to have a
fix in hand. Surfacing the right question is a real contribution.

---

## At 1.0: pull requests open

When MOOTx01 reaches 1.0, the substrate stabilizes against a published
conformance contract, and the calculus changes. At that point pull
requests open, and people who want to contribute code are more than
welcome. We expect to say more about review process, coding standards,
and conformance expectations as 1.0 approaches; this document will be
updated then.

### Contributor License Agreement

When pull requests open at 1.0, contributions will require a signed
**Contributor License Agreement (CLA)** before they can be merged.

This is not a formality we are imposing for its own sake. The community
edition is source-available under the Functional Source License
(FSL-1.1-ALv2; see `LICENSE` and `LICENSING.md`), it converts to Apache
2.0 on the schedule the license sets, and a commercial edition is built
from the same substrate. For all of that to hold together, the project
needs clear, documented rights to include a contribution in the
community edition, to relicense it under the future Apache license on
schedule, and to include it in the commercial edition. The CLA is what
makes those rights unambiguous, for the project and for the contributor
both.

The exact CLA text will be published at 1.0. If you are weighing a
larger contribution and want to understand the terms before then, open
an issue and we will point you to the current draft.

---

## Reporting security issues

**Do not report security-sensitive issues in public.**

MOOTx01 is trust-critical infrastructure: it holds a person's memory and,
in federated configurations, mediates what one estate shares with another.
A security problem disclosed in a public issue is a problem disclosed to
everyone, including anyone who might exploit it, before it can be fixed.

If you believe you have found a security vulnerability — anything touching
data integrity, the federation trust boundary, the access perimeter, or
the chain-of-custody guarantees — report it privately rather than opening
a public issue.

> **Security contact:** see [SECURITY.md](SECURITY.md) for the private
> reporting channels and what to expect after you report.

We will acknowledge a security report, work the problem privately, and
coordinate disclosure once a fix has tested out and shipped to the
community edition.

---

## A note on conduct

Engage in good faith, assume good faith in others, and keep discussion
focused on the work. That covers it.

---

*This document describes the contribution process before 1.0. It will be
revised at the 1.0 release to cover the pull-request workflow, the CLA,
and the security contact in full.*


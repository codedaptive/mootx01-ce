# Contributing to MOOTx01

Thank you for your interest in MOOTx01. This document explains how to
contribute.

The short version: **contributions are open.** Open an issue to report a
problem or propose an idea, or open a pull request to contribute code.
Pull requests require a signed Contributor License Agreement before they
can be merged — see below.

---

## Issues: tell us what you know

If you have spotted an error in the mathematics, found a bug, seen a
correctness problem, have a suggestion, or know something about a technique
or a reference that bears on the work, **open an issue and tell us.** You do
not need to have a fix in hand — surfacing the right question is a real
contribution.

Good issues tend to include: what you observed or are proposing, why it
matters, and — where it applies — a pointer to the relevant part of the
substrate, a reference, or a worked example.

How the code moves is worth understanding when you file: development
happens in our enterprise codebase and lands in this community edition as
each change is validated. The community edition is downstream of that work
— it moves when a change has tested out.

---

## Pull requests

Pull requests are open and welcome. Before you invest significant effort in
a large change, it is worth opening an issue first to check the direction —
because the community edition tracks validated work from upstream, a large
patch can collide with a change already in flight.

We will say more about review process, coding standards, and conformance
expectations over time; for now, keep changes focused, include tests where
they apply, and describe what the change does and why.

### Contributor License Agreement

Code contributions require a signed **Contributor License Agreement (CLA)**
before they can be merged. The full text is in [`CLA.md`](CLA.md).

This is not a formality imposed for its own sake. The community edition is
source-available under the Functional Source License (FSL-1.1-ALv2; see
`LICENSE` and `LICENSING.md`), it converts to Apache 2.0 on the schedule the
license sets, and a commercial edition is built from the same substrate. For
all of that to hold together, the project needs clear, documented rights to
include a contribution in the community edition, to relicense it under the
future Apache license on schedule, and to include it in the commercial
edition. The CLA is what makes those rights unambiguous, for the project and
for the contributor both.

You confirm the CLA on your first pull request; it then covers that
contribution and any future contributions you submit. If you are weighing a
larger contribution and want to discuss the terms first, open an issue.

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

> **Security contact:** report privately via GitHub's
> [Report a vulnerability](https://github.com/codedaptive/mootx01-ce/security/advisories/new)
> form, or email <security@codedaptive.com>. Please do not file a public
> issue for a security problem. See [`SECURITY.md`](SECURITY.md) for the
> full policy.

We will acknowledge a security report, work the problem privately, and
coordinate disclosure once a fix has tested out and shipped to the
community edition.

---

## A note on conduct

Engage in good faith, assume good faith in others, and keep discussion
focused on the work. That covers it.

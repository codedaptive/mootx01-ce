---
title: The Approach to Memory Retrieval in MOOTx01
release: "1.1"
date: 2026-09-17
description: How MOOTx01 finds stored evidence, why it uses several search paths, and where the measured figures live.
---

# The Approach to Memory Retrieval in MOOTx01

Answering a question from memory is two jobs. First find the right records.
Then turn them into an answer. MOOTx01 keeps the two apart, and measures them
apart, because a good answer built on the wrong evidence is still wrong — and
because a system that scores them as one number cannot tell you which half
failed.

## Six ways to find a record

Ask for "the invoice Ana sent in March" and matching words is enough. Ask
"what did we decide about pricing?" and the words in the question may appear
nowhere in the record that answers it. So MOOTx01 searches several ways at
once:

- **Words.** Records that use the terms you used.
- **Meaning.** Records that say the same thing in different words.
- **Time.** Records from the period you are asking about, whether that is when
  something happened or when it was written down.
- **Relationships.** Records reached by following a link from a record already
  found — the person, the project, the document it belongs to.
- **Known fields.** A direct lookup when the question names something the
  system stores explicitly, like a date or an owner.
- **Partial cues.** A half-remembered fragment, widened into candidates worth
  checking.

Each path is good at a different kind of question. Exact lookups, questions
about a period, counting, comparison, "what replaced this", vague recollection,
and questions that need several hops all take different routes to the evidence.
No one path is best at all of them, which is why there are six rather than one.

## Choices are measured, not asserted

Which paths run, and how their results are combined, is settled by running the
benchmarks rather than by argument. A comparison holds everything fixed — the
corpus, the questions, the binary, the port, the scale, and any model used to
answer or judge — and changes only the one thing under test. Whatever ships as
the default records the run that chose it, so a setting can always be traced
back to the measurement behind it.

## What finding cannot do on its own

Retrieval locates evidence. It does not count how often something happened
across many records, decide what you meant when the question is ambiguous, or
state a fact that exists only as the sum of several records. Those need a
model, so figures that involve one name the model that produced them. The
figures that measure MOOTx01 itself — did it find the right evidence, and how
fast — stay separate and name no model.

## Notes the system writes for itself

When the machine is idle, MOOTx01 can read across related memories and write
short derived notes, each citing the records it came from. A note retires when
the records under it change. These notes are ordinary memories once written,
so the six search paths find them like anything else, and nothing about
retrieval changes when the feature is switched off.

This closes part of the gap between finding and stating: a count or a
cross-record conclusion becomes something the system can find, with its sources
attached, instead of something it must assemble on every question.

## Where the numbers are

`RESULTS.md` lists every measured surface and what each one must cover. The
page for each benchmark defines its task, its metrics, and how to reproduce it.
Every published figure names the run it came from, the binary and product
version, the protocol and schema version, the port and scale, and the models
involved where there are any.

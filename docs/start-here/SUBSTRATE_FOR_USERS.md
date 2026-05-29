---
title: "What MOOTx01 Is Built On"
subtitle: "A plain-language tour of the machine behind your memory"
author: "Bob Pankratz"
date: "2026-05-21"
---

> If you have read ABOUT.md, you know what MOOTx01 is for. This is the companion piece. It explains, in plain language, what is going on under the floor. You do not need to read it to use MOOTx01. You may want to read it if you would like to know what you are trusting.

# Why this exists

You have heard the promise before. Memory that survives your sessions. Memory that learns. Memory that stays yours.

The promise has been made by a lot of products. Most of them did not have the machinery behind it. We built the machinery. This document explains, in regular English, how the machinery works.

There are thirteen pieces. Each piece has a name. Some of those names are familiar (the hash, the log, the graph). A few are mathematical (SimHash, CRDT). We will name a couple of the techniques so you know they are not made up. We will leave the rest to the technical documentation, which exists and is available to engineers who maintain the system.

You do not need to follow every detail. You need to come away with the right gut feeling: that the work was done, that the choices were deliberate, and that the substrate underneath your memory is not a hand-wave.

# It is one thing, used many ways

Most software systems pick a shape for their data and stick to it. A database is a table. A search engine is an index. A graph database is a graph.

MOOTx01 is one thing that can be read as several. The same row of data can be looked at as a bundle of facts, a fingerprint, a coordinate, a node in a graph, a moment in a log, or a count in a tally. None of these are copies. They are views.

We did this because memory does not have one shape. Sometimes you want a list. Sometimes you want a date range. Sometimes you want a theme. Building one shared object that supports all those questions was harder than building six different stores. The payoff is that nothing has to be translated, and nothing can drift out of sync.

# Everything has an address

Every piece of memory has an address that says where it sits in human knowledge. The address uses two systems: a library classification scheme that has been around for a century, and Wikidata, which is the open knowledge graph behind much of the modern web.

The point of the address is that "things about taxes" stay near each other regardless of who wrote them or when. A note from last March about a deduction lives near a note from this morning about an audit, because both of them have addresses in the same neighborhood. The neighborhood is public and standardized, so two MOOTs can recognize the same neighborhood without coordinating in advance.

# Facts as bits, queries as math

Each row of memory carries three little columns of bits. One says what kind of row it is. One says how it came in. One says where it came from.

When you ask a question, the substrate does not read paragraphs of text. It does arithmetic on the bits. A processor can do this kind of arithmetic billions of times per second. That is why recall feels instant even when the memory grows large.

# A fingerprint that means something

Every row also has a kind of fingerprint. It is 256 bits long, and the rule that makes it is what the math people call a locality-sensitive hash. The plain-English version: rows that are similar end up with similar fingerprints.

Why this matters: comparing two fingerprints is fast. Comparing two whole rows is slow. The fingerprint lets the substrate ask "are these two things alike" the way a human asks "do these two faces look like the same person." Not perfectly, but quickly, and quickly is usually what you need.

The fingerprint has four parts, each capturing a different aspect of the row (what it is about, what category, when and how, and from where). The substrate can weight the parts differently for different questions.

# Skip what does not matter

When a query comes in, the substrate does not check every row. It checks summaries first. Each room of memory keeps a small summary that combines all of its rows in a way that can answer "is there anything in here that could possibly match," but not what specifically.

If the summary says no, the room is skipped. Whole sections of memory get bypassed in microseconds. This is the trick that lets MOOTx01 stay fast as it grows.

# Counts, not just yes or no

Sometimes the substrate needs to know not just whether something exists, but how often. For that, it keeps counts in vectors that can be added together cleanly. If two MOOTs want to compare notes on themes, they trade vectors and add them. If a user erases a set of memories, the substrate subtracts those memories out of every count they touched. No rebuilds. No recomputes.

This sounds like simple addition, and that is exactly why it works. Simple operations that compose are sturdier than clever operations that do not.

# Nothing is ever silently overwritten

Every change to your memory is recorded as an event. The events are immutable. The current state of memory is the result of replaying the events in order. The state from any past moment is the result of replaying up to that moment.

This is a deliberate design choice with a technical name (a grow-only set CRDT, with hybrid logical clocks). The user-facing consequences are what matter.

Three of them.

Your memory is auditable. Every change has a record. Nothing is rewritten quietly.

Your memory can live in more than one place without going out of sync. Two devices that have seen the same events end up in the same state.

You can rewind. The substrate can show you what your memory looked like at any past moment.

# Learning we can read

MOOTx01 learns over time. What patterns appear, what things tend to come together, what tends to follow what. The learning is not buried inside a model's weights. It lives in small tables that can be inspected.

This is the difference between a model that learns and a substrate that learns. A model that learns is a black box. A substrate that learns has the learning sitting out in the open, where you can see it, export it, audit it, and (if you choose) take it with you.

The substrate also has a small daemon that runs while you sleep. It reviews the day's events, surfaces themes, and updates the tables. By morning, the recall for tomorrow's questions is already prepared.

# Memories that connect

Memory is not a list. It is a network. The things you write down connect to the things you wrote down before. The substrate can read that network as a graph and answer two questions a list cannot.

The first question is "what is central to my thinking." Some pieces of memory get linked to over and over again; the substrate notices and surfaces them as keystones.

The second is "what is connected to this, two or three steps out." That is how the substrate finds things you would not have thought to ask for directly.

# Ranking that learns from you

When the substrate returns answers, it ranks them. The ranking combines several measures of relevance: how close in concept, how close in fingerprint, how close in meaning if a model is involved. The weights on these measures are not fixed. They learn from your choices.

If you pick one suggestion over another, the substrate nudges its ranking slightly toward the kind of choice you made. Over time, the ranking becomes yours. The technique behind this is well known and has been used in everything from sports rating systems to recommendation engines.

The important part is the direction. The ranking serves you. It does not serve a metric that lives somewhere else.

# When two MOOTs talk

You can have more than one MOOT, and your MOOT can talk to other MOOTs you authorize.

Two MOOTs do not merge. They handshake. They exchange enough information to compare notes on the questions you allow, and they stay separate the rest of the time. The handshake has guardrails. Your MOOT and your spouse's MOOT can compare notes on the household calendar. That does not implicitly let your spouse's employer compare notes with you.

When MOOTs aggregate up to a shared tier (a household, a team), the substrate adds a small, mathematically bounded amount of noise to each contribution. The noise is enough to make individual records unrecoverable from the aggregate, without breaking the aggregate's usefulness. This is a standard privacy technique with a formal guarantee behind it.

You stay in control of every gathering. Nothing crosses a boundary unless you opened it.

# The right tool for the chip

The substrate's heaviest operations have several versions. A simple one. A fast one that uses the parallel instructions in modern processors. A version that runs on the graphics chip. The system picks the right one at startup based on the hardware it finds itself on.

Every version produces exactly the same answer. There is a conformance test that proves it. A faster version that gives a different answer is not faster; it is broken. We hold ourselves to that.

We chose this approach because the right answer depends on the chip and the size of the job, and we would rather measure than guess. The measurements are recorded. Anyone who looks at the engineering documents can see why a given version was chosen.

# Guardrails that hold

Every piece of memory in the substrate exists in one of a small number of states. The transitions between states are not free; they follow rules. A piece of memory cannot be both secret and public. A piece that has been removed stays removed. The substrate checks every change before it commits.

These rules are not suggestions. The substrate enforces them mechanically. The reason this matters: every other promise in this document depends on those rules holding. Your secret memory stays secret because the substrate makes "secret and public" unreachable, not unlikely.

# What you can trust

The substrate was built deliberately. The choices were measured, not asserted. The math has a written record that exists, that the team maintains, and that supports every claim made here.

If you would like the next layer of detail, the developers' guide goes deeper, with the techniques named and the kits pointed at. If you would like the layer beyond that, the maintainers' guide adds failure modes and performance numbers.

You do not need to read either of them.

You came here to understand whether the thing you are trusting was built well. The honest answer is yes, and the work is open to inspection. The memory is yours. The substrate is yours to look at. The promise has machinery behind it.

That is what MOOTx01 is built on.

---

*A plain-language overview. Derived from the developers' and maintainers' guides. The full mathematical treatment is held internally.*

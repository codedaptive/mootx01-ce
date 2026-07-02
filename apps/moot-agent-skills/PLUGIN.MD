# Why a Plugin?

MOOTx01 can install three ways. Each one gives you more than the last.
Understanding the difference tells you why the plugin is worth the extra step.

---

## Mode 1: The Server

You run `mootx01 install` and the server wires itself in.

Your AI coding tool can now call MOOTx01 tools. It can search memory, file
facts, read journals, and link ideas together.

**What's missing:** The AI doesn't know *when* to use those tools. You have to
ask it. Every time. "Hey, search memory for the last decision about X." If you
forget to ask, it forgets MOOTx01 exists.

This is still useful. But the value depends entirely on you remembering to ask.

---

## Mode 2: The Skill

`mootx01 install --mode skills` adds a SKILL.md file to your config.

A skill is a short instruction file. It tells the AI what MOOTx01 does and
when to reach for it. Now the AI notices when you're working on something that
might need memory — like continuing a project, checking a past decision, or
building on earlier work — and it uses MOOTx01 on its own.

**What's missing:** The skill is just a file sitting in a folder. Your AI
coding tool doesn't manage it. It won't show up in a plugin list. It has no
version. There's no `disable` button. It doesn't get updates. If you switch
computers or share your setup with your team, you copy the file by hand.

This is much better. But it's invisible infrastructure. You know it's there.
Nobody else does.

---

## Mode 3: The Plugin

`mootx01 install` (the default) does everything in Mode 1 and Mode 2 — and then
goes further.

It installs MOOTx01 as a *registered plugin* inside your AI coding tool.

Here's what that unlocks:

**It shows up in the plugin list.** Open your tool's plugin panel. MOOTx01 is
there with a name, a description, and a version number. You can see it. You can
disable it. You can update it. You know exactly what's installed.

**You get a slash command.** Type `/mootx01-start` in your editor and the AI
orients itself to MOOTx01 — pings the server, reads the journal, maps the
estate — before it starts work. One command instead of four manual tool calls.

**Team distribution works.** If you use Cursor Teams, Claude Code Enterprise,
or Codex for a workspace, an admin can install MOOTx01 once and push it to
everyone. The server wires itself into each member's config. The skill activates
for everyone. Nobody has to copy files by hand.

**The tool knows it's there.** When your AI coding tool manages a plugin, it
treats it differently than a loose file. It can validate the package, handle
updates cleanly, and respect the tool's own governance controls — like
enterprise policies about which plugins are allowed.

---

## Why It Matters

The difference between a skill file and a plugin is the difference between
a note taped to your monitor and a notification in your calendar.

Both say the same thing. But one gets managed. One shows up in searches. One
can be shared with a click. One survives a laptop wipe. One works across your
whole team without anyone touching a config file.

MOOTx01's value compounds over time. Memory you wrote three months ago becomes
useful today. That compounding only happens if MOOTx01 is consistently active —
for you, for your team, across every session.

A loose skill file can go missing. A registered plugin doesn't.

That's why we built the plugin. Not to check a box. Because the value of memory
depends on it always being there.

---

## Quick Reference

| | Mode 1: Server | Mode 2: Skills | Mode 3: Plugin |
|---|---|---|---|
| MCP tools available | ✓ | ✓ | ✓ |
| AI knows when to use them | | ✓ | ✓ |
| Shows in plugin list | | | ✓ |
| Slash command | | | ✓ |
| Version + update support | | | ✓ |
| Team / enterprise push | | | ✓ |

---

## Which Hosts Support Plugins

| Host | Plugin Support |
|---|---|
| Claude Code | ✓ Full plugin |
| Cursor | ✓ Full plugin + rules |
| OpenAI Codex | ✓ Full plugin |
| Gemini CLI | ✓ Extension (plugin equivalent) |
| Google Antigravity | ✓ Full plugin |
| GitHub Copilot | Coming in v1.1 |
| Cline | Skills only (no plugin system yet) |
| Hermes | Skills only (no plugin system yet) |
| opencode | Skills only (no plugin system yet) |

Hosts that don't have a plugin system yet still get Mode 2. The skill
activates automatically. They just don't get the management layer on top.

---

*See `README.md` for the full adapter library and per-host install paths.*

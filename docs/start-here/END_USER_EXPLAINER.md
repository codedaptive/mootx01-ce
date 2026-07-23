# MOOTx01 CE For End Users

MOOTx01 CE is local long-term memory for AI assistants.

It gives your AI a place to remember useful things beyond one chat session while keeping that memory on your machine by default.

## The Short Version

Your AI has a context window. That is what it can think with right now.

MOOTx01 gives it a memory estate. That is what it can remember from later.

You can use MOOTx01 to let your AI:

- remember project decisions,
- recall prior conversations,
- connect related notes,
- keep facts and journal entries,
- search memory across sessions,
- prepare better answers because past context is no longer lost.

## Why This Matters

Without a memory layer, an AI starts each session mostly from scratch. You can paste context back in, but that costs time, attention, and tokens.

MOOTx01 CE gives supported AI clients a local memory surface. The AI can file memories, search them later, connect them, and report estate status through a shared interface.

The goal is not to replace the AI model. The goal is to give the AI a memory it can use across sessions.

## What Gets Installed

A normal MOOTx01 CE product install may include:

- the `mootx01` command-line tool,
- a local resident daemon,
- MCP client configuration for supported AI tools,
- the `moot-mgr` management dashboard if available,
- local data files for your MOOT estate.

The default local services are:

| Surface | Address |
|---|---|
| MOOTx01 resident daemon | `http://127.0.0.1:4242` |
| Management dashboard | `http://127.0.0.1:4200` |

These are loopback addresses. They are intended to be reachable from your own machine, not from the public internet.

## What Local Memory Means

MOOTx01 CE is designed around user-owned memory.

That means:

- the memory estate lives locally by default,
- AI clients talk to it through a local interface,
- the user controls what gets written,
- the user can inspect and manage the local system,
- memory is not meant to disappear when one AI chat ends.

MOOTx01 is not Claude, ChatGPT, Codex, Cursor, Cline, Continue, or a local model. It is a memory layer those tools can use.

## What ARIA Means

ARIA is the interface language MOOTx01 uses.

You can think of ARIA as the shared vocabulary for memory operations. AI clients use ARIA through MCP tools such as memory filing, memory search, facts, links, journal entries, and estate status.

The important part is that different clients can speak the same MOOTx01 memory language.

## What The Dashboard Is

The dashboard is served by `moot-mgr`.

Default address:

    http://127.0.0.1:4200

It is for observing and managing the local MOOTx01 system. Depending on the build, it may show health, estate status, pipeline activity, topology, or management controls.

If the dashboard is not installed or not running, MOOTx01 may still be usable through the command line and AI client integration.

## What The Daemon Is

The resident daemon is the background process your AI clients can share.

Default address:

    http://127.0.0.1:4242

Instead of every AI client starting its own memory process, supported clients can connect to the resident daemon. That gives them a shared local memory surface.

## What Your AI Can Do After Install

Once MOOTx01 is installed and wired into an AI client, you can ask the AI to:

- remember a project preference,
- recall prior project decisions,
- file facts,
- search memory,
- connect related memories,
- show estate status,
- summarize what it knows from your local MOOT.

Example prompts:

    Remember that for this project we prefer small focused commits.

    Search my MOOT for what we decided about the installer.

    File this as a project memory: the dashboard port is 4200 and the daemon port is 4242.

    Show me the current status of my MOOT estate.

    What do you remember about this project from previous sessions?

## Maturity

MOOTx01 CE is a released 1.0 product, locally installed and
locally owned. It is a local tool, not a managed cloud service.
Verify what was installed with `mootx01 status`.

## What A Good AI Install Should Do

A good AI assistant should:

1. Explain MOOTx01 in plain language.
2. Ask your platform and AI client.
3. Tell you what it will install.
4. Run the correct install command.
5. Verify the service.
6. Show you where the dashboard is.
7. Confirm your AI client can see MOOTx01.
8. Help you file and recall one test memory.
9. Tell you how to troubleshoot or uninstall.

If an AI assistant skips verification, ask it to verify.

## Going Further: Make Your AI Use MOOTx01 Automatically

Installing MOOTx01 wires the tools into your AI client. A *great* install does one more
thing: it enables the matching **MOOTx01 adapter** for your client, so the AI instinctively
uses its memory — recalling, filing, and linking on its own — instead of waiting to be asked.

Those adapters live in `apps/moot-agent-skills/`, one folder per client (Claude, Codex,
Cursor, Cline, and others). After the runtime is verified, a good assistant copies the right
adapter into your client's config and confirms the behavior with a couple of memory prompts.
If it is not offered, ask for it.
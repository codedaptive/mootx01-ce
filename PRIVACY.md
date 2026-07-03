# MOOTx01 Privacy Policy

**Effective: July 3, 2026**

This policy covers MOOTx01 Community Edition — the `mootx01` binary, its
local services, and the MOOTx01 plugins and skills for AI clients (Claude
Code, Cursor, Codex, Gemini CLI, and others) published by Codedaptive LLC.

## The short version

MOOTx01 is on-device software. Your memories, facts, journals, and every
other piece of data it stores live in a local estate on your machine.
**Codedaptive does not collect, receive, transmit, sell, or share any of
your data.** There is no vendor account, no required cloud, and no server
of ours that ever sees your content.

## What the software stores, and where

MOOTx01 stores the content you and your AI clients file into it — memories,
facts, links, journal entries, recall indexes, and telemetry — in local
databases on your machine (by default under your home directory). This data
never leaves your machine unless you explicitly export it, sync it through
a storage provider you configure (such as your own iCloud or PostgreSQL),
or share it through a federation grant you create. All of those channels
are owned and controlled by you, not by Codedaptive.

Telemetry (operational statistics) is written to a local store on your
machine. It is not transmitted to Codedaptive or anyone else.

## Network connections the software makes

- **Update availability check.** The plugin's optional update-check hook
  and the CLI's update mechanisms query GitHub's public release API for
  `codedaptive/mootx01-ce` to compare version numbers. This sends GitHub a
  normal HTTPS request; no estate content, identifiers, or usage data is
  included. GitHub's own privacy policy governs that request.
- **Installation.** Installing via Homebrew, winget, or the install
  scripts downloads release assets from GitHub. Those services' policies
  govern those downloads.
- **Your AI clients.** MOOTx01 exposes tools to AI clients over the Model
  Context Protocol on your machine. What an AI client does with content it
  reads from your estate — including sending it to a model provider — is
  governed by that client's and provider's policies, not this one.

That is the complete list. The MOOTx01 services bind to loopback addresses
(`127.0.0.1`) and reject connections from other devices.

## Data we collect through this repository and our sites

If you open a GitHub issue, discussion, or pull request, that content is
public and governed by GitHub's terms. Our websites (mootx01.ai,
codedaptive.com) are static informational sites; any analytics they use are
disclosed on those sites.

## Data retention and deletion

Your data is yours, on your disk. Delete the estate directories and it is
gone. Codedaptive holds nothing to delete on your behalf.

## Children's privacy

MOOTx01 is a developer tool not directed at children, and we collect no
personal information from anyone, including children.

## Changes to this policy

Changes will be committed to this file with the repository's normal history,
so every revision is public and diffable.

## Contact

Questions: **privacy@codedaptive.com** · Security reports: see
[SECURITY.md](SECURITY.md).

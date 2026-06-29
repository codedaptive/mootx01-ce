# Fixing Slow, Token-Wasting Searches

If your code searches sometimes spew tens of kilobytes of garbled, minified
text — wasting time at the terminal and burning tokens and time in an AI
coding session — this is the fix. It takes two minutes and it is worth it.

## The symptom

A search for a common token occasionally floods the screen with one
enormous unreadable line of JSON-ish text, then the real results. In an AI
coding agent it is worse: that flood is sent to the model, so it costs both
latency and tokens on every search that hits it.

## Why it happens

It is **long lines**, not a slow disk or too many files:

- The substrate ships a few **generated / minified files** whose content is
  one very long line — embedded install bundles and generated artifacts can
  be **50,000+ characters on a single line**.
- `grep` (and `ugrep`) print the **entire matching line**. A single match
  inside one of those files dumps the whole 50KB line.
- Only **ripgrep (`rg`)** can be told to truncate long lines. `grep` and
  `ugrep` cannot, and they ignore ripgrep's config file.
- Some AI coding harnesses have **no separate search tool** — searches run
  through the shell, and a shell `grep` may be remapped to `ugrep`, which
  does not truncate. So `rg` is the only path that stays cheap.

## The fix

### 1. Tell ripgrep to truncate long lines

Create a file named `.ripgreprc` in your home directory with:

```
--max-columns=2000
--max-columns-preview
```

`2000` is deliberately generous: it clears every normal source line (long
signatures, kit-name lists) so they print in full, while still capping the
rare generated single-line files that run tens of thousands of characters. A
much tighter cap (e.g. 200) clips legitimate long lines and looks like the
tool is mangling your results.

Then point ripgrep at it from your shell startup file (`.zshrc` for zsh,
`.bashrc` for bash) by adding this line:

```sh
export RIPGREP_CONFIG_PATH="$HOME/.ripgreprc"
```

Open a new terminal. Now an `rg` match inside a 50KB line prints the first
~2000 characters followed by `[... omitted end of long line]` instead of the
whole thing, while ordinary code lines print in full.

### 2. If you use an AI coding agent (e.g. Claude Code)

This is the step people miss. **An agent's shell usually does not read your
interactive shell startup file**, so the `export` above never reaches the
agent — its searches keep flooding. Set the variable in the agent's *own*
environment instead.

For Claude Code, add it to the `env` block of the settings file in your home
directory (`.claude/settings.json`):

```json
{
  "env": {
    "RIPGREP_CONFIG_PATH": "/absolute/path/to/your/home/.ripgreprc"
  }
}
```

Use the **absolute** path to the `.ripgreprc` you created in step 1 (JSON
does not expand `~` or `$HOME`). To confirm it worked: a search that used to
dump ~55KB should now return only a couple hundred bytes.

## Habits that avoid the problem entirely

- Prefer **`rg`** over `grep` for content searches.
- When you only need *where* or *how many*, use `rg -l` (list files),
  `rg -c` (count per file), or `rg -o` (print only the match) — none of these
  can ever dump a whole long line.
- One-off, without the config file: `rg -M2000 --max-columns-preview PATTERN`.
- For a `grep` or `git grep` baked into a script that ignores the config,
  pipe it through `cut -c1-2000`.

## Why ripgrep specifically

`rg` respects `.gitignore`, so it skips build output automatically, and it is
the only common search tool that can cap long lines through a config file.
`grep` and `ugrep` do neither. For this codebase, `rg` is the default.

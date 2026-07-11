# MOOTx01 Memory Adapter

Drop-in `/memories` backend with governance for the Anthropic
`memory_20250818` tool.

## What it does

Any Claude 4+ / Fable 5 agent that thinks it is reading and writing
`/memories` files is actually reading and writing **governed MOOTx01
drawers** — with dedup, provenance, sensitivity floor, confirmation
state, and a full audit trail included.

## The differentiator

Every model-written memory lands as **unconfirmed** with derived trust.
A startup scan or audit pass can quarantine suspect lessons using the
estate's contained filter and anomaly lenses. This is the poisoning
defense the ecosystem currently lacks — the memory tool contract gives
models write access; MOOTx01 gives you the governance to trust (or not
trust) what they wrote.

## Two surfaces

### 1. MCP tool (built into mootx01)

The mootx01 daemon registers a `memory` tool on its MCP surface that
matches Anthropic's contract exactly. Claude Code and Claude Desktop
users already connected to mootx01 as an MCP server get the memory tool
for free — no adapter needed.

### 2. Python SDK handler (this package)

For Messages API users who run the tool-use loop themselves:

```python
from moot_memory import MootMemoryTool
import anthropic

client = anthropic.Anthropic()
memory = MootMemoryTool(base_url="http://127.0.0.1:4242")

runner = client.beta.messages.tool_runner(
    model="claude-opus-4-8",
    max_tokens=1024,
    messages=[{"role": "user", "content": "Remember that Acme prefers email."}],
    tools=[memory],
)
final = runner.until_done()
```

Or standalone without the SDK:

```python
from moot_memory import MootMemoryHandler

handler = MootMemoryHandler(base_url="http://127.0.0.1:4242")
result = handler.execute({"command": "view", "path": "/memories"})
```

## Op mapping

| memory_20250818 | Estate behavior |
|---|---|
| view (dir) | enumerate drawers in wing="memories" |
| view (file) | drawer content with line numbers |
| create | capture as unconfirmed drawer |
| str_replace | supersede: new content, old withdrawn (full lineage) |
| insert | supersede: content with insertion applied |
| delete | soft withdrawal (never hard-erase from model ops) |
| rename | capture at new location, withdraw old |

## Security

- **Path traversal protection**: all paths validated against `/memories`
- **Model writes land unconfirmed**: poisoning quarantine seam
- **Deletes are soft withdrawals**: reversible, audit trail preserved
- **Sensitivity floor**: adapter wing is Normal
- **File size cap**: 100KB per file
- **No hidden files**: dotfiles rejected

## Tests

```bash
# Against the running daemon
python -m pytest apps/moot-memory-adapter/tests/

# The poisoning quarantine test
python -m pytest apps/moot-memory-adapter/tests/test_memory_adapter.py::TestPoisoningQuarantine -v
```

## Requirements

- Running mootx01 daemon (v1.0.22+)
- Python 3.10+
- `anthropic` SDK (optional, for the BetaAbstractMemoryTool subclass)

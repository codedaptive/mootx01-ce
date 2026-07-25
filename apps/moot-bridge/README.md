# moot-bridge

`moot-bridge` is an optional stdio MCP multiplexer for exactly two memory
backends. An AI client launches one bridge process; the bridge presents the
primary backend's tool surface, serves reads from that primary, and mirrors
configured writes into the secondary.

It is useful for migrations, comparison periods, and deliberate dual-backend
operation. It is not part of the standard MOOTx01 install and is not shipped as
a release asset.

## Routing contract

| Client traffic | Bridge behavior |
|---|---|
| `initialize` and other request methods | Forward to the current primary |
| MCP notifications | Forward best-effort to both backends |
| `tools/list` | Return the primary's tools plus `bridge_set_primary` and `bridge_status` |
| Configured query tool | Call the primary only and return its response |
| Configured write tool | Return the primary response, then translate and mirror the write to the secondary |
| Unclassified primary tool | Call the primary only |

The bridge does not merge query results from both backends. “Union” means that
classified writes can be maintained in both stores while one selected backend
answers reads.

A secondary write failure is counted and suppressed so it does not change the
primary response already returned to the client. Check `bridge_status`; a
non-zero secondary-failure count means the two stores may have diverged.

## Bridge-owned tools

### `bridge_status`

Reports:

- current primary and secondary;
- configured backend names;
- mean and p95 request latency by backend/operation;
- total samples;
- non-fatal secondary write failures.

### `bridge_set_primary`

```json
{
  "backend": "mootx01"
}
```

The selected backend becomes primary for the next request. Reads and returned
responses come from it; classified writes continue to mirror to both.

## Build

Swift:

```sh
cd apps/moot-bridge
swift build -c release
.build/release/moot-bridge --config bridge-config.json
```

Rust:

```sh
cd apps/moot-bridge/rust
cargo build --release
target/release/moot-bridge --config ../bridge-config.json
```

## Configure

The JSON configuration names two launch commands, their tool mappings, and the
initial primary. Each `verbMap` must identify the backend's write and query
tools. Optional argument mappings let the bridge translate the primary call
into the secondary backend's vocabulary.

```json
{
  "backendA": {
    "name": "mempalace",
    "command": "mempalace-mcp --palace /path/to/palace",
    "verbMap": {
      "write": "mempalace_add_drawer",
      "query": "mempalace_search",
      "contentArg": "content",
      "queryArg": "query",
      "constantArgs": {
        "wing": "scratch",
        "room": "notes"
      },
      "resultFormat": {
        "kind": "jsonObjects",
        "contentKey": "text"
      }
    }
  },
  "backendB": {
    "name": "mootx01",
    "command": "MOOTX01_DATA_DIR=/path/to/data mootx01 serve",
    "verbMap": {
      "write": "moot_file_memory",
      "query": "moot_memory_search",
      "contentArg": "content",
      "queryArg": "query",
      "constantArgs": {
        "location": "scratch/notes"
      },
      "resultFormat": {
        "kind": "mootText"
      }
    }
  },
  "primary": "mempalace"
}
```

`primary` must exactly match one backend name. Point the AI client's MCP
configuration at `moot-bridge --config <path>` instead of either backend
directly.

## Operational guidance

1. Confirm both backend commands work independently over stdio.
2. Start the bridge with a configuration file readable only by the intended
   account.
3. Call `bridge_status` after startup and after changing the primary.
4. Monitor secondary failures during a migration or comparison period.
5. Before retiring either backend, reconcile the stores using backend-native
   export or validation tools.

The bridge does not provide durable retry or replay for failed secondary
writes. It reports the gap; the operator owns reconciliation.

## Security boundary

The bridge launches both configured child processes and passes memory content
to both for classified writes. Treat the configuration as executable,
sensitive input:

- use absolute executable and data paths;
- do not accept bridge configuration from an untrusted source;
- avoid embedding secrets in the JSON when environment-specific secret
  injection is available;
- restrict configuration-file permissions;
- remember that the secondary receives every successfully translated write,
  even though it does not answer the read.

The bridge is a local transport component, not an authentication boundary and
not a remote deployment surface.

## Failure behavior

| Failure | Effect |
|---|---|
| Primary unavailable | The client operation fails |
| Secondary unavailable during write | Primary result is preserved; failure counter increases |
| Write cannot be translated | Primary result is preserved; failure counter increases |
| Query tool called | Secondary is not contacted |
| Unknown tool called | Primary handles it; no mirroring |
| Client closes stdin | Bridge exits and child processes are torn down |

## Implementation

- Swift: `Sources/moot-bridge`
- Rust: `rust/`
- Acceptance configuration: `Tests/Fixtures/acceptance-config.json`
- Core tests: `Tests/moot-bridgeTests/` and `rust/tests/`

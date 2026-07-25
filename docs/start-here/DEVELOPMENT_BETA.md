# 1.1 development beta

This branch is where compatible 1.1 capabilities land and are qualified before
promotion. It moves continuously: APIs, migrations, documentation, and feature
flags can change between commits. The beta suffix counts the pushes made to
`candidate/1.1.x` since that branch was created. Pin the commit you test, use a
disposable or backed-up estate, and report the version and commit with every
beta issue.

Current 1.1 work includes the native MOOTx01-App, CorpusKit shared-content
architecture, Apple surfaces and on-demand federation, and the foundation for
continuous Obsidian synchronization. The roadmap distinguishes implemented
behavior from planned work.

Build the beta directly:

```bash
# Swift — macOS 26+
swift build -c release --package-path apps/mootx01 --product mootx01
SWIFT_BIN="$(swift build -c release --package-path apps/mootx01 --show-bin-path)"
"$SWIFT_BIN/mootx01" --version

# Rust — Linux or Windows
cargo build --locked --release --manifest-path apps/mootx01/rust/Cargo.toml
apps/mootx01/rust/target/release/mootx01 --version
```

The plugin packages committed on this branch are development artifacts. The
public marketplace plugin remains on the stable 1.0 channel.


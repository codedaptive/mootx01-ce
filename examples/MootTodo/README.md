# MootTodo

A universal (iOS + macOS) MOOTx01 SDK example that demonstrates the **sidecar
pattern**: an ordinary to-do app keeps its own primary store (a tiny Codable
JSON file) while mirroring every write into a **parallel MOOT** with about five
lines of glue. The MOOT accumulates a full-text-searchable memory beside the
app — surfaced by a "Search memory" field — showing that an app can gain memory
"for free" by sidecaring. App Intents (`CaptureDrawerIntent`,
`RecallDrawerIntent`) share the same estate via `GatewayRuntime.shared`, so
Siri/Shortcuts and the app's own UI read and write one MOOT.

Open in Xcode via:

```sh
xcodegen generate
```

Then build and run the `MootTodo` scheme. See `GUIDE.md` for a plain-language
walkthrough and `SPEC.md` for the technical details.

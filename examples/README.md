# MOOTx01 SDK Examples

**Heavily-commented** reference apps for developers who compile and read them (not end users).
Each shows a different way to use MOOTx01, on the same SDK seam the `apps/Mootx01` app uses.
Build any with `xcodegen generate` in its folder, then open the `.xcodeproj`.

| Example | Pattern it teaches | MOOT's role |
|---|---|---|
| **MootNotepad** | Build a **new app on top of MOOT** | MOOT is the *only* store — notes are drawers |
| **MootTodo** | Add a **sidecar to your own app** | App keeps its own store; MOOT runs *parallel* (~5 lines) for free-text memory |
| **MootCalendarIngest** | Leverage a **legacy app you can't change** | Apple Calendar is read-only-untouched; its events flow *into* MOOT |

Each folder has:
- `App/` — the source (over-commented; the comments are the lesson).
- `SPEC.md` — concise technical spec (what it demonstrates, the MOOT calls, the intents).
- `GUIDE.md` — an 8th-grade-reading-level explanation (what it is, how it works, what to try).
- `project.yml` — xcodegen spec (regenerate the `.xcodeproj` from it).

All three reach MOOTx01 through the shared `MootGateway` library in `apps/Mootx01`, register real
App Intents (callable from Shortcuts/Siri once installed), and seed sample data on first launch.

See `docs/decisions/ADR-005` for the architecture these sit on. The older `Sidecar_Demo_macOS`
remains as the minimal CLI sidecar wiring reference.

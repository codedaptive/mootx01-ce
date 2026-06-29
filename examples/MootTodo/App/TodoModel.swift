import Foundation
import Observation
import MootGateway   // MootBridge — the public ARIA tool surface onto the MOOT.
import AriaMCP       // JSONValue — the value type every tool argument uses
                     // (e.g. .string("..."), .bool(true)).

// ============================================================================
// TodoModel — the app's PRIMARY store, plus the ~5-line MOOT sidecar.
// ============================================================================
//
// Read this file as two layers stacked on top of each other:
//
//   LAYER 1 (the whole top of the file): a completely ordinary to-do list
//   backed by a Codable JSON file in the app container. No MOOTx01 here at all.
//   This is the app's source of truth.
//
//   LAYER 2 (the small, clearly-marked SIDECAR section): the handful of lines
//   that mirror each todo into a parallel MOOT and let us search it. This is
//   the part the example exists to show. Notice how little code it is.
//
// The model is @MainActor because it owns UI-facing state; @Observable so
// SwiftUI re-renders when `todos` or `searchResults` change.

/// One to-do item. Plain Codable — this is the app's own data shape, nothing
/// to do with the MOOT. The MOOT will mirror these, but it does not define them.
struct Todo: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var done: Bool = false
}

@MainActor
@Observable
final class TodoModel {

    // ========================================================================
    // LAYER 1 — THE PRIMARY STORE (the app's own data; no MOOT involved)
    // ========================================================================

    /// The to-do list. This is the source of truth the UI renders.
    private(set) var todos: [Todo] = []

    /// Where we persist the primary store: a tiny JSON file in the app
    /// container. We deliberately use a hand-rolled Codable file instead of
    /// SwiftData so the app stays dependency-free and the sidecar contrast is
    /// obvious — the MOOT is the ONLY heavyweight store in play, and it's the
    /// parallel one.
    private let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base
            .appendingPathComponent("MootTodo", isDirectory: true)
            .appendingPathComponent("todos.json")
    }()

    init() {
        loadPrimaryStore()
    }

    /// Load the to-do list from the JSON file. Missing file = empty list.
    private func loadPrimaryStore() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Todo].self, from: data)
        else { return }
        todos = decoded
    }

    /// Persist the to-do list to the JSON file. Best-effort; a failure here
    /// does not crash the app.
    private func savePrimaryStore() {
        let parent = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(todos) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // ------------------------------------------------------------------------
    // Primary-store mutations. The UI calls these. Each one updates the app's
    // own store FIRST, then (LAYER 2) mirrors the change into the MOOT.
    // ------------------------------------------------------------------------

    /// Add a todo. Writes to the primary store, then mirrors into the MOOT.
    func add(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let todo = Todo(title: trimmed)
        // 1) Primary store: the app's own truth.
        todos.append(todo)
        savePrimaryStore()

        // 2) Sidecar: mirror into the parallel MOOT. (See mirrorToMoot below.)
        Task { await mirrorToMoot(todo) }
    }

    /// Toggle a todo's done flag. Writes to the primary store, then re-mirrors
    /// the updated state into the MOOT so the memory reflects "done" too.
    func toggle(_ todo: Todo) {
        guard let idx = todos.firstIndex(of: todo) else { return }
        // 1) Primary store.
        todos[idx].done.toggle()
        savePrimaryStore()

        // 2) Sidecar: re-file the updated state.
        let updated = todos[idx]
        Task { await mirrorToMoot(updated) }
    }

    // ========================================================================
    // LAYER 2 — THE MOOT SIDECAR (this is the part the example is about)
    // ========================================================================
    //
    // The bridge onto the parallel MOOT. Handed to us at launch by the app
    // (which got it from GatewayRuntime.shared.bridge(), so it's the SAME
    // estate the App Intents use). Optional because the to-do list must work
    // even if the MOOT failed to attach — the sidecar is additive, never
    // load-bearing.
    private var bridge: MootBridge?

    /// The "room" every mirrored todo is filed into. In MOOTx01 a drawer's
    /// `location` is the room it lives in — think of it as a folder/topic. We
    /// keep all mirrored todos in one room so they're easy to search together.
    private let todosRoom = "todos"

    /// Search results, rendered under the search field. Each entry is one line
    /// the MOOT returned. (See the note below about why these are strings.)
    private(set) var searchResults: [String] = []

    /// A human-readable note about the last MOOT problem, if any, for the UI.
    private(set) var mootStatus: String = ""

    /// Receive the shared bridge from the app at launch.
    func attach(bridge: MootBridge) {
        self.bridge = bridge
    }

    /// Record an attach failure for display. The app still runs without a MOOT.
    func recordMootError(_ error: Error) {
        mootStatus = "MOOT unavailable: \(error.localizedDescription)"
    }

    // ------------------------------------------------------------------------
    // mirrorToMoot — THE SIDECAR ITSELF. This is the ~5 lines the whole
    // example is built to show off. One todo in → one drawer filed in the MOOT.
    // ------------------------------------------------------------------------
    private func mirrorToMoot(_ todo: Todo) async {
        guard let bridge else { return }   // No MOOT? Skip silently; app is fine.

        // We render the todo as a short, human-readable line of content and
        // file it into the "todos" room via moot_file_memory. That's the entire
        // mirror: build content, call the tool. The MOOT now remembers this
        // todo and its done-state, full-text searchable, forever.
        //
        // Example content: "TODO: Buy milk [open]"  /  "TODO: Buy milk [done]"
        let state = todo.done ? "done" : "open"
        let content = "TODO: \(todo.title) [\(state)]"

        let call = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string(content),
            "location": .string(todosRoom),   // location == the room to file into
        ])

        // moot_file_memory returns human-readable text like:
        //   "filed memory <id>\nroom: todos\nlineage: <uuid>"
        // We don't need to parse it here; we just note any error for the UI.
        if call.isError {
            mootStatus = "MOOT mirror failed: \(call.text)"
        } else {
            mootStatus = "Mirrored to MOOT: \(content)"
        }
    }

    // ------------------------------------------------------------------------
    // search — query the parallel MOOT. This is the capability the app gained
    // "for free" by sidecaring: full-text search over everything it ever filed,
    // including the done/open history the little JSON store never kept.
    // ------------------------------------------------------------------------
    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bridge, !trimmed.isEmpty else {
            searchResults = []
            return
        }

        // moot_memory_search does the full-text recall over the MOOT.
        let call = await bridge.callTool("moot_memory_search", arguments: [
            "query": .string(trimmed),
            "limit": .integer(20),
        ])

        if call.isError {
            mootStatus = "MOOT search failed: \(call.text)"
            searchResults = []
            return
        }

        // KNOWN SDK EDGE — comment this clearly for the reader:
        // The ARIA tool surface returns TEXT, not structured drawer objects. So
        // moot_memory_search hands back lines shaped like:
        //
        //     found N memory(s)
        //     <id>  [room]  <preview>
        //     <id>  [room]  <preview>
        //     ...
        //
        // To list results we parse those lines ourselves. A production app would
        // want a STRUCTURED recall tool that returns typed drawers; until that
        // ships, parsing the text is the documented approach. We keep the parse
        // intentionally forgiving: drop the "found N" header and any blank
        // lines, and show the rest verbatim.
        // NOTE(integrate): replace this text-parse with a structured recall
        // tool when the SDK exposes one.
        let lines = call.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.lowercased().hasPrefix("found ") }

        searchResults = lines
    }

    // ------------------------------------------------------------------------
    // seedSampleDataIfEmpty — first-launch sample data.
    // ------------------------------------------------------------------------
    //
    // SAMPLE-DATA APPROACH: on first launch the MOOT is empty. We detect that
    // by searching it; if the search comes back with nothing, we seed three
    // sample todos. Seeding runs through the normal add() path, so each sample
    // is written to the primary store AND mirrored into the MOOT — exactly as a
    // user tap would do. Result: the app has content out of the box and the
    // MOOT has something to search immediately.
    func seedSampleDataIfEmpty() async {
        guard let bridge else { return }

        // Ask the MOOT if it already contains any "TODO" content. Seed guard
        // is content-marker based ("TODO"), not room-marker based.
        let probe = await bridge.callTool("moot_memory_search", arguments: [
            "query": .string("TODO"),
            "limit": .integer(1),
        ])

        // moot_memory_search returns "found 0 memory(s)" when the estate is
        // empty for this query. If we see a "found 0" (or an error), treat the
        // MOOT as fresh and seed it. Otherwise leave it alone.
        let isEmpty = probe.isError || probe.text.lowercased().contains("found 0")
        guard isEmpty, todos.isEmpty else { return }

        // Seed via the normal add path so the sidecar mirrors each one too.
        add(title: "Buy milk")
        add(title: "Walk the dog")
        add(title: "Read the MOOTx01 sidecar guide")
    }
}

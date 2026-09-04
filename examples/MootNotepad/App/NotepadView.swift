import SwiftUI
import MootGateway   // MootBridge, GatewayCall — the MOOT seam.
import AriaMCP       // JSONValue (.string(…)) — how tool arguments are built.

// =============================================================================
// NotepadView.swift — the UI and the MOOT wiring.
// =============================================================================
//
// This file has three parts:
//   1. Note            — a plain value type for one row, plus the DECODER that
//                        turns a tool's structured result rows into Notes.
//   2. NotepadModel    — the @MainActor view-model. EVERY MOOT call lives here.
//   3. NotepadView     — the SwiftUI list + editor.
//
// Read NotepadModel first if you want to see the MOOT in action — it is the
// part of the app that actually talks to the substrate.


// MARK: - 1. Note  (a row in the list)

enum NotepadRoom {
    /// The MOOT "room" (location) every MootNotepad note is filed into.
    static let value = "notes"
}

/// One note, as the app understands it.
///
/// MOOT does not hand us a "Note" type of its own — it hands us structured
/// result rows. Every recall-family tool (`moot_memory_search`,
/// `moot_memory_get`, …) answers with a text block for humans AND a
/// `structuredContent` block whose `results` array carries one object per
/// drawer: `id`, and where known `room`, `subject`, `content`. A `Note` is
/// what we build from one of those rows.
struct Note: Identifiable, Hashable {
    /// The drawer id from the MOOT. This is the handle we pass to
    /// moot_withdraw_memory to delete the note. It is MOOT's id, not ours.
    let id: String
    /// The room (location) the drawer is filed in — always "notes" here.
    let room: String
    /// The full note body, verbatim, as `moot_memory_get` returned it at
    /// depth:full. Search rows do not carry content (they are travel rows:
    /// id, subject, room); the body is fetched by id in a second call.
    var content: String

    // -------------------------------------------------------------------------
    // decode — the STRUCTURED-RESULT contract, made concrete.
    // -------------------------------------------------------------------------
    //
    // `IntentCallResult.structured` is the tool's `structuredContent` block,
    // verbatim JSON. For the recall family it is:
    //
    //     { "results": [ { "id": "…", "room": "…", "subject": "…",
    //                      "content": "…" }, … ] }
    //
    // Optional fields are ABSENT (never null) when the tool has nothing to
    // say: search rows omit `content`; a drawer without a subject omits
    // `subject`. The text block exists for people and for audit; an app reads
    // the structured block and never re-parses the text.

    /// Every result row as a dictionary, or [] when the tool sent no block.
    static func rows(in structured: JSONValue?) -> [[String: JSONValue]] {
        guard case let .object(top)? = structured,
              case let .array(items)? = top["results"] else { return [] }
        return items.compactMap { item in
            if case let .object(row) = item { return row }
            return nil
        }
    }

    /// A `Note` from one `moot_memory_get` row at depth:full. Returns nil for
    /// rows that are not a note we can show: no content (the drawer is gated
    /// or opaque), or an id that is not a UUID.
    static func from(row: [String: JSONValue]) -> Note? {
        guard case let .string(id)? = row["id"],
              case let .string(content)? = row["content"] else { return nil }

        // Security: only accept UUID ids. The id is what drives the
        // moot_withdraw_memory call on delete, so it must come from the
        // structural contract, never from anything a note body could contain.
        // MOOT drawer ids are always UUIDs under the current substrate.
        guard UUID(uuidString: id) != nil else { return nil }

        let room: String
        if case let .string(r)? = row["room"] { room = r } else { room = "" }
        return Note(id: id, room: room, content: content)
    }
}
// MARK: - 2. NotepadModel  (every MOOT call lives here)

/// The view-model. It owns the `MootBridge` and exposes plain async methods the
/// UI calls. Each method is a thin shell: build JSONValue arguments → call a
/// `moot_*` tool on the bridge → translate the text result into SwiftUI state.
///
/// `@MainActor` + `@Observable` means SwiftUI re-renders automatically whenever
/// `notes`, `lastError`, or `status` change, and all that state lives on the
/// main thread (Swift 6 strict-concurrency clean).
@MainActor
@Observable
final class NotepadModel {

    /// The room every note is filed into.
    let room = NotepadRoom.value

    /// The notes currently shown in the list. Rebuilt by `refresh()` from the
    /// MOOT — this array is a CACHE of what the substrate holds, never the
    /// source of truth. The MOOT is the source of truth.
    private(set) var notes: [Note] = []

    /// The estate summary text (from moot_estate_status), shown in the toolbar
    /// so you can watch the drawer count change as you add/remove notes.
    private(set) var status: String = ""

    /// The last error to surface in a banner. nil means "no error".
    private(set) var lastError: String?

    /// The MOOT seam. nil until `attach(bridge:)` runs at launch. Every method
    /// guards on this; if the bridge isn't ready, the call is a no-op.
    private var bridge: MootBridge?

    // -- wiring -------------------------------------------------------------

    /// Receive the shared bridge from the app's launch path.
    func attach(bridge: MootBridge) {
        self.bridge = bridge
    }

    /// Record an error for the UI banner.
    func report(error: Error) {
        lastError = error.localizedDescription
    }

    // -- READ: list/search notes -------------------------------------------

    /// Rebuild `notes` from the MOOT.
    ///
    /// Two calls. `moot_memory_search` with a broad query and `limit: 200`
    /// returns travel rows — ids, subjects, rooms — but no bodies. We collect
    /// the ids and hand them to `moot_memory_get` in one batched call at
    /// depth:full, which returns the verbatim content and the room for each.
    /// Results are filtered to rows whose room is ours ("notes"). The limit
    /// bounds the list; it is not a guaranteed exhaustive search.
    func refresh(query: String = "") async {
        guard let bridge else { return }

        // Build the tool arguments. A broad query ("*" matches broadly) plus a
        // generous limit recalls the whole notebook. When the user types a
        // search term we pass that instead — same tool, narrower query.
        let effectiveQuery = query.isEmpty ? "*" : query
        let search = await bridge.callTool("moot_memory_search", arguments: [
            "query": .string(effectiveQuery),
            "limit": .integer(200),
        ])

        if search.isError {
            lastError = String(localized: "Search failed: \(search.text)")
            return
        }
        lastError = nil

        // Travel rows → ids. Nothing else on a search row is needed here.
        let ids: [JSONValue] = Note.rows(in: search.structured).compactMap { row in
            if case let .string(id)? = row["id"] { return .string(id) }
            return nil
        }
        guard !ids.isEmpty else {
            notes = []
            await refreshStatus()
            return
        }

        // Hydrate: one batched moot_memory_get at depth:full gives every
        // drawer's room and verbatim content in one round trip.
        let get = await bridge.callTool("moot_memory_get", arguments: [
            "ids": .array(ids),
            "depth": .string("full"),
        ])
        if get.isError {
            lastError = String(localized: "Could not load notes: \(get.text)")
            return
        }

        notes = Note.rows(in: get.structured)
            .compactMap(Note.from(row:))
            // Keep only OUR room. (A drawer filed elsewhere isn't a notepad note.)
            .filter { $0.room == room }
        await refreshStatus()
    }
    // -- CREATE: file a new note -------------------------------------------

    /// File a new note into the MOOT.
    ///
    /// This is `moot_file_memory`: `content` is the note body, `location` is
    /// the room. The tool returns text like "filed memory <id>\nroom: notes",
    /// which we don't need to parse — we just refresh the list afterward so the
    /// new drawer appears. (Re-reading from the MOOT after a write keeps the UI
    /// in step with it: it shows what the substrate actually stored, not what we hoped.)
    func add(content: String) async {
        guard let bridge else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let call = await bridge.callTool("moot_file_memory", arguments: [
            "content": .string(trimmed),
            "location": .string(room),
        ])
        if call.isError {
            lastError = String(localized: "Could not save note: \(call.text)")
            return
        }
        lastError = nil
        await refresh()
    }

    // -- DELETE: retire a note ---------------------------------------------

    /// Delete a note by withdrawing its drawer from the MOOT.
    ///
    /// `moot_withdraw_memory` takes the drawer `id` we captured during parse.
    /// "Withdraw" is MOOT's word for retiring a drawer — the app calls it
    /// "delete." Again we refresh from the substrate afterward rather than just
    /// removing the row locally, so the list reflects the MOOT's real state.
    func delete(_ note: Note) async {
        guard let bridge else { return }
        let call = await bridge.callTool("moot_withdraw_memory", arguments: [
            "id": .string(note.id),
        ])
        if call.isError {
            lastError = String(localized: "Could not delete note: \(call.text)")
            return
        }
        lastError = nil
        await refresh()
    }

    // -- STATUS: estate summary --------------------------------------------

    /// Pull the human-readable estate summary for the toolbar.
    ///
    /// `moot_estate_status` returns a text overview of the whole MOOT. We show
    /// its first line so you can literally watch the estate change as you work.
    private func refreshStatus() async {
        guard let bridge else { return }
        let call = await bridge.callTool("moot_estate_status", arguments: [:])
        guard !call.isError else { return }
        status = call.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
    }

    // -- SEED: sample data on first run ------------------------------------

    /// Sample-data approach: if no notes are found in the opening probe, file
    /// three example notes so the list has content out of the box. The probe
    /// is a normal `refresh()`; if it leaves the list empty, we seed. Delete
    /// the SQLite file to reset.
    func seedIfEmpty() async {
        guard bridge != nil else { return }

        // Ask the MOOT whether our room already has notes.
        await refresh()
        guard notes.isEmpty else { return }
        // File the three sample notes. We reuse `add`, which files into our
        // room and refreshes — so after seeding the list is already populated.
        let samples = [
            "Welcome to MootNotepad — every note here is a MOOT drawer.",
            "Try adding a note: tap the pencil, type, and save.",
            "Search as you type: the list is the MOOT's answer.",
        ]
        for sample in samples {
            await add(content: sample)
        }
    }
}


// MARK: - 3. NotepadView  (the UI)

/// The notepad screen: a list of notes with an editor presented as a sheet.
/// Universal — this SwiftUI compiles unchanged for iOS and macOS.
@MainActor
struct NotepadView: View {

    // The model is owned by the app and passed in; @Bindable lets us bind to
    // its observable state for SwiftUI updates.
    @Bindable var model: NotepadModel

    /// The text the user is typing in the search field.
    @State private var searchText = ""
    /// Whether the "new note" editor sheet is showing.
    @State private var isEditing = false
    /// The draft body for a new note.
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            List {
                // An optional error banner, driven by the model's lastError.
                if let error = model.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                // One row per note. The row shows the full note body;
                // by expanding; swipe-to-delete withdraws the drawer.
                Section {
                    ForEach(model.notes) { note in
                        NoteRow(note: note)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    // Delete = withdraw the drawer from the MOOT.
                                    Task { await model.delete(note) }
                                } label: {
                                    Label(String(localized: "Delete"), systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    // The estate summary, straight from moot_estate_status.
                    Text(model.status.isEmpty ? String(localized: "Notes") : model.status)
                        .font(.caption)
                        .textCase(nil)
                }
            }
            .navigationTitle(String(localized: "MootNotepad"))
            // The search field re-queries the MOOT as the user types.
            .searchable(text: $searchText, prompt: String(localized: "Search notes"))
            .onChange(of: searchText) { _, newValue in
                // Each keystroke calls moot_memory_search with the new term.
                // (For a teaching example this immediate-search is fine; a
                // production app would debounce.)
                Task { await model.refresh(query: newValue) }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        draft = ""
                        isEditing = true
                    } label: {
                        Label(String(localized: "New Note"), systemImage: "square.and.pencil")
                    }
                }
            }
            // The editor sheet for composing a new note.
            .sheet(isPresented: $isEditing) {
                NoteEditor(draft: $draft) {
                    // On save: file the draft as a new MOOT drawer.
                    Task {
                        await model.add(content: draft)
                        isEditing = false
                    }
                } onCancel: {
                    isEditing = false
                }
            }
        }
    }
}

/// One note row: shows the note body moot_memory_get returned.
private struct NoteRow: View {
    let note: Note
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.content)
                .lineLimit(3)
            // The drawer id, shown small, so the MOOT's handle is visible —
            // this is the value passed to moot_withdraw_memory on delete.
            Text(note.id)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// A minimal editor for a new note. Saving files a drawer; cancel discards.
private struct NoteEditor: View {
    @Binding var draft: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            // A multi-line text editor for the note body.
            TextEditor(text: $draft)
                .padding()
                .navigationTitle(String(localized: "New Note"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Save"), action: onSave)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel"), action: onCancel)
                    }
                }
        }
    }
}

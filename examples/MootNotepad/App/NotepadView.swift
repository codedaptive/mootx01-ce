import SwiftUI
import MootGateway   // MootBridge, GatewayCall — the MOOT seam.
import AriaMCP       // JSONValue (.string(…)) — how tool arguments are built.

// =============================================================================
// NotepadView.swift — the UI and the MOOT wiring.
// =============================================================================
//
// This file has three parts:
//   1. Note            — a plain value type for one row, plus the PARSER that
//                        turns a moot_memory_search text line into a Note.
//   2. NotepadModel    — the @MainActor view-model. EVERY MOOT call lives here.
//   3. NotepadView     — the SwiftUI list + editor.
//
// Read NotepadModel first if you want to see the MOOT in action — it is the
// part of the app that actually talks to the substrate.


// MARK: - 1. Note  (a row in the list)

/// One note, as the app understands it.
///
/// MOOT does not hand us a "Note" object — it hands us TEXT. A `Note` is what
/// we reconstruct by parsing that text. The fields here are exactly what a
/// `moot_memory_search` line gives us: a drawer `id`, the `room` it's filed
/// in, and a short `preview` of its content.
struct Note: Identifiable, Hashable {
    /// The drawer id from the MOOT. This is the handle we pass to
    /// moot_withdraw_memory to delete the note. It is MOOT's id, not ours.
    let id: String
    /// The room (location) the drawer is filed in — always "notes" here.
    let room: String
    /// A short preview of the note's content, as the search tool returned it.
    /// NOTE(integrate): the search tool returns a *preview*, not the full body.
    /// For this teaching example the preview IS the note text we show and edit.
    /// A production app wanting the verbatim full body would call a structured
    /// "get drawer by id" tool — see the edge note at the top of the app file.
    var preview: String

    // -------------------------------------------------------------------------
    // parse — the TEXT-RESULT EDGE, made concrete.
    // -------------------------------------------------------------------------
    //
    // `moot_memory_search` returns lines shaped like:
    //
    //     <id>  [room]  <preview text...>
    //
    // i.e. the id, then the room in square brackets, then the preview — fields
    // separated by runs of whitespace. We split on the bracketed room to peel
    // the three fields apart. This string-parsing is the single most important
    // thing to understand about building on the current tool surface: the
    // substrate speaks text, so the app re-derives structure from text.
    //
    // Returns nil for lines that aren't note rows (e.g. the "found N memory(s)"
    // header, or a blank line), so callers can simply compactMap over them.
    static func parse(line: String) -> Note? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // The room appears as "[notes]". Find that bracketed token; if a line
        // has no bracketed room, it isn't a drawer row (it's the header), so
        // we skip it.
        guard let open = trimmed.firstIndex(of: "["),
              let close = trimmed.firstIndex(of: "]"),
              open < close else {
            return nil
        }

        // id = everything before the "[" (trimmed of trailing spaces).
        let id = String(trimmed[trimmed.startIndex..<open])
            .trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }

        // room = the text inside the brackets.
        let afterOpen = trimmed.index(after: open)
        let room = String(trimmed[afterOpen..<close])

        // preview = everything after the "]" (trimmed of leading spaces).
        let afterClose = trimmed.index(after: close)
        let preview = String(trimmed[afterClose...])
            .trimmingCharacters(in: .whitespaces)

        return Note(id: id, room: room, preview: preview)
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

    /// The room every note is filed into. Shared with the Shortcuts provider
    /// via NotepadRoom so a voice-captured note lands where the UI reads.
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
    /// We call `moot_memory_search`. Passing a broad query recalls everything
    /// in the estate; we then keep only rows whose room is ours ("notes"),
    /// because the estate could in principle hold drawers from other rooms
    /// (e.g. ones filed by the generic Capture intent, or sample data). The
    /// `limit` keeps the list bounded.
    ///
    /// THE TEXT EDGE: the result is text, so we split it into lines and run
    /// each through Note.parse. See Note.parse for the line shape.
    func refresh(query: String = "") async {
        guard let bridge else { return }

        // Build the tool arguments. A broad query ("*" matches broadly) plus a
        // generous limit recalls the whole notebook. When the user types a
        // search term we pass that instead — same tool, narrower query.
        let effectiveQuery = query.isEmpty ? "*" : query
        let call = await bridge.callTool("moot_memory_search", arguments: [
            "query": .string(effectiveQuery),
            "limit": .integer(200),
        ])

        if call.isError {
            lastError = String(localized: "Search failed: \(call.text)")
            return
        }
        lastError = nil

        // Parse the text result into Note rows. The first line is usually the
        // "found N memory(s)" header, which Note.parse returns nil for, so it
        // drops out of the compactMap automatically.
        let parsed = call.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { Note.parse(line: String($0)) }
            // Keep only OUR room. (A drawer filed elsewhere isn't a notepad note.)
            .filter { $0.room == room }

        notes = parsed
        await refreshStatus()
    }

    // -- CREATE: file a new note -------------------------------------------

    /// File a new note into the MOOT.
    ///
    /// This is `moot_file_memory`: `content` is the note body, `location` is
    /// the room. The tool returns text like "filed memory <id>\nroom: notes",
    /// which we don't need to parse — we just refresh the list afterward so the
    /// new drawer appears. (Re-reading from the MOOT after a write keeps the UI
    /// honest: it shows what the substrate actually stored, not what we hoped.)
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

    /// Sample-data approach: if the notebook is empty the very first time the
    /// app runs, file three example notes so the list has content out of the
    /// box. We detect "empty" by asking the MOOT — if a broad search finds no
    /// notes in our room, we seed.
    ///
    /// This runs once per fresh estate. Delete the SQLite file (see the app
    /// file for its location) to reset and re-seed.
    func seedIfEmpty() async {
        guard let bridge else { return }

        // Ask the MOOT whether our room already has notes.
        let probe = await bridge.callTool("moot_memory_search", arguments: [
            "query": .string("*"),
            "limit": .integer(10),
        ])
        let hasNotes = probe.text
            .split(separator: "\n")
            .compactMap { Note.parse(line: String($0)) }
            .contains { $0.room == room }
        guard !hasNotes else { return }

        // File the three sample notes. We reuse `add`, which files into our
        // room and refreshes — so after seeding the list is already populated.
        let samples = [
            "Welcome to MootNotepad — every note here is a MOOT drawer.",
            "Try adding a note: tap the pencil, type, and save.",
            "Ask Siri: \"Search my notes in MootNotepad.\"",
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

                // One row per note. Tapping shows the (preview) content inline
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

/// One note row: shows the preview text the MOOT search returned.
private struct NoteRow: View {
    let note: Note
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.preview)
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

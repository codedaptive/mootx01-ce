import SwiftUI
import MootGateway   // Only needed indirectly here; the model holds the bridge.

// ============================================================================
// ContentView — the UI. Small on purpose.
// ============================================================================
//
// The top of the screen is an ordinary to-do list driven by the PRIMARY store
// (model.todos). The bottom is a "Search memory" field that queries the
// PARALLEL MOOT (model.search). Watch how the two halves use two different
// stores: the list reads model.todos (the app's JSON store), the search reads
// model.searchResults (the MOOT). That split IS the sidecar story.
//
// @MainActor because it touches the @MainActor model. Universal: this same
// SwiftUI body compiles for iOS and macOS unchanged.

@MainActor
struct ContentView: View {

    // The shared model. ContentView never talks to the MOOT directly — it goes
    // through the model, which owns the bridge. UI stays MOOT-agnostic; the
    // sidecar lives in the model.
    @Bindable var model: TodoModel

    // Local UI state for the two text fields. Not persisted — just what the
    // user is typing right now.
    @State private var newTitle: String = ""
    @State private var searchQuery: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // ----- THE PRIMARY STORE: the to-do list -----
                // This list renders model.todos — the app's OWN JSON-backed
                // store. No MOOT here. Tapping a row toggles done, which (in the
                // model) also re-mirrors into the MOOT.
                List {
                    Section(String(localized: "todos.section.title")) {
                        ForEach(model.todos) { todo in
                            Button {
                                model.toggle(todo)   // primary store + sidecar mirror
                            } label: {
                                HStack {
                                    Image(systemName: todo.done
                                          ? "checkmark.circle.fill"
                                          : "circle")
                                    Text(todo.title)
                                        .strikethrough(todo.done)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // ----- THE PARALLEL MOOT: search results -----
                    // This section renders model.searchResults — lines that came
                    // back from moot_memory_search over the MOOT, NOT from the
                    // to-do list. This is the capability the app got "for free"
                    // by sidecaring: full-text search across everything ever
                    // filed, including done/open history.
                    Section(String(localized: "search.section.title")) {
                        if model.searchResults.isEmpty {
                            Text(String(localized: "search.empty.hint"))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.searchResults, id: \.self) { line in
                                // We show the raw line the MOOT returned. Recall
                                // the known edge: the tool surface answers in
                                // text, so each line is "<id>  [room]  <preview>".
                                Text(line)
                                    .font(.callout)
                                    .monospaced()
                            }
                        }
                    }
                }

                // ----- Input bar: add a todo, and search the memory -----
                VStack(spacing: 8) {
                    // Add-to-the-primary-store field.
                    HStack {
                        TextField(String(localized: "todos.add.placeholder"),
                                  text: $newTitle)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addTapped() }
                        Button(String(localized: "todos.add.button")) { addTapped() }
                            .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    // Search-the-MOOT field. Submitting queries the parallel
                    // estate via the model.
                    HStack {
                        TextField(String(localized: "search.placeholder"),
                                  text: $searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { searchTapped() }
                        Button(String(localized: "search.button")) { searchTapped() }
                            .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal, 16)   // semantic edges, not .left/.right
                .padding(.vertical, 12)

                // A tiny status line so the reader can SEE the sidecar firing
                // (e.g. "Mirrored to MOOT: TODO: Buy milk [open]").
                if !model.mootStatus.isEmpty {
                    Text(model.mootStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                        .padding(.horizontal, 16)
                }
            }
            .navigationTitle(String(localized: "app.title"))
        }
    }

    // Add a todo through the model (primary store + sidecar mirror), then clear.
    private func addTapped() {
        model.add(title: newTitle)
        newTitle = ""
    }

    // Search the MOOT through the model. Runs async because the tool call is
    // async; results land in model.searchResults and SwiftUI re-renders.
    private func searchTapped() {
        let q = searchQuery
        Task { await model.search(q) }
    }
}

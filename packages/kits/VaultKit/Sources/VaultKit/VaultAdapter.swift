import Foundation

/// The modular adapter seam: vault files ⇄ `NoteIR`.
///
/// `VaultAdapter` is the one place where a concrete vault format
/// (Obsidian today; Joplin / Bear / Logseq / plain-Markdown later) is
/// taught how to read itself into the canonical `NoteIR` and write
/// `NoteIR` back out. Everything above this seam — `DrawerMapping` and
/// `VaultBridge` — is format-agnostic and never names a concrete
/// adapter, so a new format adds one `VaultAdapter` conformer with no
/// change to the core (Vault import/export (c)).
///
/// Both write methods are `throws` because they touch the filesystem;
/// both are pure with respect to the substrate (an adapter never
/// reaches a `Drawer`, a verb, or a kit — that boundary belongs to
/// `DrawerMapping`).
public protocol VaultAdapter: Sendable {

    /// Read a vault directory into canonical notes.
    ///
    /// - Parameter vaultURL: the root directory of the vault.
    /// - Returns: one `NoteIR` per source note, in a deterministic
    ///   order (sorted by `stableSourceKey`) so repeated reads and the
    ///   round-trip equality `toIR(fromIR(x)) == x` are stable.
    func toIR(vaultURL: URL) throws -> [NoteIR]

    /// Write canonical notes back out to a vault directory, mirroring
    /// the folder tree carried in each note's wing/room frontmatter.
    ///
    /// - Parameters:
    ///   - notes: the notes to emit.
    ///   - vaultURL: the root directory to write under. Created if
    ///     absent. The adapter writes only inside this directory.
    func fromIR(_ notes: [NoteIR], to vaultURL: URL) throws

    /// Write canonical notes with optional per-item progress reporting.
    ///
    /// This is a protocol requirement (not merely an extension default) so
    /// that concrete adapters can override it for real per-item firing and
    /// the override is reached through a `VaultAdapter` existential.
    /// Conformers that do not support per-item progress do NOT need to
    /// implement this method — the default extension below delegates to
    /// `fromIR(_:to:)` and ignores the closure.
    ///
    /// - Parameters:
    ///   - notes: the notes to emit.
    ///   - vaultURL: the root directory to write under.
    ///   - progress: optional `VaultProgress` closure — called every 100
    ///     items and at the final item with `(processed, total)`.
    ///     Pass `nil` (the default) to suppress all progress callbacks.
    func fromIR(_ notes: [NoteIR], to vaultURL: URL, progress: VaultProgress?) throws
}

extension VaultAdapter {

    /// Default implementation: delegates to `fromIR(_:to:)` and ignores progress.
    /// Adapters that support per-item reporting provide their own implementation.
    public func fromIR(_ notes: [NoteIR], to vaultURL: URL, progress: VaultProgress?) throws {
        try fromIR(notes, to: vaultURL)
    }
}

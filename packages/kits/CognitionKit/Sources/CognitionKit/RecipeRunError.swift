// RecipeRunError.swift
//
// The typed wrapper that unifies a recipe-level guard failure (`RecipeError`)
// with a propagated substrate-operation failure (`SubstrateError`). This is
// the Swift mirror of the Rust `RecipeRunError` / `SubstrateError` hierarchy
// in `error.rs`.
//
// Force-mirror ruling (code-parity Phase-0, 2026-06-05): both ports must
// expose matching error TYPE surfaces. The Rust port carries:
//   - `SubstrateError { operation, detail }` — the typed substrate-fault arm
//   - `RecipeRunError { .recipe(RecipeError) | .substrate(SubstrateError) }`
//
// Swift previously propagated substrate faults through untyped `throws`. This
// file adds the mirror types so the public CognitionKit surface is
// type-identical across ports. `RecipeError` (the 6-case guard enum) is
// unchanged. The `Recipe.run()` protocol signature remains `async throws`
// for backward compatibility with the protocol abstraction; the concrete run
// bodies may throw `RecipeRunError` where a substrate arm is possible, and
// callers who need the typed distinction can catch against this enum.
//
// Description strings mirror the Rust `Display` implementations in `error.rs`
// byte-for-byte, satisfying COGNITIONKIT_SPEC § 6.

import Foundation

// MARK: - SubstrateError

/// A failure of a substrate operation behind the `RecipeSubstrate` seam
/// (derive / capture / benchmark / recall). Substrate-agnostic: a live
/// adapter maps the underlying GLK / estate error into `operation` + `detail`;
/// the deterministic test fake never errors.
///
/// This is the Swift mirror of the Rust `SubstrateError` struct in `error.rs`.
/// Rust's untyped `throws` used to absorb these; this type makes the arm
/// explicit and matchable.
public struct SubstrateError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The seam operation that failed (e.g. "derive_branch", "capture",
    /// "benchmark", "recall"). Matches the Rust `operation` field exactly.
    public let operation: String
    /// Textual cause from the underlying substrate error. Matches the Rust
    /// `detail` field exactly.
    public let detail: String

    /// Construct a substrate error from an operation name and any displayable
    /// underlying cause. Mirrors `SubstrateError::new` in `error.rs`.
    public init(operation: String, detail: String) {
        self.operation = operation
        self.detail = detail
    }

    /// Mirrors the Rust `Display` implementation:
    /// `"SubstrateError.{operation}: {detail}"`.
    public var description: String {
        "SubstrateError.\(operation): \(detail)"
    }
}

// MARK: - RecipeRunError

/// The result error of running a recipe: either a recipe-level `RecipeError`
/// (the closed, parity-gated guard set) or a propagated `SubstrateError`.
///
/// This is the Swift mirror of the Rust `RecipeRunError` enum in `error.rs`.
/// Swift's untyped `throws` used to absorb both arms; this type makes the
/// distinction explicit and matchable across ports.
///
/// Cases match the Rust variants exactly (Swift camelCase ↔ Rust PascalCase):
/// - `.recipe(RecipeError)`   — a recipe-level guard failure
/// - `.substrate(SubstrateError)` — a propagated substrate-operation failure
public enum RecipeRunError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A recipe-level guard failure (capability gate, duplicate plan, etc.).
    /// Mirrors the Rust `RecipeRunError::Recipe(RecipeError)` variant.
    case recipe(RecipeError)

    /// A propagated substrate-operation failure. Mirrors the Rust
    /// `RecipeRunError::Substrate(SubstrateError)` variant.
    case substrate(SubstrateError)

    /// Unwraps the `.recipe` arm if present; nil otherwise.
    public var recipeError: RecipeError? {
        if case .recipe(let e) = self { return e }
        return nil
    }

    /// Unwraps the `.substrate` arm if present; nil otherwise.
    public var substrateError: SubstrateError? {
        if case .substrate(let e) = self { return e }
        return nil
    }

    /// Mirrors the Rust `Display` implementation: delegates to the inner
    /// type's description. The prefix and case name do NOT appear here —
    /// the inner type's description already carries its identity prefix
    /// (`RecipeError.XYZ` or `SubstrateError.operation`).
    public var description: String {
        switch self {
        case .recipe(let e): return e.description
        case .substrate(let e): return e.description
        }
    }
}

// MARK: - Conversion helpers

extension RecipeRunError {
    /// Wrap a `RecipeError` in the `.recipe` arm. Mirrors the Rust
    /// `impl From<RecipeError> for RecipeRunError`.
    public init(_ e: RecipeError) {
        self = .recipe(e)
    }

    /// Wrap a `SubstrateError` in the `.substrate` arm. Mirrors the Rust
    /// `impl From<SubstrateError> for RecipeRunError`.
    public init(_ e: SubstrateError) {
        self = .substrate(e)
    }
}

extension RecipeError {
    /// Lift this `RecipeError` into a `RecipeRunError`. Convenience for
    /// call sites that throw through the `RecipeRunError` surface.
    public var asRunError: RecipeRunError { .recipe(self) }
}

// UtilityTierTests.swift
//
// PR-04 verification: the estate-status subject-debt counter on a mixed
// fixture, and the terse/verbose catalogue tiers.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Utility tier — subject-debt counter + catalogue tiers", .serialized)
struct UtilityTierTests {

    private func text(of result: JSONValue) -> String {
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(s)? = first["text"]
        else { return "" }
        return s
    }

    /// MXE-XU — every drawer-derived aggregate on this surface reads the
    /// sensitivity-filtered set, not the raw cluster-A set.
    ///
    /// The fixture holds one visible subject-bearing row plus two restricted
    /// rows — one carrying a subject, one not — filed into a wing of their
    /// own. Before the fix this reported `memories: 3 active (3 total)` and
    /// `subjects: 2/3 (1 missing)`: an ungranted caller learned that live rows
    /// were hidden from it, how many, and how many of those carried a subject.
    /// `wings:` was already filtered; it is the control that proves the fix
    /// closes the leak without over-reaching.
}

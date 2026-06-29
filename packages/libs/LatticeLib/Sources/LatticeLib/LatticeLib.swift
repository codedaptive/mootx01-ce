// LatticeLib.swift
//
// The LatticeLib module surface. The classification engine is FDC
// (Frame-Directed Classification): callers reach it through the FDC
// runtime (FDC.encodeAnchor) and the shared text primitives, both of
// which own and cache their pinned reference data internally. This
// enum also hosts the public `wordClass` text-classification APIs
// (extended in WordClassTagger.swift) and the module version.

import Foundation

/// The LatticeLib module surface.
public enum LatticeLib {

    /// The module version. Bumped in lockstep with the bundled FDC
    /// artifacts when new signatures ship.
    public static let version: String = "1.0.0"
}

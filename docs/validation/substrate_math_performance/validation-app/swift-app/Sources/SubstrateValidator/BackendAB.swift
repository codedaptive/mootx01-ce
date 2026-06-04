// BackendAB.swift — subsystem 2 (backend A/B) for the Swift app.
//
// Runs the shipping lib's kernel-dispatched ops under each AVAILABLE kernel
// backend (scalar / simd / bnns / metal) over deterministic inputs and asserts
// the results are byte-identical across backends — the four-way conformance
// invariant (every backend must match the scalar reference bit-for-bit) checked
// at runtime in the shipping binary. Swift carries the richer kernel set; the
// Rust app only has scalar/simd.
import Foundation
import Harness
import SubstrateTypes
import SubstrateKernel

enum BackendAB {
    static func run() -> Int {
        print("SubstrateValidator (Swift) — backend A/B (kernel-dispatched ops, byte-identical across backends)")
        print("hardware: \(Hardware.tag())\n")

        // Resolve the kernels actually available on this build. PortableKernel
        // .kernel(of:) falls back to scalar for an unavailable backend, so we keep
        // only kernels whose reported .kind matches what we asked for.
        let candidates: [KernelKind] = [.scalar, .simd, .bnns, .metal]
        var kernels: [(KernelKind, any SubstrateKernel)] = []
        for k in candidates {
            let kern = PortableKernel.kernel(of: k)
            if kern.kind == k { kernels.append((k, kern)) }
        }
        print("available backends: \(kernels.map { "\($0.0.rawValue)" }.joined(separator: ", "))\n")
        if kernels.count < 2 {
            print("only one backend available — nothing to A/B."); return 0
        }

        // Deterministic inputs (no vector decode needed; we test cross-backend
        // agreement, not the committed CRC — that's subsystem 1).
        var rng = SplitMix64(seed: 0x5A17_C0DE_F00D_1234)
        let fps = (0..<256).map { _ in
            Fingerprint256(block0: rng.next(), block1: rng.next(),
                           block2: rng.next(), block3: rng.next())
        }

        var anyFail = false
        anyFail = abOp("hammingDistance256", kernels) { kern in
            var e = CanonicalBinaryEncoder()
            for i in 1..<fps.count { e.writeU32(UInt32(kern.hammingDistance256(fps[0], fps[i]))) }
            return CRC32.compute(e.bytes)
        } || anyFail
        anyFail = abOp("hammingDistanceBatch", kernels) { kern in
            var e = CanonicalBinaryEncoder()
            for v in kern.hammingDistanceBatch(probe: fps[0], candidates: Array(fps[1...])) {
                e.writeU32(UInt32(v))
            }
            return CRC32.compute(e.bytes)
        } || anyFail
        anyFail = abOp("orReduce256", kernels) { kern in
            let r = kern.orReduce256(fps)
            var e = CanonicalBinaryEncoder()
            e.writeU64(r.block0); e.writeU64(r.block1); e.writeU64(r.block2); e.writeU64(r.block3)
            return CRC32.compute(e.bytes)
        } || anyFail
        anyFail = abOp("popcount64", kernels) { kern in
            var e = CanonicalBinaryEncoder()
            for fp in fps { e.writeU32(UInt32(kern.popcount64(fp.block0))) }
            return CRC32.compute(e.bytes)
        } || anyFail

        print(anyFail
            ? "\nbackend A/B: DISAGREEMENT — a backend diverges from the reference"
            : "\nbackend A/B: all backends byte-identical")
        return anyFail ? 1 : 0
    }

    /// Run `f` under every available kernel; print per-backend CRC + agreement.
    /// Returns true on disagreement.
    private static func abOp(_ name: String,
                             _ kernels: [(KernelKind, any SubstrateKernel)],
                             _ f: (any SubstrateKernel) -> UInt32) -> Bool {
        let results = kernels.map { ($0.0, f($0.1)) }
        let allEqual = results.allSatisfy { $0.1 == results[0].1 }
        let cells = results.map { "\($0.0.rawValue)=\(HexCoding.crc32($0.1))" }.joined(separator: "  ")
        print("\(name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(cells)  \(allEqual ? "agree" : "DISAGREE")")
        return !allEqual
    }
}

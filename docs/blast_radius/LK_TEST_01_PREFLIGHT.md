# Smythe Pre-flight — LK-TEST-01

Mission: `docs/missions/inflight/MISSION_LK_TEST_01.md`
Stream: lk · Branch: `stream/lk-locuskit-test-finish` · Baseline: `16c0579`
Spawned as a separate `smythe` agent (agentId a992103b87f15abf6).

## Status
**GREEN**

## Status details
- Blast radius: verified. Exactly 3 files import XCTest — no more, no fewer.
  41 files import Testing. Total 45 test files in the directory (incl. helper
  TestStorage.swift). Mission's "24 methods" claim confirmed: KGFactTests 18 +
  SealedBitTests 4 + LocusKitVocabularyTests 2 = 24.
- Prior art: none conflicting. `stream/lk-locuskit-test-finish` is zero commits
  ahead of main. No other active stream touches these 3 files.
- Environment: clean. Branch correct.
- Dependencies: satisfied. Package.swift already wired — no explicit `Testing`
  product needed (bundled Swift 6 toolchain); 41 working suites prove it
  resolves. Must not be touched.

## Blockers
None.

## Reference style — confirmed from 41 existing suites

```swift
import Testing
// (other imports preserved as-is)
@testable import LocusKit

@Suite("SuiteName")
struct SuiteName {
    @Test
    func testName() {
        #expect(...)
    }
}
```

- `throws` tests: keep `throws` on the `@Test func`. `try` calls unchanged.
- `guard-else` (vocabulary test): `guard case .success = ... else {
  Issue.record("message"); return }`. Plain string form is correct;
  `Issue.record` is well-established in the existing suites.

## Bilby's stated approach (captured)
Mechanical framework conversion, three files in isolation, assertions verbatim;
`XCTFail` in the vocabulary guard-else → `Issue.record(...); return`; the one
`throws` test in KGFactTests keeps `throws`. No production/Rust/Package.swift
change. Accepted — every element has a clean precedent in the 41 existing suites.

## Decision needed
None.

**GREEN. Terrain clear. Proceed.**

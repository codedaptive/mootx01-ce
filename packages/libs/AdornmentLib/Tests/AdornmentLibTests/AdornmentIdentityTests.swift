#if MOOTX01_MINERS
import Testing
@testable import AdornmentLib

/// Tests for AdornmentMinterDescriptor and StoredAdornment identity values
/// (ADORNMENTLIB_SPEC §4, ADORNMENTLIB_INTERFACE 0.3.0).
///
/// Golden pins:
///   - Descriptor round-trips through equality with identical field values.
///   - Stored adornment holds exactly (drawerID, minterID, text).
///   - Descriptors differing only in isActive are not equal.
///   - Descriptors differing only in parameters are not equal.
@Suite("AdornmentIdentityTests")
struct AdornmentIdentityTests {

    // MARK: - AdornmentMinterDescriptor

    @Test("descriptor equality — same fields produce equal values")
    func descriptorEquality() {
        let a = AdornmentMinterDescriptor(
            id: "minter-001",
            name: "Apple Gen1",
            family: "apple",
            modelID: "apple-gen1",
            modelVersion: "2026-07",
            promptDigest: "abc123def456",
            parameters: ["temperature": "0.7", "top_p": "0.9"],
            isActive: true
        )
        let b = AdornmentMinterDescriptor(
            id: "minter-001",
            name: "Apple Gen1",
            family: "apple",
            modelID: "apple-gen1",
            modelVersion: "2026-07",
            promptDigest: "abc123def456",
            parameters: ["temperature": "0.7", "top_p": "0.9"],
            isActive: true
        )
        #expect(a == b, "descriptors with identical fields must be equal")
    }

    @Test("descriptor inequality — different isActive")
    func descriptorInequalityActiveFlag() {
        let active = AdornmentMinterDescriptor(
            id: "minter-001",
            name: "Apple Gen1",
            family: "apple",
            modelID: "apple-gen1",
            modelVersion: "2026-07",
            promptDigest: "abc123",
            parameters: [:],
            isActive: true
        )
        let inactive = AdornmentMinterDescriptor(
            id: "minter-001",
            name: "Apple Gen1",
            family: "apple",
            modelID: "apple-gen1",
            modelVersion: "2026-07",
            promptDigest: "abc123",
            parameters: [:],
            isActive: false
        )
        #expect(active != inactive, "descriptors differing only in isActive must not be equal")
    }

    @Test("descriptor inequality — different parameters")
    func descriptorInequalityParameters() {
        let d1 = AdornmentMinterDescriptor(
            id: "m1", name: "M", family: "apple",
            modelID: "model-a", modelVersion: "v1", promptDigest: "digest",
            parameters: ["temperature": "0.7"], isActive: true
        )
        let d2 = AdornmentMinterDescriptor(
            id: "m1", name: "M", family: "apple",
            modelID: "model-a", modelVersion: "v1", promptDigest: "digest",
            parameters: ["temperature": "0.9"], isActive: true
        )
        #expect(d1 != d2, "descriptors differing in parameters must not be equal")
    }

    @Test("descriptor fields are accessible")
    func descriptorFieldAccess() {
        let descriptor = AdornmentMinterDescriptor(
            id: "minter-xyz",
            name: "Non-Apple Gen2",
            family: "candle",
            modelID: "candle-gen2",
            modelVersion: "v2.1",
            promptDigest: "deadbeef",
            parameters: ["seed": "42", "top_k": "50"],
            isActive: false
        )
        #expect(descriptor.id == "minter-xyz")
        #expect(descriptor.name == "Non-Apple Gen2")
        #expect(descriptor.family == "candle")
        #expect(descriptor.modelID == "candle-gen2")
        #expect(descriptor.modelVersion == "v2.1")
        #expect(descriptor.promptDigest == "deadbeef")
        #expect(descriptor.parameters["seed"] == "42")
        #expect(descriptor.parameters["top_k"] == "50")
        #expect(descriptor.isActive == false)
    }

    @Test("descriptor with empty parameters is valid")
    func descriptorEmptyParameters() {
        let d = AdornmentMinterDescriptor(
            id: "m0", name: "Min", family: "apple",
            modelID: "model", modelVersion: "v0", promptDigest: "00",
            parameters: [:], isActive: true
        )
        #expect(d.parameters.isEmpty)
        #expect(d.isActive == true)
    }

    // MARK: - StoredAdornment

    @Test("stored adornment fields are accessible")
    func storedAdornmentFields() {
        let sa = StoredAdornment(
            drawerID: "drawer-abc-123",
            minterID: "minter-001",
            text: "Stated facts about the thing; key claim here"
        )
        #expect(sa.drawerID == "drawer-abc-123")
        #expect(sa.minterID == "minter-001")
        #expect(sa.text == "Stated facts about the thing; key claim here")
    }

    @Test("stored adornment equality — same fields")
    func storedAdornmentEquality() {
        let a = StoredAdornment(drawerID: "d1", minterID: "m1", text: "blob; data here")
        let b = StoredAdornment(drawerID: "d1", minterID: "m1", text: "blob; data here")
        #expect(a == b)
    }

    @Test("stored adornment inequality — different text")
    func storedAdornmentInequalityText() {
        let a = StoredAdornment(drawerID: "d1", minterID: "m1", text: "version one")
        let b = StoredAdornment(drawerID: "d1", minterID: "m1", text: "version two")
        #expect(a != b, "adornments with different text must not be equal")
    }

    @Test("stored adornment inequality — different minterID")
    func storedAdornmentInequalityMinter() {
        let a = StoredAdornment(drawerID: "d1", minterID: "minter-a", text: "some text")
        let b = StoredAdornment(drawerID: "d1", minterID: "minter-b", text: "some text")
        #expect(a != b, "adornments from different minters must not be equal even with same text")
    }

    // MARK: - Cross-type composability

    @Test("descriptor and stored adornment link via id/minterID fields")
    func descriptorAndAdornmentLinkage() {
        let minter = AdornmentMinterDescriptor(
            id: "minter-alpha",
            name: "Alpha Minter",
            family: "apple",
            modelID: "apple-gen3",
            modelVersion: "2026-08",
            promptDigest: "cafebabe",
            parameters: ["temperature": "0.5"],
            isActive: true
        )
        let adornment = StoredAdornment(
            drawerID: "drawer-001",
            minterID: minter.id,  // explicitly links to the descriptor
            text: "Apple Cupertino California; Steve Jobs founded 1976"
        )
        #expect(adornment.minterID == minter.id, "adornment.minterID must equal descriptor.id")
    }
}
#endif // MOOTX01_MINERS: the library compiles to nothing with the switch off, so do its tests.

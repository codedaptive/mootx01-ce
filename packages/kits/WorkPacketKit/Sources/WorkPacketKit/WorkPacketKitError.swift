// WorkPacketKitError — kit-local errors.
//
// All errors thrown by WorkPacketKit carry a message string with enough
// context for the caller to log without wrapping. No LocusKit internals
// surface through these cases.

public enum WorkPacketKitError: Error, Sendable, Equatable {

    /// JSON encoding of a WorkPacket to a UTF-8 string failed.
    case encodingFailure(String)

    /// JSON decoding of a drawer's content to a WorkPacket failed.
    case decodingFailure(String)
}

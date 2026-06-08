import Testing
import AriaResident

/// The resident env parsers were untestable when inline in the aria-mcp
/// executable; moving them into the AriaResident library puts them
/// under test. Each takes an injected env dict — defaults, override, invalid
/// fallback, and the 1 h clamp on the tick/poll knobs.
@Suite("AriaResident env parsers")
struct AriaResidentEnvTests {

    @Test func httpMaxBodyBytesDefaultOverrideInvalid() {
        #expect(AriaResident.httpMaxBodyBytes(env: [:]) == 4 * 1024 * 1024)
        #expect(AriaResident.httpMaxBodyBytes(env: ["MOOTX01_HTTP_MAX_BODY_BYTES": "1048576"]) == 1_048_576)
        #expect(AriaResident.httpMaxBodyBytes(env: ["MOOTX01_HTTP_MAX_BODY_BYTES": "nope"]) == 4 * 1024 * 1024)
        #expect(AriaResident.httpMaxBodyBytes(env: ["MOOTX01_HTTP_MAX_BODY_BYTES": "0"]) == 4 * 1024 * 1024)
    }

    @Test func brainTickMsDefaultOverrideClampInvalid() {
        #expect(AriaResident.brainTickMs(env: [:]) == 5000)
        #expect(AriaResident.brainTickMs(env: ["MOOTX01_BRAIN_TICK_MS": "1000"]) == 1000)
        #expect(AriaResident.brainTickMs(env: ["MOOTX01_BRAIN_TICK_MS": "999999999"]) == 3_600_000)  // clamp 1h
        #expect(AriaResident.brainTickMs(env: ["MOOTX01_BRAIN_TICK_MS": "-5"]) == 5000)
    }

    @Test func monitoringPollMsDefaultOverrideClampInvalid() {
        #expect(AriaResident.monitoringPollMs(env: [:]) == 5000)
        #expect(AriaResident.monitoringPollMs(env: ["MOOTX01_MONITORING_POLL_MS": "2000"]) == 2000)
        #expect(AriaResident.monitoringPollMs(env: ["MOOTX01_MONITORING_POLL_MS": "999999999"]) == 3_600_000)  // clamp 1h
        #expect(AriaResident.monitoringPollMs(env: ["MOOTX01_MONITORING_POLL_MS": "0"]) == 5000)
    }
}

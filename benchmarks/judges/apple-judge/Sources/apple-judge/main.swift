// apple-judge — judge contract: prompt on stdin, reply on stdout, exit 0.
//
// Uses Apple's bundled on-device model via FoundationModels (macOS 26+;
// the OS ships the weights — nothing to download, no server, no key).
// Judge identity for run records: "apple-foundationmodels" plus the
// macOS build the run executed on (sw_vers), because the bundled model
// revs with the OS, not with this tool.
//
// Exit codes: 0 success; 2 model unavailable (harness records a judge
// failure for the question rather than grading error text); 1 other.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

let data = FileHandle.standardInput.readDataToEndOfFile()
guard let prompt = String(data: data, encoding: .utf8),
      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    FileHandle.standardError.write(Data("apple-judge: empty prompt on stdin\n".utf8))
    exit(1)
}

#if canImport(FoundationModels)
guard #available(macOS 26.0, *) else {
    FileHandle.standardError.write(Data("apple-judge: requires macOS 26+\n".utf8))
    exit(2)
}
// APPLE_JUDGE_PCC=1 selects the Private Cloud Compute server model
// (WWDC26-319): same API, larger context, reasoning-capable — but it
// requires internet, an Apple Intelligence device, AND the app tier
// granted via the developer-site application. Until that grant exists
// this path reports unavailable (exit 2), never a wrong grade.
let usePCC = ProcessInfo.processInfo.environment["APPLE_JUDGE_PCC"] == "1"
if usePCC {
    // Deliberately DARK until the PCC app tier is granted: a judge must
    // never silently substitute one model for another (judge identity is
    // part of the measurement), so there is no fallback here — the leg
    // records a judge failure instead. Wiring the real
    // PrivateCloudComputeLanguageModel session is one commit once the
    // developer-site application is approved.
    FileHandle.standardError.write(Data(
        "apple-judge: PCC tier requested but not yet granted for this app — apply on the developer website\n".utf8))
    exit(2)
}
// Availability is a runtime property (model can be disabled, not yet
// downloaded, or unsupported hardware) — probe before responding.
guard SystemLanguageModel.default.availability == .available else {
    FileHandle.standardError.write(Data(
        "apple-judge: bundled model unavailable on this system\n".utf8))
    exit(2)
}
// Context guard: the on-device model is small-context (4K per
// WWDC26-319; read the real bound at runtime). A judge prompt past the
// bound must FAIL VISIBLY (exit 2 → recorded judge failure), never be
// silently truncated into a plausible-looking wrong grade. The ~4-chars
// -per-token floor deliberately under-counts so the guard only fires
// when overflow is certain.
let contextTokens = SystemLanguageModel.default.contextSize
if prompt.utf8.count / 4 > contextTokens {
    let msg = "apple-judge: prompt (~\(prompt.utf8.count / 4) tokens) exceeds the "
        + "model context (\(contextTokens)) — lower --judge-hydration-depth\n"
    FileHandle.standardError.write(Data(msg.utf8))
    exit(2)
}
let semaphore = DispatchSemaphore(value: 0)
// The judge must be as deterministic as the API allows: greedy sampling.
let options = GenerationOptions(sampling: .greedy)
// Task.detached, NOT Task {}: top-level code is MainActor-isolated in
// Swift 6, and the semaphore below blocks the main thread — an attached
// task would schedule onto the blocked actor and deadlock before the
// first token.
Task.detached {
    do {
        let session = LanguageModelSession(
            instructions: "You are a strict grader. Answer with exactly what the prompt asks for and nothing else.")
        let reply = try await session.respond(to: prompt, options: options).content
        FileHandle.standardOutput.write(Data(
            reply.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("apple-judge: \(error)\n".utf8))
        exit(1)
    }
}
semaphore.wait()
#else
FileHandle.standardError.write(Data(
    "apple-judge: built without FoundationModels (non-Apple toolchain)\n".utf8))
exit(2)
#endif

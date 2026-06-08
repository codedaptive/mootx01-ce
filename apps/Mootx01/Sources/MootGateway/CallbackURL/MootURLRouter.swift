import Foundation
import AriaMCP   // JSONValue

// MARK: - MootURLRouter  (A5 — x-callback-url)
//
// Parses `mootx01://x-callback-url/<verb>?…&x-success=…&x-error=…` and routes
// the verb through the in-process ARIA tool surface, then constructs the
// x-callback return URL the calling app expects. This is a compiling,
// unit-testable SHELL: the only thing it lacks to be real is URL-scheme
// registration, which needs an app bundle's Info.plist CFBundleURLTypes —
// the router logic itself is complete.
//
// Mapping (LEXICON_TO_APPLE_MAPPING.md, x-callback column): the verb path
// segment selects the moot_* tool; query items become tool arguments;
// x-success / x-error carry the caller's return URLs per the x-callback-url
// 1.0 spec (https://x-callback-url.com/specifications/).
//
// Security: two hardening layers are active here.
//
// 1. Verb allowlist: only non-destructive verbs (capture, recall, reanchor)
//    are permitted over x-callback-url. Destructive verbs (expunge, withdraw,
//    mutate) are rejected with .notHandled. A crafted URL containing a
//    destructive verb could otherwise drive an irreversible erase from any
//    app that can compose a URL — the allowlist removes that surface.
//
// 2. Callback-scheme allowlist: the host MUST pass the set of URL schemes
//    it considers safe when constructing this router. The router only builds
//    a return URL if the x-success/x-error callback's scheme is in that set.
//    An empty set (the default) means returnURL is always nil and the host
//    decides what to open — this prevents an open-redirect where a malicious
//    caller supplies x-success=https://attacker.example/… and the app opens
//    an arbitrary URL on their behalf.

public struct MootURLRouter: Sendable {

    public static let scheme = "mootx01"
    public static let host = "x-callback-url"

    // Non-destructive verbs that x-callback-url is permitted to invoke.
    // Destructive verbs (expunge, withdraw, mutate) are not in this list:
    // a crafted URL must not be able to drive an irreversible erase.
    private static let allowedVerbs: Set<String> = ["capture", "recall", "reanchor"]

    // URL schemes the router may use when constructing a return URL.
    // The host configures this at init time; an empty set means the router
    // never auto-opens a callback URL (the host decides). Any x-success /
    // x-error whose scheme is not in this set is silently dropped from
    // returnURL to prevent open-redirect abuse.
    private let permittedCallbackSchemes: Set<String>

    /// - Parameter permittedCallbackSchemes: URL schemes the router may use
    ///   when building x-success / x-error return URLs. Pass an empty set
    ///   (the default) to disable automatic return-URL construction; the host
    ///   is then responsible for opening any callback. Pass e.g. `["myapp"]`
    ///   to allow `myapp://…` callbacks. Schemes not in this set are stripped
    ///   from `returnURL` in the Outcome.
    public init(permittedCallbackSchemes: Set<String> = []) {
        self.permittedCallbackSchemes = permittedCallbackSchemes
    }

    /// The outcome of routing one inbound URL.
    public enum Outcome: Sendable, Equatable {
        /// A return URL to open (the x-success or x-error callback with the
        /// result appended), or nil if the caller supplied no callback or the
        /// callback scheme was not in the permitted-schemes allowlist.
        case routed(returnURL: URL?, resultText: String, isError: Bool)
        /// The URL did not match the gateway's scheme/host/verb grammar, or
        /// the verb was not in the non-destructive allowlist.
        case notHandled(reason: String)
    }

    /// Route one inbound URL. Pure of side effects except the substrate call;
    /// the host (an app's onOpenURL) decides whether to open `returnURL`.
    public func route(_ url: URL, using bridge: MootBridge) async -> Outcome {
        guard url.scheme == Self.scheme else {
            return .notHandled(reason: "scheme is not \(Self.scheme)://")
        }
        guard url.host == Self.host else {
            return .notHandled(reason: "host is not \(Self.host)")
        }
        // The verb is the first path segment: /capture, /recall, …
        let verb = url.path.split(separator: "/").first.map(String.init) ?? ""

        // Verb allowlist: reject destructive verbs before touching the substrate.
        // Only non-destructive verbs (capture, recall, reanchor) may be driven
        // via x-callback-url; expunge/withdraw/mutate are blocked here.
        guard Self.allowedVerbs.contains(verb) else {
            return .notHandled(reason: "verb not permitted over x-callback-url: \(verb)")
        }

        guard let row = LexiconMap.verbs.first(where: { $0.xCallbackPath == verb }),
              let tool = row.mootTool else {
            return .notHandled(reason: "unknown or non-invokable verb: \(verb)")
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        let xSuccess = items.first(where: { $0.name == "x-success" })?.value
        let xError = items.first(where: { $0.name == "x-error" })?.value

        // Every non-x-callback query item becomes a string tool argument. The
        // tool's own decoders validate/convert (e.g. sensitivity strings).
        var arguments: [String: JSONValue] = [:]
        for item in items where !item.name.hasPrefix("x-") {
            if let value = item.value { arguments[item.name] = .string(value) }
        }

        let call = await bridge.callTool(tool, arguments: arguments)
        let callbackBase = call.isError ? xError : xSuccess

        // Callback-scheme gate: only build a return URL if the callback's
        // scheme is in the host-configured allowlist. This prevents an
        // open-redirect where a malicious caller supplies x-success pointing
        // at an arbitrary URL and the app opens it on their behalf.
        let returnURL = callbackBase.flatMap { base -> URL? in
            guard let scheme = URLComponents(string: base)?.scheme,
                  permittedCallbackSchemes.contains(scheme) else { return nil }
            return Self.appendResult(to: base, result: call.text)
        }
        return .routed(returnURL: returnURL, resultText: call.text, isError: call.isError)
    }

    /// Append the result to a caller-supplied x-callback return URL as a
    /// percent-encoded `result` query item, per the x-callback-url spec.
    private static func appendResult(to base: String, result: String) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "result", value: result))
        components.queryItems = items
        return components.url
    }
}

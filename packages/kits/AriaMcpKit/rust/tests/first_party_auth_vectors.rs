//! Independent Rust verification of the first-party authenticated-wire golden
//! vectors.
//!
//! WHAT THIS IS. `docs/reference/vectors/ARIA_MCP_FIRST_PARTY_AUTH_V1.json` is
//! the single language-neutral source of truth for the MOOTx01 first-party wire.
//! Swift emits it from `FirstPartyAuthProtocol.swift`. This test recomputes
//! every published value from the field inputs and asserts byte equality. If the
//! two ports disagree on a single byte, the wire is not language-neutral.
//!
//! WHAT THIS IS NOT. This is a **vector verifier**, not an implementation. The
//! Rust port does not host a first-party session server, does not expose an
//! authenticated-first-party runtime capability, and does not advertise one.
//! Kong binding decision 5 is explicit: Rust must pass the shared vectors
//! *before* it may implement or advertise the protocol, and a partial
//! implementation is worse than none. Everything below therefore lives in the
//! test target and nothing is re-exported from `src/`.
//!
//! WHY THE PRIMITIVES ARE WRITTEN OUT BY HAND. The crate carries `sha2` as a
//! direct dependency but no `hmac` or `hkdf` crate, and MACD-2b may not add
//! dependencies or touch `Cargo.toml`/`Cargo.lock`. RFC 2104 and RFC 5869 are
//! implemented here over `sha2` alone. That constraint is a feature for this
//! particular test: a hand-written HMAC that agrees with CryptoKit's is
//! meaningfully independent evidence, where two calls into the same underlying
//! BoringSSL would not be.

use serde_json::Value;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::PathBuf;

// ---------------------------------------------------------------------------
// RFC 2104 — HMAC-SHA256
// ---------------------------------------------------------------------------

const SHA256_BLOCK_BYTES: usize = 64;

/// HMAC-SHA256 per RFC 2104.
///
/// A key longer than the block size is hashed first; a shorter one is
/// zero-padded to the block. `ipad`/`opad` are the RFC's 0x36/0x5c constants.
fn hmac_sha256(key: &[u8], message: &[u8]) -> Vec<u8> {
    let mut block = [0u8; SHA256_BLOCK_BYTES];
    if key.len() > SHA256_BLOCK_BYTES {
        let digest = Sha256::digest(key);
        block[..digest.len()].copy_from_slice(&digest);
    } else {
        block[..key.len()].copy_from_slice(key);
    }

    let mut inner_pad = [0u8; SHA256_BLOCK_BYTES];
    let mut outer_pad = [0u8; SHA256_BLOCK_BYTES];
    for i in 0..SHA256_BLOCK_BYTES {
        inner_pad[i] = block[i] ^ 0x36;
        outer_pad[i] = block[i] ^ 0x5c;
    }

    let mut inner = Sha256::new();
    inner.update(inner_pad);
    inner.update(message);
    let inner_digest = inner.finalize();

    let mut outer = Sha256::new();
    outer.update(outer_pad);
    outer.update(inner_digest);
    outer.finalize().to_vec()
}

// ---------------------------------------------------------------------------
// RFC 5869 — HKDF-SHA256
// ---------------------------------------------------------------------------

/// HKDF-SHA256 extract-then-expand per RFC 5869 §2.2 and §2.3.
///
/// The salt is always passed explicitly by every caller in this protocol; an
/// "omitted" salt is spelled as 32 zero octets at the call site rather than
/// defaulted here, so the vector file records the value actually used.
fn hkdf_sha256(ikm: &[u8], salt: &[u8], info: &[u8], output_len: usize) -> Vec<u8> {
    // Extract.
    let prk = hmac_sha256(salt, ikm);

    // Expand.
    let mut output = Vec::with_capacity(output_len);
    let mut previous_block: Vec<u8> = Vec::new();
    let mut counter: u8 = 1;
    while output.len() < output_len {
        let mut message = previous_block.clone();
        message.extend_from_slice(info);
        message.push(counter);
        previous_block = hmac_sha256(&prk, &message);
        output.extend_from_slice(&previous_block);
        counter += 1;
    }
    output.truncate(output_len);
    output
}

// ---------------------------------------------------------------------------
// The canonical encoder
// ---------------------------------------------------------------------------

/// Length-prefixed, fixed-order, big-endian canonical encoder.
///
/// Mirrors `CanonicalEncoder` in `FirstPartyAuthProtocol.swift` exactly. It is
/// reimplemented rather than shared because a shared encoder would make the
/// cross-port comparison circular.
#[derive(Default)]
struct CanonicalEncoder {
    bytes: Vec<u8>,
}

impl CanonicalEncoder {
    fn new() -> Self {
        Self { bytes: Vec::new() }
    }

    /// UInt32 big-endian length followed by the bytes.
    fn append_bytes(&mut self, value: &[u8]) {
        self.append_u32(value.len() as u32);
        self.bytes.extend_from_slice(value);
    }

    /// UTF-8 bytes, length-prefixed.
    fn append_string(&mut self, value: &str) {
        self.append_bytes(value.as_bytes());
    }

    fn append_u16(&mut self, value: u16) {
        self.bytes.extend_from_slice(&value.to_be_bytes());
    }

    fn append_u32(&mut self, value: u32) {
        self.bytes.extend_from_slice(&value.to_be_bytes());
    }

    fn append_u64(&mut self, value: u64) {
        self.bytes.extend_from_slice(&value.to_be_bytes());
    }

    /// The 16 RFC 4122 bytes, never the string form.
    fn append_uuid(&mut self, value: &str) {
        self.bytes.extend_from_slice(&parse_uuid(value));
    }

    /// Sorted by wire spelling, counted, then each entry length-prefixed — so
    /// the encoding cannot depend on the order a set happened to iterate in.
    fn append_capabilities(&mut self, values: &[String]) {
        let mut sorted: Vec<&String> = values.iter().collect();
        sorted.sort();
        self.append_u32(sorted.len() as u32);
        for value in sorted {
            self.append_string(value);
        }
    }
}

/// Parse a hyphenated RFC 4122 UUID string into its 16 bytes.
fn parse_uuid(value: &str) -> [u8; 16] {
    let hex: String = value.chars().filter(|c| *c != '-').collect();
    assert_eq!(hex.len(), 32, "UUID must be 32 hex digits: {value}");
    let bytes = decode_hex(&hex);
    let mut out = [0u8; 16];
    out.copy_from_slice(&bytes);
    out
}

fn decode_hex(value: &str) -> Vec<u8> {
    assert!(value.len() % 2 == 0, "hex string must have even length");
    (0..value.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&value[i..i + 2], 16).expect("valid hex"))
        .collect()
}

fn encode_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn sha256(bytes: &[u8]) -> Vec<u8> {
    Sha256::digest(bytes).to_vec()
}

/// base64url without padding (RFC 4648 §5), for the header-form vectors.
fn base64url_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;
        let quantum = chunk.len();
        out.push(ALPHABET[((triple >> 18) & 0x3F) as usize] as char);
        out.push(ALPHABET[((triple >> 12) & 0x3F) as usize] as char);
        if quantum > 1 {
            out.push(ALPHABET[((triple >> 6) & 0x3F) as usize] as char);
        }
        if quantum > 2 {
            out.push(ALPHABET[(triple & 0x3F) as usize] as char);
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Domain strings — must match FirstPartyAuthProtocol.swift exactly
// ---------------------------------------------------------------------------

const DESCRIPTOR_DOMAIN: &str = "MOOTX01-DESCRIPTOR-v1";
const SESSION_DOMAIN: &str = "MOOTX01-DAEMON-SESSION-v1";
const AUTH_DOMAIN: &str = "MOOTX01-AUTH-v1";
const SERVER_PROOF_DOMAIN: &str = "MOOTX01-SERVER-PROOF-v1";
const CLIENT_PROOF_DOMAIN: &str = "MOOTX01-CLIENT-PROOF-v1";
const SESSION_KEY_DOMAIN: &str = "MOOTX01-REQUEST-SESSION-v1";
const ESTABLISHED_DOMAIN: &str = "MOOTX01-ESTABLISHED-v1";
const REQUEST_DOMAIN: &str = "MOOTX01-REQUEST-v1";
const RESPONSE_DOMAIN: &str = "MOOTX01-RESPONSE-v1";

/// Prefix a body with a canonically-encoded domain string.
fn domain_prefixed(domain: &str, body: &[u8]) -> Vec<u8> {
    let mut encoder = CanonicalEncoder::new();
    encoder.append_string(domain);
    let mut out = encoder.bytes;
    out.extend_from_slice(body);
    out
}

// ---------------------------------------------------------------------------
// Vector file
// ---------------------------------------------------------------------------

fn load_vectors() -> Value {
    // CARGO_MANIFEST_DIR is packages/kits/AriaMcpKit/rust; the repository root
    // is four levels above it.
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for _ in 0..4 {
        path.pop();
    }
    path.push("docs/reference/vectors/ARIA_MCP_FIRST_PARTY_AUTH_V1.json");
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read golden vectors at {}: {e}", path.display()));
    serde_json::from_str(&text).expect("golden vectors are valid JSON")
}

fn string_field<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key]
        .as_str()
        .unwrap_or_else(|| panic!("missing string field {key}"))
}

fn u64_field(value: &Value, key: &str) -> u64 {
    value[key]
        .as_u64()
        .unwrap_or_else(|| panic!("missing u64 field {key}"))
}

fn bytes_field(value: &Value, key: &str) -> Vec<u8> {
    decode_hex(string_field(value, key))
}

/// Rebuild the descriptor MAC input from the descriptor's declared fields.
fn descriptor_mac_input(descriptor: &Value) -> Vec<u8> {
    let capabilities: Vec<String> = descriptor["capabilities"]
        .as_array()
        .expect("capabilities array")
        .iter()
        .map(|c| c.as_str().expect("capability string").to_string())
        .collect();

    let mut encoder = CanonicalEncoder::new();
    encoder.append_string(DESCRIPTOR_DOMAIN);
    encoder.append_u64(u64_field(descriptor, "schemaVersion"));
    encoder.append_string(string_field(descriptor, "providerIdentifier"));
    encoder.append_string(string_field(descriptor, "serviceIdentifier"));
    encoder.append_string(string_field(descriptor, "endpoint"));
    encoder.append_string(string_field(descriptor, "authProtocol"));
    encoder.append_string(string_field(descriptor, "authKeyIdentifier"));
    encoder.append_u64(u64_field(descriptor, "publishedAt"));
    encoder.append_uuid(string_field(descriptor, "instanceIdentifier"));
    encoder.append_uuid(string_field(descriptor, "estateIdentifier"));
    encoder.append_string(string_field(descriptor, "binaryVersion"));
    encoder.append_u64(u64_field(descriptor, "contractRevision"));
    encoder.append_string(string_field(descriptor, "mcpProtocolVersion"));
    encoder.append_capabilities(&capabilities);
    encoder.append_u64(u64_field(descriptor, "credentialGeneration"));
    encoder.append_u64(u64_field(descriptor, "descriptorGeneration"));
    encoder.bytes
}

/// The full canonical descriptor: the MAC input and the MAC, each length-prefixed.
fn descriptor_canonical_bytes(mac_input: &[u8], mac: &[u8]) -> Vec<u8> {
    let mut encoder = CanonicalEncoder::new();
    encoder.append_bytes(mac_input);
    encoder.append_bytes(mac);
    encoder.bytes
}

#[allow(clippy::too_many_arguments)]
fn session_transcript(descriptor: &Value, session: &Value, digest: &[u8]) -> Vec<u8> {
    let mut encoder = CanonicalEncoder::new();
    encoder.append_string(SESSION_DOMAIN); //  1
    encoder.append_bytes(digest); //  2
    encoder.append_string(string_field(descriptor, "providerIdentifier")); //  3
    encoder.append_string(string_field(descriptor, "serviceIdentifier")); //  4
    encoder.append_string(string_field(descriptor, "endpoint")); //  5
    encoder.append_uuid(string_field(descriptor, "instanceIdentifier")); //  6
    encoder.append_uuid(string_field(descriptor, "estateIdentifier")); //  7
    encoder.append_string(string_field(descriptor, "binaryVersion")); //  8
    encoder.append_u64(u64_field(descriptor, "schemaVersion")); //  9
    encoder.append_u64(u64_field(descriptor, "contractRevision")); // 10
    encoder.append_string(string_field(descriptor, "mcpProtocolVersion")); // 11
    encoder.append_u64(u64_field(descriptor, "credentialGeneration")); // 12
    encoder.append_u64(u64_field(descriptor, "descriptorGeneration")); // 13
    encoder.append_bytes(&bytes_field(session, "clientNonceHex")); // 14
    encoder.append_bytes(&bytes_field(session, "serverNonceHex")); // 15
    encoder.append_bytes(&bytes_field(session, "sessionIdentifierHex")); // 16
    encoder.append_u64(u64_field(session, "issuedAt")); // 17
    encoder.append_u64(u64_field(session, "idleExpiry")); // 18
    encoder.append_u64(u64_field(session, "absoluteExpiry")); // 19
    encoder.bytes
}

fn request_mac(
    session_key: &[u8],
    session_id: &[u8],
    sequence: u64,
    method: &str,
    path: &str,
    content_type: &str,
    body: &[u8],
) -> Vec<u8> {
    let mut encoder = CanonicalEncoder::new();
    encoder.append_string(REQUEST_DOMAIN);
    encoder.append_bytes(session_id);
    encoder.append_u64(sequence);
    encoder.append_string(method);
    encoder.append_string(path);
    encoder.append_string(content_type);
    encoder.append_bytes(&sha256(body));
    hmac_sha256(session_key, &encoder.bytes)
}

fn response_mac(
    session_key: &[u8],
    session_id: &[u8],
    sequence: u64,
    status: u16,
    content_type: &str,
    body: &[u8],
) -> Vec<u8> {
    let mut encoder = CanonicalEncoder::new();
    encoder.append_string(RESPONSE_DOMAIN);
    encoder.append_bytes(session_id);
    encoder.append_u64(sequence);
    encoder.append_u16(status);
    encoder.append_string(content_type);
    encoder.append_bytes(&sha256(body));
    hmac_sha256(session_key, &encoder.bytes)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// RFC 2104 test case 2, so a failure in the hand-written HMAC is diagnosed
/// here rather than as a mystifying vector mismatch further down.
#[test]
fn hmac_matches_rfc2104_test_case_2() {
    let mac = hmac_sha256(b"Jefe", b"what do ya want for nothing?");
    assert_eq!(
        encode_hex(&mac),
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
    );
}

/// RFC 5869 test case 1, same reasoning as above.
#[test]
fn hkdf_matches_rfc5869_test_case_1() {
    let ikm = [0x0bu8; 22];
    let salt: Vec<u8> = (0x00u8..=0x0c).collect();
    let info: Vec<u8> = (0xf0u8..=0xf9).collect();
    let okm = hkdf_sha256(&ikm, &salt, &info, 42);
    assert_eq!(
        encode_hex(&okm),
        "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
    );
}

/// The descriptor key, MAC, canonical bytes, and digest all reproduce.
#[test]
fn descriptor_vectors_reproduce() {
    let vectors = load_vectors();
    let root = bytes_field(&vectors, "installationRootHex");
    let descriptor = &vectors["descriptor"];

    let descriptor_key = hkdf_sha256(&root, &[0u8; 32], DESCRIPTOR_DOMAIN.as_bytes(), 32);
    assert_eq!(
        encode_hex(&descriptor_key),
        string_field(descriptor, "descriptorKeyHex"),
        "K_descriptor disagrees between Swift and Rust"
    );

    let mac_input = descriptor_mac_input(descriptor);
    assert_eq!(
        encode_hex(&mac_input),
        string_field(descriptor, "macInputHex"),
        "canonical descriptor MAC input disagrees"
    );

    let mac = hmac_sha256(&descriptor_key, &mac_input);
    assert_eq!(
        encode_hex(&mac),
        string_field(descriptor, "descriptorMACHex"),
        "descriptor MAC disagrees"
    );

    let canonical = descriptor_canonical_bytes(&mac_input, &mac);
    assert_eq!(
        encode_hex(&canonical),
        string_field(descriptor, "canonicalBytesHex"),
        "full canonical descriptor bytes disagree"
    );

    assert_eq!(
        encode_hex(&sha256(&canonical)),
        string_field(descriptor, "digestHex"),
        "descriptor digest disagrees"
    );
}

/// The transcript, the derivation ladder, and all three proofs reproduce.
#[test]
fn session_vectors_reproduce() {
    let vectors = load_vectors();
    let root = bytes_field(&vectors, "installationRootHex");
    let descriptor = &vectors["descriptor"];
    let session = &vectors["session"];

    let digest = bytes_field(descriptor, "digestHex");
    let transcript = session_transcript(descriptor, session, &digest);
    assert_eq!(
        encode_hex(&transcript),
        string_field(session, "transcriptHex"),
        "canonical session transcript disagrees"
    );
    assert_eq!(
        encode_hex(&sha256(&transcript)),
        string_field(session, "transcriptDigestHex")
    );

    let auth_key = hkdf_sha256(&root, &digest, AUTH_DOMAIN.as_bytes(), 32);
    assert_eq!(encode_hex(&auth_key), string_field(session, "authKeyHex"));

    let session_key = hkdf_sha256(
        &root,
        &sha256(&transcript),
        SESSION_KEY_DOMAIN.as_bytes(),
        32,
    );
    assert_eq!(
        encode_hex(&session_key),
        string_field(session, "sessionKeyHex")
    );

    let server_proof = hmac_sha256(&auth_key, &domain_prefixed(SERVER_PROOF_DOMAIN, &transcript));
    let client_proof = hmac_sha256(&auth_key, &domain_prefixed(CLIENT_PROOF_DOMAIN, &transcript));
    let established = hmac_sha256(
        &session_key,
        &domain_prefixed(ESTABLISHED_DOMAIN, &transcript),
    );
    assert_eq!(
        encode_hex(&server_proof),
        string_field(session, "serverProofHex")
    );
    assert_eq!(
        encode_hex(&client_proof),
        string_field(session, "clientProofHex")
    );
    assert_eq!(
        encode_hex(&established),
        string_field(session, "establishmentProofHex")
    );

    // Domain separation is the property that stops a reflected server proof
    // from satisfying the client check; assert it rather than assuming it.
    assert_ne!(server_proof, client_proof);
    assert_ne!(session_key, auth_key);

    // The published header forms must match what a Rust peer would emit.
    let session_id = bytes_field(session, "sessionIdentifierHex");
    assert_eq!(
        base64url_encode(&session_id),
        string_field(session, "sessionIdentifierBase64URL")
    );
    assert_eq!(
        format!("Mootx01Session {}", base64url_encode(&session_id)),
        string_field(session, "authorizationHeaderValue")
    );
}

/// Every request MAC reproduces, in order and out of order.
#[test]
fn request_mac_vectors_reproduce() {
    let vectors = load_vectors();
    let session = &vectors["session"];
    let session_key = bytes_field(session, "sessionKeyHex");
    let session_id = bytes_field(session, "sessionIdentifierHex");

    let requests = vectors["requests"].as_array().expect("requests array");
    assert!(!requests.is_empty(), "vector file publishes no requests");

    for request in requests {
        let sequence = u64_field(request, "sequence");
        let body = string_field(request, "bodyUTF8").as_bytes();

        assert_eq!(
            encode_hex(&sha256(body)),
            string_field(request, "bodySHA256Hex"),
            "body digest disagrees at sequence {sequence}"
        );

        let mac = request_mac(
            &session_key,
            &session_id,
            sequence,
            "POST",
            "/mcp/first-party",
            "application/json",
            body,
        );
        assert_eq!(
            encode_hex(&mac),
            string_field(request, "macHex"),
            "request MAC disagrees at sequence {sequence}"
        );
        assert_eq!(
            base64url_encode(&mac),
            string_field(request, "macBase64URL"),
            "request MAC header form disagrees at sequence {sequence}"
        );
        // The canonical sequence header has exactly one spelling per value.
        assert_eq!(
            sequence.to_string(),
            string_field(request, "sequenceHeader")
        );
    }
}

/// Every response MAC reproduces, including the empty 204 acknowledgement.
#[test]
fn response_mac_vectors_reproduce() {
    let vectors = load_vectors();
    let session = &vectors["session"];
    let session_key = bytes_field(session, "sessionKeyHex");
    let session_id = bytes_field(session, "sessionIdentifierHex");

    let responses = vectors["responses"].as_array().expect("responses array");
    let mut saw_no_content = false;

    for response in responses {
        let sequence = u64_field(response, "sequence");
        let status = u64_field(response, "status") as u16;
        let content_type = string_field(response, "contentType");
        let body = string_field(response, "bodyUTF8").as_bytes();
        if status == 204 {
            saw_no_content = true;
            // A 204 carries no body and no Content-Type; the canonical content
            // type is therefore the empty string, not "application/json".
            assert!(body.is_empty());
            assert!(content_type.is_empty());
        }

        let mac = response_mac(
            &session_key,
            &session_id,
            sequence,
            status,
            content_type,
            body,
        );
        assert_eq!(
            encode_hex(&mac),
            string_field(response, "macHex"),
            "response MAC disagrees at sequence {sequence} status {status}"
        );
        assert_eq!(
            base64url_encode(&mac),
            string_field(response, "macBase64URL")
        );
    }

    assert!(
        saw_no_content,
        "vectors must cover the MACed empty 204 acknowledgement"
    );
}

/// The negative vectors reproduce too.
///
/// Reproducing only the positive vectors would be satisfied by a verifier that
/// ignored part of its input. These pin that a one-bit change anywhere in the
/// covered material moves the output, and that the mutated value is the exact
/// one Swift computed.
#[test]
fn negative_vectors_reproduce() {
    let vectors = load_vectors();
    let root = bytes_field(&vectors, "installationRootHex");
    let descriptor = &vectors["descriptor"];
    let session = &vectors["session"];
    let negative = &vectors["negative"];

    let mac_input = descriptor_mac_input(descriptor);
    let mut mac = bytes_field(descriptor, "descriptorMACHex");

    // Flip one bit of the descriptor MAC: the digest must move.
    mac[0] ^= 0x01;
    let flipped_canonical = descriptor_canonical_bytes(&mac_input, &mac);
    assert_eq!(
        encode_hex(&sha256(&flipped_canonical)),
        string_field(negative, "descriptorMACBit0FlippedDigestHex")
    );
    assert_ne!(
        encode_hex(&sha256(&flipped_canonical)),
        string_field(descriptor, "digestHex")
    );

    // Flip one bit of the transcript: the server proof must move.
    let digest = bytes_field(descriptor, "digestHex");
    let mut transcript = session_transcript(descriptor, session, &digest);
    transcript[0] ^= 0x01;
    let auth_key = hkdf_sha256(&root, &digest, AUTH_DOMAIN.as_bytes(), 32);
    let flipped_proof = hmac_sha256(&auth_key, &domain_prefixed(SERVER_PROOF_DOMAIN, &transcript));
    assert_eq!(
        encode_hex(&flipped_proof),
        string_field(negative, "transcriptBit0FlippedServerProofHex")
    );

    let session_key = bytes_field(session, "sessionKeyHex");
    let session_id = bytes_field(session, "sessionIdentifierHex");

    // Flip one bit of the request body: the request MAC must move.
    let mut body = b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}".to_vec();
    body[0] ^= 0x01;
    let flipped_request = request_mac(
        &session_key,
        &session_id,
        1,
        "POST",
        "/mcp/first-party",
        "application/json",
        &body,
    );
    assert_eq!(
        encode_hex(&flipped_request),
        string_field(negative, "requestBodyBit0FlippedMACHex")
    );

    // Change only the response status: the response MAC must move. This is the
    // property that stops a peer downgrading an authenticated 200 to a 401.
    let ok_body = b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}";
    let mutated_status = response_mac(
        &session_key,
        &session_id,
        1,
        401,
        "application/json",
        ok_body,
    );
    assert_eq!(
        encode_hex(&mutated_status),
        string_field(negative, "responseStatusMutated401MACHex")
    );
    assert_ne!(
        encode_hex(&mutated_status),
        string_field(&vectors["responses"][0], "macHex")
    );
}

/// The Rust port must not advertise a capability it does not implement.
///
/// Kong binding decision 5: Rust passes the vectors before it may implement or
/// advertise the protocol. This test fails if `authenticated-first-party` ever
/// appears in the Rust source tree, which is what would make the advertisement
/// possible.
#[test]
fn rust_port_advertises_no_first_party_capability() {
    let mut src = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    src.push("src");

    fn scan(dir: &PathBuf, hits: &mut Vec<String>) {
        let entries = match fs::read_dir(dir) {
            Ok(entries) => entries,
            Err(_) => return,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                scan(&path, hits);
            } else if path.extension().and_then(|e| e.to_str()) == Some("rs") {
                if let Ok(text) = fs::read_to_string(&path) {
                    if text.contains("authenticated-first-party") {
                        hits.push(path.display().to_string());
                    }
                }
            }
        }
    }

    let mut hits = Vec::new();
    scan(&src, &mut hits);
    assert!(
        hits.is_empty(),
        "Rust src/ must not reference authenticated-first-party until a parity \
         mission implements the full wire; found in: {hits:?}"
    );
}

// VectorFile.swift
//
// In-memory model of a test-vector file plus JSON canonical
// serialization per `docs/test-vector-format.md`.

import Foundation

public struct VectorFile {

    public static let formatVersion = "1"
    public static let harnessVersion = "1.0.0"

    public var primitive: String
    public var cookbookSection: String
    public var generator: Generator
    public var seed: UInt64
    public var generatedAt: String
    public var outputCrc32: UInt32
    public var cases: [Case]

    public init(primitive: String,
                cookbookSection: String,
                generator: Generator,
                seed: UInt64,
                generatedAt: String,
                outputCrc32: UInt32,
                cases: [Case]) {
        self.primitive = primitive
        self.cookbookSection = cookbookSection
        self.generator = generator
        self.seed = seed
        self.generatedAt = generatedAt
        self.outputCrc32 = outputCrc32
        self.cases = cases
    }

    public struct Generator {
        public var language: String
        public var harnessVersion: String
        public var referenceFile: String

        public init(language: String, harnessVersion: String,
                    referenceFile: String) {
            self.language = language
            self.harnessVersion = harnessVersion
            self.referenceFile = referenceFile
        }
    }

    public struct Case {
        public var id: String
        public var description: String
        /// Inputs payload. Each primitive defines its own schema.
        /// Stored as canonical JSON dict (lex-sorted keys).
        public var inputs: JSONDict
        /// Expected output payload. Same shape rules as inputs.
        public var expectedOutput: JSONDict

        public init(id: String, description: String,
                    inputs: JSONDict, expectedOutput: JSONDict) {
            self.id = id
            self.description = description
            self.inputs = inputs
            self.expectedOutput = expectedOutput
        }
    }
}

/// Minimal JSON dict / value representation. Keeps key order
/// stable (sorted lex) for canonical output. Restricted to the
/// value types the test-vector format uses.
public enum JSONValue {
    case string(String)
    case integer(Int64)
    case double(Double)         // serialized as hex per format spec; NOT JSON-number
    case bool(Bool)
    case null
    case array([JSONValue])
    case dict(JSONDict)
}

public struct JSONDict {
    public private(set) var keys: [String]
    public private(set) var values: [String: JSONValue]

    public init() {
        keys = []
        values = [:]
    }

    public init(_ pairs: [(String, JSONValue)]) {
        keys = pairs.map { $0.0 }.sorted()
        values = [:]
        for (k, v) in pairs {
            values[k] = v
        }
    }

    public mutating func set(_ key: String, _ value: JSONValue) {
        if values[key] == nil {
            keys.append(key)
            keys.sort()
        }
        values[key] = value
    }

    public func get(_ key: String) -> JSONValue? {
        return values[key]
    }
}

public enum JSONWriter {

    /// Produce canonical JSON for a VectorFile per spec.
    public static func write(_ file: VectorFile) -> String {
        let topLevel = JSONDict([
            ("format_version",      .string(VectorFile.formatVersion)),
            ("primitive",           .string(file.primitive)),
            ("cookbook_section",    .string(file.cookbookSection)),
            ("generator",           .dict(JSONDict([
                ("language",         .string(file.generator.language)),
                ("harness_version",  .string(file.generator.harnessVersion)),
                ("reference_file",   .string(file.generator.referenceFile)),
            ]))),
            ("seed",                .string(HexCoding.u64(file.seed))),
            ("generated_at",        .string(file.generatedAt)),
            ("case_count",          .integer(Int64(file.cases.count))),
            ("output_crc32",        .string(HexCoding.crc32(file.outputCrc32))),
            ("cases",               .array(file.cases.map { caseToValue($0) })),
        ])
        var out = ""
        writeValue(.dict(topLevel), indent: 0, into: &out)
        out.append("\n")
        return out
    }

    private static func caseToValue(_ c: VectorFile.Case) -> JSONValue {
        return .dict(JSONDict([
            ("id",              .string(c.id)),
            ("description",     .string(c.description)),
            ("inputs",          .dict(c.inputs)),
            ("expected_output", .dict(c.expectedOutput)),
        ]))
    }

    private static func writeValue(_ v: JSONValue, indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent)
        let nextPad = String(repeating: "  ", count: indent + 1)
        switch v {
        case .string(let s):
            out.append("\"")
            for ch in s {
                switch ch {
                case "\"":  out.append("\\\"")
                case "\\":  out.append("\\\\")
                case "\n":  out.append("\\n")
                case "\r":  out.append("\\r")
                case "\t":  out.append("\\t")
                default:
                    let scalar = ch.unicodeScalars.first!.value
                    if scalar < 0x20 {
                        out.append(String(format: "\\u%04x", scalar))
                    } else {
                        out.append(ch)
                    }
                }
            }
            out.append("\"")
        case .integer(let i):
            out.append(String(i))
        case .double(let d):
            // Per format spec: f64 is hex-encoded. Caller should
            // have already converted to .string(hex) before
            // reaching the writer. Reaching .double(...) here is
            // a contract violation.
            preconditionFailure("doubles must be hex-encoded as .string before reaching JSONWriter; got \(d)")
        case .bool(let b):
            out.append(b ? "true" : "false")
        case .null:
            out.append("null")
        case .array(let arr):
            if arr.isEmpty {
                out.append("[]")
            } else {
                out.append("[\n")
                for (i, item) in arr.enumerated() {
                    out.append(nextPad)
                    writeValue(item, indent: indent + 1, into: &out)
                    if i < arr.count - 1 { out.append(",") }
                    out.append("\n")
                }
                out.append(pad)
                out.append("]")
            }
        case .dict(let d):
            if d.keys.isEmpty {
                out.append("{}")
            } else {
                out.append("{\n")
                for (i, key) in d.keys.enumerated() {
                    out.append(nextPad)
                    out.append("\"\(key)\": ")
                    writeValue(d.values[key]!, indent: indent + 1, into: &out)
                    if i < d.keys.count - 1 { out.append(",") }
                    out.append("\n")
                }
                out.append(pad)
                out.append("}")
            }
        }
    }
}

public enum JSONReader {

    /// Parse a canonical-format JSON string into a JSONDict.
    /// Tolerant of extra whitespace. Hex-encoded f64 values
    /// remain strings; callers convert as needed.
    public static func parseDict(_ s: String) throws -> JSONDict {
        // For the harness we rely on Foundation's JSONSerialization
        // for parsing and then convert into our JSONDict form.
        guard let data = s.data(using: .utf8) else {
            throw JSONReaderError.invalidUTF8
        }
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else {
            throw JSONReaderError.expectedDict
        }
        return try toJSONDict(dict)
    }

    public static func parseVectorFile(_ s: String) throws -> VectorFile {
        let root = try parseDict(s)
        guard case .string(let formatVersion) = root.get("format_version") ?? .null else {
            throw JSONReaderError.missingField("format_version")
        }
        guard formatVersion == VectorFile.formatVersion else {
            throw JSONReaderError.versionMismatch(formatVersion)
        }
        guard case .string(let primitive)        = root.get("primitive")        ?? .null,
              case .string(let cookbookSection)  = root.get("cookbook_section") ?? .null,
              case .dict(let generatorDict)      = root.get("generator")        ?? .null,
              case .string(let seedHex)          = root.get("seed")             ?? .null,
              case .string(let generatedAt)      = root.get("generated_at")     ?? .null,
              case .integer(_)                   = root.get("case_count")       ?? .null,
              case .string(let crcHex)           = root.get("output_crc32")     ?? .null,
              case .array(let caseArr)           = root.get("cases")            ?? .null else {
            throw JSONReaderError.malformedRoot
        }
        let seedBytes = try HexCoding.decode(seedHex)
        guard seedBytes.count == 8 else {
            throw JSONReaderError.malformedField("seed")
        }
        let seed = seedBytes.enumerated().reduce(UInt64(0)) { acc, item in
            acc | (UInt64(item.element) << (item.offset * 8))
        }
        let crcBytes = try HexCoding.decode(crcHex)
        guard crcBytes.count == 4 else {
            throw JSONReaderError.malformedField("output_crc32")
        }
        let crc = crcBytes.enumerated().reduce(UInt32(0)) { acc, item in
            acc | (UInt32(item.element) << (item.offset * 8))
        }
        guard case .string(let lang)        = generatorDict.get("language")         ?? .null,
              case .string(let hVer)        = generatorDict.get("harness_version")  ?? .null,
              case .string(let refFile)     = generatorDict.get("reference_file")   ?? .null else {
            throw JSONReaderError.malformedField("generator")
        }
        var cases = [VectorFile.Case]()
        for v in caseArr {
            guard case .dict(let c) = v else { throw JSONReaderError.malformedField("cases") }
            guard case .string(let id)             = c.get("id")              ?? .null,
                  case .string(let desc)           = c.get("description")     ?? .null,
                  case .dict(let inp)              = c.get("inputs")          ?? .null,
                  case .dict(let exp)              = c.get("expected_output") ?? .null else {
                throw JSONReaderError.malformedField("case")
            }
            cases.append(VectorFile.Case(id: id, description: desc,
                                          inputs: inp, expectedOutput: exp))
        }
        return VectorFile(
            primitive: primitive,
            cookbookSection: cookbookSection,
            generator: VectorFile.Generator(language: lang,
                                             harnessVersion: hVer,
                                             referenceFile: refFile),
            seed: seed,
            generatedAt: generatedAt,
            outputCrc32: crc,
            cases: cases
        )
    }

    private static func toJSONDict(_ d: [String: Any]) throws -> JSONDict {
        var pairs = [(String, JSONValue)]()
        for (k, v) in d {
            pairs.append((k, try toJSONValue(v)))
        }
        return JSONDict(pairs)
    }

    private static func toJSONValue(_ v: Any) throws -> JSONValue {
        if let s = v as? String { return .string(s) }
        if let b = v as? Bool, type(of: v) == Bool.self { return .bool(b) }
        if let n = v as? NSNumber {
            // NSNumber covers Int and Double; we discriminate.
            // Booleans are sometimes returned as NSNumber too.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            if String(cString: n.objCType) == "d" || String(cString: n.objCType) == "f" {
                return .double(n.doubleValue)
            }
            return .integer(n.int64Value)
        }
        if let arr = v as? [Any] {
            return .array(try arr.map { try toJSONValue($0) })
        }
        if let dict = v as? [String: Any] {
            return .dict(try toJSONDict(dict))
        }
        if v is NSNull {
            return .null
        }
        throw JSONReaderError.unsupportedValueType(String(describing: type(of: v)))
    }
}

public enum JSONReaderError: Error, CustomStringConvertible {
    case invalidUTF8
    case expectedDict
    case missingField(String)
    case malformedField(String)
    case malformedRoot
    case versionMismatch(String)
    case unsupportedValueType(String)

    public var description: String {
        switch self {
        case .invalidUTF8:              return "JSON input is not valid UTF-8"
        case .expectedDict:             return "expected top-level JSON object"
        case .missingField(let f):      return "missing required field: \(f)"
        case .malformedField(let f):    return "malformed field: \(f)"
        case .malformedRoot:            return "malformed root object"
        case .versionMismatch(let v):   return "unsupported format_version: \(v)"
        case .unsupportedValueType(let t): return "unsupported JSON value type: \(t)"
        }
    }
}

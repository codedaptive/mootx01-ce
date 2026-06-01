// GeneratedExpressionTests.swift
//
// Part 2 coverage gap: GeneratedColumn / GeneratedExpression are exercised
// only indirectly through the conformance generatedSchema (bitAnd, shiftRight,
// notEqual via SQLite/InMemory). The pure renderSQL() and evaluate() surface —
// bitOr, bitXor, shiftLeft, equal, and the integerValue type coercion — had no
// direct unit coverage. These tests pin both, with no backend involved.

import Testing
import SubstrateTypes
import PersistenceKit

struct GeneratedExpressionTests {

    // MARK: - renderSQL (all nine cases)

    @Test func renderColumnQuotesIdentifier() {
        #expect(GeneratedExpression.column("flags").renderSQL() == "\"flags\"")
    }

    @Test func renderLiteral() {
        #expect(GeneratedExpression.literal(15).renderSQL() == "15")
        #expect(GeneratedExpression.literal(-3).renderSQL() == "-3")
    }

    @Test func renderBitAnd() {
        let e = GeneratedExpression.bitAnd(.column("flags"), .literal(0x0F))
        #expect(e.renderSQL() == "(\"flags\" & 15)")
    }

    @Test func renderBitOr() {
        let e = GeneratedExpression.bitOr(.column("a"), .column("b"))
        #expect(e.renderSQL() == "(\"a\" | \"b\")")
    }

    @Test func renderBitXorExpandsToOrMinusAnd() {
        // SQLite has no binary XOR; both backends express it as (a|b)-(a&b).
        let e = GeneratedExpression.bitXor(.column("a"), .literal(3))
        #expect(e.renderSQL() == "((\"a\" | 3) - (\"a\" & 3))")
    }

    @Test func renderShifts() {
        #expect(GeneratedExpression.shiftRight(.column("flags"), 4).renderSQL() == "(\"flags\" >> 4)")
        #expect(GeneratedExpression.shiftLeft(.column("flags"), 2).renderSQL() == "(\"flags\" << 2)")
    }

    @Test func renderEqualityThroughCase() {
        #expect(GeneratedExpression.equal(.column("a"), .literal(1)).renderSQL()
                == "(CASE WHEN \"a\" = 1 THEN 1 ELSE 0 END)")
        #expect(GeneratedExpression.notEqual(.column("a"), .literal(0)).renderSQL()
                == "(CASE WHEN \"a\" <> 0 THEN 1 ELSE 0 END)")
    }

    @Test func renderNestedComposes() {
        // (flags >> 6) & 0x3F — the six-bit field extract from the doc comment.
        let e = GeneratedExpression.bitAnd(.shiftRight(.column("adjective"), 6), .literal(0x3F))
        #expect(e.renderSQL() == "((\"adjective\" >> 6) & 63)")
    }

    // MARK: - evaluate (all cases)

    private let row: [String: TypedValue] = ["flags": .bitmap(0xA5)]  // 1010_0101

    @Test func evaluateColumnAndLiteral() {
        #expect(GeneratedExpression.column("flags").evaluate(row) == 0xA5)
        #expect(GeneratedExpression.literal(7).evaluate(row) == 7)
    }

    @Test func evaluateBitwiseOps() {
        #expect(GeneratedExpression.bitAnd(.column("flags"), .literal(0x0F)).evaluate(row) == 0x05)
        #expect(GeneratedExpression.bitOr(.literal(0xF0), .literal(0x0F)).evaluate(row) == 0xFF)
        #expect(GeneratedExpression.bitXor(.literal(0xFF), .literal(0x0F)).evaluate(row) == 0xF0)
    }

    @Test func evaluateShifts() {
        #expect(GeneratedExpression.shiftRight(.column("flags"), 4).evaluate(row) == 0x0A)
        #expect(GeneratedExpression.shiftLeft(.literal(1), 4).evaluate(row) == 16)
    }

    @Test func evaluateEquality() {
        #expect(GeneratedExpression.equal(.literal(5), .literal(5)).evaluate(row) == 1)
        #expect(GeneratedExpression.equal(.literal(5), .literal(6)).evaluate(row) == 0)
        #expect(GeneratedExpression.notEqual(.literal(5), .literal(6)).evaluate(row) == 1)
        #expect(GeneratedExpression.notEqual(.literal(5), .literal(5)).evaluate(row) == 0)
    }

    // MARK: - integerValue coercion (via .column over each integer-family case)

    @Test func evaluateCoercesIntegerFamily() {
        #expect(GeneratedExpression.column("v").evaluate(["v": .int(42)]) == 42)
        #expect(GeneratedExpression.column("v").evaluate(["v": .bitmap(9)]) == 9)
        #expect(GeneratedExpression.column("v").evaluate(["v": .bool(true)]) == 1)
        #expect(GeneratedExpression.column("v").evaluate(["v": .bool(false)]) == 0)
        let hlc = HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1)
        #expect(GeneratedExpression.column("v").evaluate(["v": .hlc(hlc)]) == Int64(bitPattern: hlc.packed))
    }

    @Test func evaluateNonIntegerAndAbsentColumnsReadAsZero() {
        #expect(GeneratedExpression.column("v").evaluate(["v": .text("nope")]) == 0)
        #expect(GeneratedExpression.column("v").evaluate(["v": .null]) == 0)
        #expect(GeneratedExpression.column("missing").evaluate([:]) == 0)
    }

    // MARK: - GeneratedColumn value semantics

    @Test func generatedColumnEquatable() {
        let a = GeneratedColumn(name: "low", type: .int, expression: .bitAnd(.column("flags"), .literal(0x0F)))
        let b = GeneratedColumn(name: "low", type: .int, expression: .bitAnd(.column("flags"), .literal(0x0F)))
        let c = GeneratedColumn(name: "low", type: .int, expression: .bitAnd(.column("flags"), .literal(0xF0)))
        #expect(a == b)
        #expect(a != c)
    }
}

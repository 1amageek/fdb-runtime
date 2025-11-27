import Testing
import Foundation
import FDBModel
@testable import FDBCore
@testable import FDBIndexing
@testable import FDBRuntime

@Suite("KeyExpression Tests")
struct KeyExpressionTests {

    @Test("FieldKeyExpression columnCount")
    func testFieldColumnCount() {
        let expr = FieldKeyExpression(fieldName: "email")
        #expect(expr.columnCount == 1)
        #expect(expr.fieldName == "email")
    }

    @Test("ConcatenateKeyExpression columnCount")
    func testConcatenateColumnCount() {
        let field1 = FieldKeyExpression(fieldName: "firstName")
        let field2 = FieldKeyExpression(fieldName: "lastName")
        let concat = ConcatenateKeyExpression(children: [field1, field2])

        #expect(concat.columnCount == 2)
        #expect(concat.children.count == 2)
    }

    @Test("EmptyKeyExpression columnCount")
    func testEmptyColumnCount() {
        let empty = EmptyKeyExpression()
        #expect(empty.columnCount == 0)
    }

    @Test("LiteralKeyExpression columnCount")
    func testLiteralColumnCount() {
        let literal = LiteralKeyExpression(value: "constant")
        #expect(literal.columnCount == 1)
        #expect(literal.value == "constant")
    }

    @Test("NestExpression columnCount")
    func testNestColumnCount() {
        let child = FieldKeyExpression(fieldName: "street")
        let nest = NestExpression(parentField: "address", child: child)

        #expect(nest.columnCount == 1)
        #expect(nest.parentField == "address")
    }

    @Test("RangeKeyExpression properties")
    func testRangeKeyExpression() {
        let rangeExpr = RangeKeyExpression(
            fieldName: "dateRange",
            component: .lowerBound
        )

        #expect(rangeExpr.columnCount == 1)
        #expect(rangeExpr.fieldName == "dateRange")
        #expect(rangeExpr.component == .lowerBound)
    }

    @Test("RangeComponent cases")
    func testRangeComponent() {
        #expect(RangeComponent.lowerBound.rawValue == "lowerBound")
        #expect(RangeComponent.upperBound.rawValue == "upperBound")
    }

    @Test("Complex concatenate expression")
    func testComplexConcatenate() {
        let field1 = FieldKeyExpression(fieldName: "category")
        let field2 = FieldKeyExpression(fieldName: "price")
        let literal = LiteralKeyExpression(value: "Electronics")

        let concat = ConcatenateKeyExpression(children: [field1, field2, literal])

        #expect(concat.columnCount == 3)
    }

    // MARK: - KeyExpressionFactory Tests

    @Test("KeyExpressionFactory from simple dot notation")
    func testFactoryFromSimpleDotNotation() {
        let expr = KeyExpressionFactory.from(dotNotation: "email")

        // Should be a simple FieldKeyExpression
        let fieldExpr = expr as? FieldKeyExpression
        #expect(fieldExpr != nil)
        #expect(fieldExpr?.fieldName == "email")
    }

    @Test("KeyExpressionFactory from nested dot notation")
    func testFactoryFromNestedDotNotation() {
        let expr = KeyExpressionFactory.from(dotNotation: "address.city")

        // Should be NestExpression(parentField: "address", child: FieldKeyExpression(fieldName: "city"))
        let nestExpr = expr as? NestExpression
        #expect(nestExpr != nil)
        #expect(nestExpr?.parentField == "address")

        let childExpr = nestExpr?.child as? FieldKeyExpression
        #expect(childExpr != nil)
        #expect(childExpr?.fieldName == "city")
    }

    @Test("KeyExpressionFactory from deeply nested dot notation")
    func testFactoryFromDeeplyNestedDotNotation() {
        let expr = KeyExpressionFactory.from(dotNotation: "user.address.city")

        // Should be NestExpression(parentField: "user", child: NestExpression(parentField: "address", child: FieldKeyExpression(fieldName: "city")))
        let outerNest = expr as? NestExpression
        #expect(outerNest != nil)
        #expect(outerNest?.parentField == "user")

        let innerNest = outerNest?.child as? NestExpression
        #expect(innerNest != nil)
        #expect(innerNest?.parentField == "address")

        let fieldExpr = innerNest?.child as? FieldKeyExpression
        #expect(fieldExpr != nil)
        #expect(fieldExpr?.fieldName == "city")
    }

    @Test("KeyExpressionFactory from components")
    func testFactoryFromComponents() {
        let expr = KeyExpressionFactory.from(components: ["address", "city"])

        let nestExpr = expr as? NestExpression
        #expect(nestExpr != nil)
        #expect(nestExpr?.parentField == "address")

        let childExpr = nestExpr?.child as? FieldKeyExpression
        #expect(childExpr != nil)
        #expect(childExpr?.fieldName == "city")
    }

    @Test("KeyExpressionFactory from empty components")
    func testFactoryFromEmptyComponents() {
        let expr = KeyExpressionFactory.from(components: [])

        let emptyExpr = expr as? EmptyKeyExpression
        #expect(emptyExpr != nil)
    }

    @Test("KeyExpressionFactory from keyPaths array - single")
    func testFactoryFromKeyPathsSingle() {
        let expr = KeyExpressionFactory.from(keyPaths: ["email"])

        let fieldExpr = expr as? FieldKeyExpression
        #expect(fieldExpr != nil)
        #expect(fieldExpr?.fieldName == "email")
    }

    @Test("KeyExpressionFactory from keyPaths array - multiple")
    func testFactoryFromKeyPathsMultiple() {
        let expr = KeyExpressionFactory.from(keyPaths: ["category", "price"])

        let concatExpr = expr as? ConcatenateKeyExpression
        #expect(concatExpr != nil)
        #expect(concatExpr?.columnCount == 2)
    }

    @Test("KeyExpressionFactory from keyPaths array - with nested")
    func testFactoryFromKeyPathsWithNested() {
        let expr = KeyExpressionFactory.from(keyPaths: ["category", "address.city"])

        let concatExpr = expr as? ConcatenateKeyExpression
        #expect(concatExpr != nil)
        #expect(concatExpr?.columnCount == 2)

        // First child should be simple field
        let firstChild = concatExpr?.children[0] as? FieldKeyExpression
        #expect(firstChild?.fieldName == "category")

        // Second child should be nested
        let secondChild = concatExpr?.children[1] as? NestExpression
        #expect(secondChild?.parentField == "address")
    }
}

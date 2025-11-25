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
}

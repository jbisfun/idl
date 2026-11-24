import XCTest

@testable import CalcCore

final class CalculatorTests: XCTestCase {
    func testArithmetic() {
        let calc = Calculator()
        XCTAssertEqual(calc.evaluate(2, "+", 3), 5)
        XCTAssertEqual(calc.evaluate(7, "×", 6), 42)
        XCTAssertNil(calc.evaluate(1, "÷", 0))
    }

    func testMemory() {
        var calc = Calculator()
        calc.store(12.5)
        XCTAssertEqual(calc.memory, 12.5)
    }
}

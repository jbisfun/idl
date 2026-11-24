import Testing

@testable import CalcCore

@Test func wholeNumbersHaveNoFraction() {
    #expect(Calculator.format(4) == "4")
    #expect(Calculator.format(-3) == "-3")
}

@Test func fractionsAreKept() {
    #expect(Calculator.format(0.5) == "0.5")
}

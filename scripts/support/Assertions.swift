import Foundation

// Used only by test-core.py when the selected Command Line Tools lack XCTest.
final class XCTestExpectation {
    let description: String
    var isInverted = false
    private let lock = NSLock()
    private var fulfilled = false
    init(description: String) { self.description = description }
    func fulfill() { lock.lock(); fulfilled = true; lock.unlock() }
    var isFulfilled: Bool { lock.lock(); defer { lock.unlock() }; return fulfilled }
}

class XCTestCase {
    func expectation(description: String) -> XCTestExpectation { XCTestExpectation(description: description) }
    func fulfillment(of expectations: [XCTestExpectation], timeout: TimeInterval,
                     file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            for expectation in expectations where expectation.isInverted && expectation.isFulfilled {
                fail("Unexpected expectation: \(expectation.description)", file: file, line: line)
            }
            let complete = expectations.filter { !$0.isInverted }.allSatisfy(\.isFulfilled)
            if complete && !expectations.contains(where: \.isInverted) { return }
            if Date() >= deadline {
                guard complete else { fail("Expectation timed out", file: file, line: line) }
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

func XCTAssertEqual(_ expression: @autoclosure () throws -> Double, _ expected: @autoclosure () throws -> Double,
                    accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    do {
        let actual = try expression(), wanted = try expected()
        if actual != wanted && !(abs(actual - wanted) <= accuracy) { fail("Values differ beyond accuracy", file: file, line: line) }
    } catch { fail("Unexpected error: \(error)", file: file, line: line) }
}

private func fail(_ message: String, file: StaticString, line: UInt) -> Never {
    fatalError("\(file):\(line): \(message)")
}

func XCTAssertEqual<T: Equatable>(_ expression: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { if try expression() != expected() { fail("Values differ", file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    do { if try !expression() { fail("Expected true. \(message())", file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertNotNil<T>(_ expression: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    do { if try expression() == nil { fail("Expected value", file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertNotEqual<T: Equatable>(_ expression: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { if try expression() == expected() { fail("Expected different values", file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertLessThanOrEqual<T: Comparable>(_ expression: @autoclosure () throws -> T,
                                            _ expected: @autoclosure () throws -> T,
                                            file: StaticString = #filePath, line: UInt = #line) {
    do { if try expression() > expected() { fail("Value exceeds upper bound", file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try expression() { fail("Expected false", file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertNil<T>(_ expression: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    do { if try expression() != nil { fail("Expected nil", file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ handler: (Error) -> Void = { _ in }, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression() } catch { handler(error); return }
    fail("Expected error", file: file, line: line)
}
func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression() } catch { fail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try expression() else { fail("Missing value", file: file, line: line) }
    return value
}

func XCTFail(_ message: String = "Assertion failed", file: StaticString = #filePath, line: UInt = #line) {
    fail(message, file: file, line: line)
}

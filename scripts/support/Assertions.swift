import Foundation

// Used only by test-core.py when the selected Command Line Tools lack XCTest.
class XCTestCase {}

private func fail(_ message: String, file: StaticString, line: UInt) -> Never {
    fatalError("\(file):\(line): \(message)")
}

func XCTAssertEqual<T: Equatable>(_ expression: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { if try expression() != expected() { fail("Values differ", file: file, line: line) } }
    catch { fail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try !expression() { fail("Expected true", file: file, line: line) } }
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

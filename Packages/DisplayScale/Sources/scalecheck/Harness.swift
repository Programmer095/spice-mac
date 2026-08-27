// SPDX-License-Identifier: MIT
import CoreGraphics
import Foundation

/// Minimal dependency-free test harness (XCTest/swift-testing are unavailable with
/// Command Line Tools). Run with `swift run scalecheck`.
final class TestRunner {
    private var passed = 0
    private var failed = 0
    private var currentFailures: [String] = []

    func test(_ name: String, _ body: () throws -> Void) {
        currentFailures = []
        do { try body() } catch { currentFailures.append("threw unexpected error: \(error)") }
        if currentFailures.isEmpty {
            passed += 1; print("  ok   \(name)")
        } else {
            failed += 1; print("  FAIL \(name)")
            for f in currentFailures { print("        - \(f)") }
        }
    }

    func expect(_ cond: Bool, _ message: @autoclosure () -> String, _ line: UInt = #line) {
        if !cond { currentFailures.append("line \(line): \(message())") }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ line: UInt = #line) {
        if actual != expected { currentFailures.append("line \(line): expected \(expected), got \(actual)") }
    }

    func expectSize(_ actual: CGSize, _ expected: CGSize, _ line: UInt = #line) {
        if actual != expected {
            currentFailures.append("line \(line): expected \(str(expected)), got \(str(actual))")
        }
    }

    /// Compare floating-point scales without tripping over binary representation.
    func expectClose(_ actual: CGFloat, _ expected: CGFloat,
                     _ tolerance: CGFloat = 0.0001, _ line: UInt = #line) {
        if abs(actual - expected) > tolerance {
            currentFailures.append("line \(line): expected \(expected) ±\(tolerance), got \(actual)")
        }
    }

    func finishAndExit() -> Never {
        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

/// Readable size formatting for failure messages.
func str(_ s: CGSize) -> String { "\(Int(s.width))x\(Int(s.height))" }

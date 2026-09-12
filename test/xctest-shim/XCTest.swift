// XCTest 桩模块（仅用于本地类型检查）。
//
// 本机只有 Command Line Tools，没有 XCTest，所以 `swiftc -parse` 只能查语法 ——
// 类型错误（例如在新测试类里引用了另一个类的私有属性：`cannot find 't0' in scope`）
// 要等 CI 的 macos runner 才暴露。这里声明测试用到的 XCTest API 子集，配合
// `test/typecheck-swift-tests.sh` 把测试源码**类型检查**一遍（不执行、不替代 CI）。
//
// 真实 XCTest 仍是权威基线：这里的断言实现是空的，跑不出结果，只保证能编译。
// `@_exported`：真实 XCTest 会再导出 Foundation，测试源码只写 `import XCTest`
// 就能用 Date/DateFormatter —— 桩模块必须保持一致。
@_exported import Foundation

open class XCTestCase {
    public init() {}
}

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {}

public func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {}

public func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {}

public func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T, _ expression2: @autoclosure () throws -> T,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {}

public func XCTAssertEqual<T: FloatingPoint>(
    _ expression1: @autoclosure () throws -> T, _ expression2: @autoclosure () throws -> T,
    accuracy: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {}

public func XCTAssertNotEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T, _ expression2: @autoclosure () throws -> T,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {}

public func XCTAssertGreaterThan<T: Comparable>(
    _ expression1: @autoclosure () throws -> T, _ expression2: @autoclosure () throws -> T,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {}

public func XCTAssertGreaterThanOrEqual<T: Comparable>(
    _ expression1: @autoclosure () throws -> T, _ expression2: @autoclosure () throws -> T,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {}

public func XCTAssertLessThan<T: Comparable>(
    _ expression1: @autoclosure () throws -> T, _ expression2: @autoclosure () throws -> T,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {}

public func XCTAssertLessThanOrEqual<T: Comparable>(
    _ expression1: @autoclosure () throws -> T, _ expression2: @autoclosure () throws -> T,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {}

public func XCTAssertNil(
    _ expression: @autoclosure () throws -> Any?, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {}

public func XCTAssertNotNil(
    _ expression: @autoclosure () throws -> Any?, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {}

public func XCTUnwrap<T>(
    _ expression: @autoclosure () throws -> T?, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) throws -> T {
    guard let value = try expression() else { throw NSError(domain: "XCTUnwrap", code: 1) }
    return value
}

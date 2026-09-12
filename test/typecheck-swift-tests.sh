#!/bin/bash
#
# typecheck-swift-tests.sh — 本地**类型检查** XCTest 源码（不执行）。
#
# 为什么需要：本机只有 Command Line Tools，`swift test` 跑不了，XCTest 只在 CI
# 编译执行。`test/parse-swift-tests.sh` 只做 `swiftc -parse`（语法），所以“另一个
# 测试类的私有属性”“API 改名”这类**类型**错误要等 CI 才炸（真实踩过：新增用例
# 里引用 `t0` → CI 报 `cannot find 't0' in scope`，白跑一轮）。
#
# 做法：先用 `-enable-testing` 把 Core 编成模块，再用 `test/xctest-shim/XCTest.swift`
# 造一个同名 XCTest 模块（只有 API 声明），最后 `swiftc -typecheck` 测试源码。
#
# 注意：它只保证**能编译**，不执行断言；权威基线仍是 CI 的 `swift test`。
# 用法: test/typecheck-swift-tests.sh
set -u
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

if ! err=$(swiftc -emit-module -enable-testing -module-name dshNotifyCore \
      -emit-module-path "$OUT/dshNotifyCore.swiftmodule" \
      Sources/dshNotifyCore/*.swift 2>&1); then
  echo "FAIL: Core 模块编译失败（产品代码有问题）"
  grep -E "error:" <<<"$err" | head -10
  exit 1
fi

if ! err=$(swiftc -emit-module -module-name XCTest \
      -emit-module-path "$OUT/XCTest.swiftmodule" \
      test/xctest-shim/XCTest.swift 2>&1); then
  echo "FAIL: XCTest 桩模块编译失败"
  grep -E "error:" <<<"$err" | head -10
  exit 1
fi

if err=$(swiftc -typecheck -I "$OUT" Tests/dshNotifyCoreTests/*.swift 2>&1) \
   && ! grep -q 'error:' <<<"$err"; then
  echo "TYPECHECK OK: Tests/dshNotifyCoreTests/*.swift"
  exit 0
fi

echo "TYPECHECK FAIL:"
grep -E "error:" <<<"$err" | head -20
exit 1

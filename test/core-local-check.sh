#!/bin/bash
#
# core-local-check.sh — 本地 Core 自检（不需要 XCTest）。
#
# 背景：本机只有 Command Line Tools，`swift test` 跑不起来，XCTest 只在 CI
# （macos-15）执行 —— 于是“Core 的错要等 CI 才知道”。这个脚本把 dshNotifyCore
# 源码 + test/core-local-check.swift 编成一个可执行文件直接跑关键不变量
# （逐行锚点 / 快照往返 / 旧格式兼容 / 深链），把这类错误提前到本地。
#
# 注意：它不是 XCTest 的替代品（断言集更小），权威基线仍是 CI 的 Tests 工作流。
# 用法: test/core-local-check.sh
set -u
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# swiftc 只允许在名为 main.swift 的文件里写顶层代码，先拷成 main.swift 再编。
cp test/core-local-check.swift "$OUT/main.swift"
if ! swiftc -O -o "$OUT/core-check" Sources/dshNotifyCore/*.swift "$OUT/main.swift" 2>"$OUT/err"; then
  echo "FAIL: 编译失败"
  grep -E "error:" "$OUT/err" | head -10
  exit 1
fi
"$OUT/core-check"

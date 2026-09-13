#!/bin/bash
#
# source-fingerprint.sh — 源码指纹（issue #31）。
#
# 为什么需要：仓库里提交了预编译的 `bin/dsh-notify-server`（用户装包即用，不装 Swift
# 工具链）。**Swift 构建不可复现**，所以没法用"字节对比"判断提交的二进制是否与源码一致；
# 能对比的是**指纹**：把影响二进制的输入哈希一遍，构建时写进产物，检查时重新算一遍。
#
# 什么算输入：`Sources/**/*.swift`（生成文件除外）+ `Package.swift`。
# 逐文件一行 "hash  path" 再整体哈希一次 —— 路径参与摘要，于是**改名、新增、删除**
# 都会让指纹变（只哈希内容会漏掉这些）。用 LC_ALL=C sort 保证跨平台顺序一致。
#
# 什么**不算**输入（已知边界，写在 docs/troubleshooting.md §28）：Swift 版本、部署目标
# 以外的工具链差异、以及"同一份源码可以编出不同字节"这件事本身 —— 指纹证明的是
# **源码一致**，不是**字节一致**。
#
# 用法: scripts/source-fingerprint.sh        # 打印 64 位十六进制指纹
set -eu
cd "$(dirname "$0")/.."

GENERATED="Sources/dshNotifyCore/GeneratedBuildFingerprint.swift"

hash_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1   # macOS
  fi
}

inputs=$(printf '%s\n' Package.swift; find Sources -type f -name '*.swift' ! -path "$GENERATED")
inputs=$(printf '%s\n' "$inputs" | LC_ALL=C sort)

{
  for f in $inputs; do
    [ -f "$f" ] || continue
    printf '%s  %s\n' "$(hash_stream < "$f")" "$f"
  done
} | hash_stream

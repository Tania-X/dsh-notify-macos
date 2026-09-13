#!/bin/bash
#
# fingerprint-check.sh — 「提交的二进制和源码是一起构建的吗？」（issue #31）
#
# 背景：`bin/dsh-notify-server` 是提交进仓库的预编译产物（用户装包即用）。源码改了却忘了
# 重新构建、或构建了忘了提交，都会让用户跑上一个"和源码对不上"的守护进程 —— 这种事真实
# 发生过（PR #25 的修复一度没进产物，而 `Build complete! (4s)` 快得不正常就是线索）。
#
# 这个脚本能离线做全部判定，**不需要 Swift 工具链**：
#   1. 用 scripts/source-fingerprint.sh 现算源码指纹；
#   2. 与生成文件 `Sources/dshNotifyCore/GeneratedBuildFingerprint.swift` 里嵌的值比对
#      （那是**构建时**写进去的事实）；
#   3. 与随包发布的 `bin/dsh-notify-server.fingerprint` 比对（安装副本里只有它）。
# 任何一个不一致 → 退出码 1，并告诉你跑什么命令修。
#
# 它**不**证明二进制字节可复现（Swift 构建做不到），也不检查运行时守卫 —— 后者由
# `{"cmd":"build"}` 诊断命令 + `test/manual/contract-check.mjs` 覆盖（能发现"升级后
# 旧守护进程还在跑"这种情况）。
#
# 用法: scripts/fingerprint-check.sh        # CI 与本地都用它
set -eu
cd "$(dirname "$0")/.."

GENERATED="Sources/dshNotifyCore/GeneratedBuildFingerprint.swift"
SHIPPED="bin/dsh-notify-server.fingerprint"

fail=0
say_ok()   { echo "  PASS: $1"; }
say_bad()  { echo "  FAIL: $1"; fail=1; }

current=$(scripts/source-fingerprint.sh)

if [ ! -f "$GENERATED" ]; then
  say_bad "缺少 ${GENERATED}（用 scripts/build-universal.sh 生成并提交）"
  exit 1
fi
embedded=$(sed -n 's/.*value = "\([0-9a-f]*\)".*/\1/p' "$GENERATED" | head -1)

if [ -z "$embedded" ]; then
  say_bad "从 $GENERATED 里读不到指纹（格式变了？）"
elif [ "$embedded" = "$current" ]; then
  say_ok "嵌进产物的指纹 == 当前源码指纹（${current:0:12}…）"
else
  say_bad "嵌进产物的指纹与源码不一致：产物 ${embedded:0:12}… ≠ 源码 ${current:0:12}…"
fi

if [ -f "$SHIPPED" ]; then
  shipped=$(head -1 "$SHIPPED" | tr -d '[:space:]')
  if [ "$shipped" = "$current" ]; then
    say_ok "随包发布的指纹 == 当前源码指纹"
  else
    say_bad "bin/dsh-notify-server.fingerprint 与源码不一致：${shipped:0:12}… ≠ ${current:0:12}…"
  fi
else
  say_bad "缺少 ${SHIPPED}（用 scripts/build-universal.sh 生成并提交）"
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "二进制与源码对不上。修法：scripts/build-universal.sh（会重新生成指纹并重建产物），"
  echo "然后提交 Sources/dshNotifyCore/GeneratedBuildFingerprint.swift、bin/dsh-notify-server"
  echo "与 bin/dsh-notify-server.fingerprint 三个文件。见 docs/troubleshooting.md §28。"
  exit 1
fi

echo "  source fingerprint: ${current:0:12}… (完整值在 $SHIPPED)"

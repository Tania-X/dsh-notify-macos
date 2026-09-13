#!/bin/bash
#
# 构建 universal（arm64 + x86_64）守护进程 —— **不需要完整 Xcode**。
#
# `swift build --arch arm64 --arch x86_64` 那条路要 XCBuild（只随完整 Xcode 提供），
# 但同一件事可以用「分架构交叉编译 + lipo」做到，CLT 就够：
#
#   1. 针对每个 triple 各编一次（Apple Silicon 上交叉编 x86_64 是支持的）
#   2. lipo 合成 fat binary
#   3. ad-hoc 重签名（lipo 之后原签名失效；Apple Silicon 上没签名会被系统直接杀掉）
#
# 注意：triple 里的部署目标要与 Package.swift 的 platforms 保持一致（当前 macOS 13）。
# 如果改了平台版本，记得同步改这里。
#
# 用法: scripts/build-universal.sh
set -eu
cd "$(dirname "$0")/.."

ARM_TRIPLE=arm64-apple-macosx13.0
X86_TRIPLE=x86_64-apple-macosx13.0

echo "==> 编译 arm64"
swift build -c release --triple "$ARM_TRIPLE"
# 产物目录名不带平台版本（.build/arm64-apple-macosx/release），所以用 --show-bin-path 取真实路径，
# 而不是拿 triple 去拼 —— 拼错过一次，脚本静默失败在 lipo 那一步。
ARM_BIN="$(swift build -c release --triple "$ARM_TRIPLE" --show-bin-path)"

echo "==> 编译 x86_64（交叉）"
swift build -c release --triple "$X86_TRIPLE"
X86_BIN="$(swift build -c release --triple "$X86_TRIPLE" --show-bin-path)"

echo "==> lipo 合成"
echo "    arm64 : $ARM_BIN/dsh-notify-server"
echo "    x86_64: $X86_BIN/dsh-notify-server"
lipo -create \
  -output bin/dsh-notify-server \
  "$ARM_BIN/dsh-notify-server" \
  "$X86_BIN/dsh-notify-server"

echo "==> ad-hoc 签名（lipo 会让原签名失效）"
codesign --force --sign - bin/dsh-notify-server

echo "==> 结果"
lipo -info bin/dsh-notify-server
file bin/dsh-notify-server

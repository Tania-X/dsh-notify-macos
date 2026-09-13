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

# 源码指纹：写进产物（生成的 Swift 常量）并随包发布一份，用来回答"提交的二进制
# 和源码是一起构建的吗"。Swift 构建不可复现，所以只能比指纹，不能比字节。
# 见 scripts/source-fingerprint.sh 与 docs/troubleshooting.md §28。
FP="$(scripts/source-fingerprint.sh)"
echo "==> 源码指纹 ${FP:0:12}…"
cat > Sources/dshNotifyCore/GeneratedBuildFingerprint.swift <<SWIFT
// 自动生成，勿手改 —— 由 scripts/build-universal.sh 写入（issue #31）。
// 值 = 本文件之外 Sources/**/*.swift 与 Package.swift 的摘要；构建产物通过
// {\"cmd\":\"build\"} 诊断命令报告它，CI 用 scripts/fingerprint-check.sh 核对它。
public enum BuildFingerprint {
    public static let value = "${FP}"
}
SWIFT
printf '%s\n' "$FP" > bin/dsh-notify-server.fingerprint

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

# 自检：**启动刚产出的这个二进制**，问它自己嵌的是哪个指纹。
# 这一步专门挡"SwiftPM 缓存陈旧 / 只重建了一半"——历史上真出现过产物没带上刚修的
# 代码，而"Build complete! (4s)"快得不正常就是当时的线索（现在由指纹直接判定）。
if ! command -v nc >/dev/null 2>&1; then
  echo "==> 跳过运行自检（没有 nc）"
  exit 0
fi
echo "==> 自检：产物报告的指纹"
SOCK="${TMPDIR:-/tmp}/dsh-notify-buildcheck-$$.sock"
rm -f "$SOCK"
./bin/dsh-notify-server "$SOCK" >/dev/null 2>&1 &
DPID=$!
cleanup() { kill "$DPID" 2>/dev/null || true; wait "$DPID" 2>/dev/null || true; rm -f "$SOCK"; }
trap cleanup EXIT

REPORTED=""
for _ in $(seq 1 25); do
  REPORTED=$(printf '{"cmd":"build"}\n' | nc -U "$SOCK" 2>/dev/null || true)
  case "$REPORTED" in *"$FP"*) break ;; esac
  sleep 0.3
done
case "$REPORTED" in
  *"$FP"*)
    echo "    OK: 产物内嵌指纹与源码一致（${REPORTED}）"
    ;;
  *)
    echo "    FAIL: 产物报告的指纹与源码不一致：'$REPORTED'（期望含 ${FP:0:12}…）"
    echo "          多半是 SwiftPM 缓存陈旧：rm -rf .build/arm64-apple-macosx .build/x86_64-apple-macosx 后重跑"
    exit 1
    ;;
esac

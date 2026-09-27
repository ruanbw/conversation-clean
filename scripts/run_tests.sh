#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$ROOT_DIR/ConversationClean"

echo "===> Compiling scanner verification suite..."
BIN_PATH="/tmp/conversation_clean_test_scanners"

# 测试只覆盖「模型 + 共享基建 + 全部 scanner」，不含 SwiftUI 视图层。
# Core 必须包含：ConversationItem.formattedSize 走的是 Fmt.bytes（1024 进制，
# 与磁盘工具口径一致），它住在 Core/Formatting.swift 里。漏掉会直接编译不过。
# DesignSystem 已于 UI 原生化重构中删除，不再参与编译。
# 用 find 通配收集：新增 scanner 或测试文件都不必再手改本脚本。
APP_SOURCES=$(find "$APP_DIR/Models" "$APP_DIR/Core" "$APP_DIR/Scanners" -name '*.swift' | sort)
TEST_SOURCES=$(find "$SCRIPT_DIR" -name '*.swift' | sort)

# 逗号分隔的文件列表需要词分割，故此处有意不加引号。
# shellcheck disable=SC2086
xcrun swiftc $APP_SOURCES $TEST_SOURCES -o "$BIN_PATH"

echo "===> Running verification tests..."
"$BIN_PATH" "$@"
EXIT_CODE=$?

rm -f "$BIN_PATH"
exit $EXIT_CODE

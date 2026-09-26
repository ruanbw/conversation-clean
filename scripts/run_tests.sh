#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "===> Compiling scanner verification suite..."
BIN_PATH="/tmp/conversation_clean_test_scanners"

xcrun swiftc \
  "$ROOT_DIR/ConversationClean/Models/ConversationItem.swift" \
  "$ROOT_DIR/ConversationClean/Services/AgentScannerProtocol.swift" \
  "$ROOT_DIR/ConversationClean/Services/ClaudeCodeScanner.swift" \
  "$ROOT_DIR/ConversationClean/Services/CodexScanner.swift" \
  "$ROOT_DIR/ConversationClean/Services/AgentScanService.swift" \
  "$SCRIPT_DIR/test_scanners.swift" \
  -o "$BIN_PATH"

echo "===> Running verification tests..."
"$BIN_PATH" "$@"
EXIT_CODE=$?

rm -f "$BIN_PATH"
exit $EXIT_CODE

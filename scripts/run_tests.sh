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
  "$ROOT_DIR/ConversationClean/Services/ClineScanner.swift" \
  "$ROOT_DIR/ConversationClean/Services/RooCodeScanner.swift" \
  "$ROOT_DIR/ConversationClean/Services/ContinueScanner.swift" \
  "$ROOT_DIR/ConversationClean/Services/PiAgentScanner.swift" \
  "$ROOT_DIR/ConversationClean/Services/VSCDBHelper.swift" \
  "$ROOT_DIR/ConversationClean/Services/VSCodeChatScanner.swift" \
  "$ROOT_DIR/ConversationClean/Services/CursorScanner.swift" \
  "$ROOT_DIR/ConversationClean/Services/WindsurfScanner.swift" \
  "$ROOT_DIR/ConversationClean/Services/TraeScanner.swift" \
  "$ROOT_DIR/ConversationClean/Services/OpenVikingScanner.swift" \
  "$ROOT_DIR/ConversationClean/Services/AiderScanner.swift" \
  "$ROOT_DIR/ConversationClean/Services/ZedScanner.swift" \
  "$ROOT_DIR/ConversationClean/Services/OpenHandsScanner.swift" \
  "$ROOT_DIR/ConversationClean/Services/AntigravityScanner.swift" \
  "$ROOT_DIR/ConversationClean/Services/AgentScanService.swift" \
  "$SCRIPT_DIR/test_scanners.swift" \
  -o "$BIN_PATH"

echo "===> Running verification tests..."
"$BIN_PATH" "$@"
EXIT_CODE=$?

rm -f "$BIN_PATH"
exit $EXIT_CODE

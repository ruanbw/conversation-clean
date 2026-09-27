import Foundation

/// 注册表中的一条用例。
struct TestEntry {
    let name: String
    let run: () async -> Void

    init(_ name: String, _ run: @escaping () async -> Void) {
        self.name = name
        self.run = run
    }
}

/// 测试套件入口。
///
/// 数组顺序即执行顺序；新增用例只需实现 `func testXxx() async` 并在此登记一行。
@main
struct Main {
    static func main() async {
        let suite: [TestEntry] = [
            // 格式化
            TestEntry("Formatting", testFormatting),

            // Claude Code
            TestEntry("RealClaudeReadOnly", testRealClaudeCodeScannerReadOnly),
            TestEntry("MockClaudeScan", testMockClaudeCodeScanner),

            // Codex 与删除验证
            TestEntry("MockCodexScan", testMockCodexScanner),
            TestEntry("MockDeletion", testMockDeletion),

            // Cline / Roo Code / Continue.dev
            TestEntry("RealClineReadOnly", testRealClineScannerReadOnly),
            TestEntry("MockClineScan", testMockClineScanner),
            TestEntry("MockRooCodeScan", testMockRooCodeScanner),
            TestEntry("MockContinueScan", testMockContinueScanner),

            // Pi Agent
            TestEntry("RealPiReadOnly", testRealPiAgentScannerReadOnly),
            TestEntry("MockPiAgent", testMockPiAgentScanner),
            TestEntry("MockPiContextModeSync", testMockPiAgentContextModeSync),

            // 统一多 Agent 扫描
            TestEntry("UnifiedFiveAgents", testUnifiedMultiAgentScan),

            // VS Code 系 IDE
            TestEntry("RealVSCodeReadOnly", testRealVSCodeChatScannerReadOnly),
            TestEntry("MockVSCodeChat", testMockVSCodeChatScanner),
            TestEntry("MockCursor", testMockCursorScanner),
            TestEntry("MockWindsurf", testMockWindsurfScanner),
            TestEntry("MockTrae", testMockTraeScanner),

            // CLI / 编辑器 Agent
            TestEntry("RealOpenVikingReadOnly", testRealOpenVikingScannerReadOnly),
            TestEntry("MockOpenViking", testMockOpenVikingScanner),
            TestEntry("RealAiderReadOnly", testRealAiderScannerReadOnly),
            TestEntry("MockAider", testMockAiderScanner),
            TestEntry("RealZedReadOnly", testRealZedScannerReadOnly),
            TestEntry("MockZed", testMockZedScanner),
            TestEntry("RealOpenHandsReadOnly", testRealOpenHandsScannerReadOnly),
            TestEntry("MockOpenHands", testMockOpenHandsScanner),

            // Antigravity
            TestEntry("RealAntigravityReadOnly", testRealAntigravityScannerReadOnly),
            TestEntry("MockAntigravityScan", testMockAntigravityScanner),

            // state.vscdb 索引同步
            TestEntry("MockVSCDBIndexSync", testMockVSCDBIndexSync),
        ]

        let exitCode = await TestRunner.run(suite)
        exit(exitCode)
    }
}

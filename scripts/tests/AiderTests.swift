import Foundation
import SQLite3

func testRealAiderScannerReadOnly() async {
    let t = TestCase("RealAiderReadOnly", section: "Test: Real Local Aider Scanner (READ-ONLY)")

    let scanner = AiderScanner()
    t.assert(scanner.category == .aider, "Category is .aider")
    do {
        let items = try await scanner.scan()
        t.assert(true, "Aider scan() executed successfully without throwing error")
        print("  \u{001B}[34m[INFO] Scanned \(items.count) Aider sessions on current machine\u{001B}[0m")
    } catch {
        t.assert(false, "Real Aider scan threw error: \(error)")
    }
}

func testMockAiderScanner() async {
    let t = TestCase("MockAider", section: "Test: Mock Aider Scanner (Fixture Directory)")

    let fm = FileManager.default
    let tempDir = TestRunner.createTempDirectory(prefix: "mock_aider")
    defer { try? fm.removeItem(at: tempDir) }

    let projDir = tempDir.appendingPathComponent("projects/my-web-app")
    Fixture.dir(projDir)

    let chatFile = projDir.appendingPathComponent(".aider.chat.history.md")
    let inputFile = projDir.appendingPathComponent(".aider.input.history")
    let tagsFile = projDir.appendingPathComponent(".aider.tags.cache.v3")
    let confFile = projDir.appendingPathComponent(".aider.conf.yml")
    let sourceCodeFile = projDir.appendingPathComponent("App.swift")

    let chatContent = """
    # aider chat started at 2026-09-20 10:00:00

    #### Add user authentication middleware with JWT tokens
    > Applied edit to Auth.swift
    """
    Fixture.write(chatContent, to: chatFile)
    Fixture.write("git status\nadd auth middleware\n", to: inputFile)
    Fixture.write("ctags-cache-v3-binary-data", to: tagsFile)
    Fixture.write("model: gpt-4o\nauto-commits: false\n", to: confFile)
    Fixture.write("import SwiftUI\nstruct App {}\n", to: sourceCodeFile)

    let scanner = AiderScanner(storageURL: tempDir)
    t.assert(scanner.isInstalled, "Mock scanner isInstalled is true")

    do {
        let items = try await scanner.scan()
        t.assert(!items.isEmpty, "Detected project Aider item")

        if let item = items.first(where: { $0.projectPath == projDir.path }) {
            t.assert(item.category == .aider, "Item category is .aider")
            t.assert(item.title.contains("Add user authentication middleware"), "Title parsed from chat history prompt (found: '\(item.title)')")
            t.assert(item.associatedPaths.contains(chatFile.path), "associatedPaths contains .aider.chat.history.md")
            t.assert(item.associatedPaths.contains(inputFile.path), "associatedPaths contains .aider.input.history")
            t.assert(item.associatedPaths.contains(tagsFile.path), "associatedPaths contains .aider.tags.cache.v3")
            t.assert(!item.associatedPaths.contains(confFile.path), "associatedPaths does NOT contain .aider.conf.yml")
            t.assert(!item.associatedPaths.contains(sourceCodeFile.path), "associatedPaths does NOT contain user source code")

            let freed = try await scanner.delete(items: [item])
            t.assert(freed == item.sizeInBytes, "Freed size matches item size")

            t.assert(!fm.fileExists(atPath: chatFile.path), ".aider.chat.history.md removed")
            t.assert(!fm.fileExists(atPath: inputFile.path), ".aider.input.history removed")
            t.assert(!fm.fileExists(atPath: tagsFile.path), ".aider.tags.cache.v3 removed")

            t.assert(fm.fileExists(atPath: confFile.path), "SAFETY PASS: .aider.conf.yml was PRESERVED")
            t.assert(fm.fileExists(atPath: sourceCodeFile.path), "SAFETY PASS: App.swift repository code was PRESERVED")
        } else {
            t.assert(false, "Project Aider item not found")
        }

        let allFreed = try await scanner.cleanAll()
        t.assert(allFreed >= 0, "cleanAll completed safely")
    } catch {
        t.assert(false, "Mock Aider test threw error: \(error)")
    }
}

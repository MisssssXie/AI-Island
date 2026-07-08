//
//  CopilotHookInstaller.swift
//  ClaudeIsland
//
//  Installs the shared claude-island-state.py hook into the GitHub Copilot
//  CLI's hooks directory (~/.copilot/hooks, or $COPILOT_HOME/hooks) as
//  `--source copilot`.
//
//  Copilot's hook config is NOT the same schema as Claude/Codex:
//   - top-level `{"version": 1, "hooks": {...}}` wrapper
//   - each event key maps straight to an array of hook objects (no
//     matcher/hooks-array wrapping level like Claude/Codex)
//   - hook objects use `bash`/`timeoutSec` fields instead of `command`/`timeout`
//   - Copilot supports multiple independent files under hooks/*.json, so we
//     own ONE dedicated file exclusively and can overwrite/delete it wholesale
//     without HooksFileMerger-style merge-preserving-other-tools'-hooks logic.
//  Copilot's hook payloads also carry no single event-name field, so each
//  entry's command bakes in `--event <name>` itself (the script reads it back
//  via argv instead of a JSON field).
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "CopilotHooks")

enum CopilotHookInstaller {

    private static let hookFileName = "claude-island.json"

    // MARK: - Install

    /// Write/refresh our hooks file in the Copilot home, if one exists.
    /// Never throws — a failure here must not block Claude/Codex install or crash.
    static func installIfNeeded() {
        guard let home = copilotHome() else {
            logger.debug("No Copilot home found; skipping Copilot hook install")
            return
        }
        installHooks(at: home)
    }

    private static func installHooks(at home: URL) {
        let dir = hooksDir(for: home)
        let hooksFile = dir.appendingPathComponent(hookFileName)

        var hooks: [String: Any] = [:]
        for (event, entry) in hookEntries() {
            hooks[event] = [entry]
        }
        let json: [String: Any] = ["version": 1, "hooks": hooks]

        guard let newData = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        // We own this file exclusively, so a byte-for-byte diff is enough to
        // skip a no-op rewrite (unlike Codex, no other tool's hooks share it).
        if let oldData = try? Data(contentsOf: hooksFile), oldData == newData {
            logger.debug("Copilot hooks unchanged at \(hooksFile.path, privacy: .public)")
            return
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try newData.write(to: hooksFile)
            logger.info("Installed Copilot hooks at \(hooksFile.path, privacy: .public)")
        } catch {
            logger.error("Failed to write Copilot hooks at \(hooksFile.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The events we drive phase detection and approvals from — the same
    /// scope as CodexHookInstaller's verified-working event set, translated
    /// to Copilot's camelCase names.
    private static func hookEntries() -> [(String, [String: Any])] {
        [
            ("sessionStart",        hookEntry(event: "sessionStart", timeout: 5)),
            ("userPromptSubmitted", hookEntry(event: "userPromptSubmitted", timeout: 5)),
            ("preToolUse",          hookEntry(event: "preToolUse", timeout: 5)),
            ("permissionRequest",   hookEntry(event: "permissionRequest", timeout: 7200)),
            ("postToolUse",         hookEntry(event: "postToolUse", timeout: 5)),
            ("agentStop",           hookEntry(event: "agentStop", timeout: 5)),
            ("sessionEnd",          hookEntry(event: "sessionEnd", timeout: 5)),
        ]
    }

    private static func hookEntry(event: String, timeout: Int) -> [String: Any] {
        ["type": "command", "bash": command(for: event), "timeoutSec": timeout]
    }

    /// `python3 '<abs>/claude-island-state.py' --source copilot --event <name>`.
    private static func command(for event: String) -> String {
        "\(HookInstaller.detectPython()) \(ClaudePaths.hookScriptShellPath) --source copilot --event \(event)"
    }

    // MARK: - Uninstall / status

    /// Remove our dedicated hooks file. Safe even if other Copilot hook files exist.
    static func uninstall() {
        guard let home = copilotHome() else { return }
        try? FileManager.default.removeItem(at: hooksDir(for: home).appendingPathComponent(hookFileName))
    }

    static func isInstalled() -> Bool {
        guard let home = copilotHome() else { return false }
        return FileManager.default.fileExists(atPath: hooksDir(for: home).appendingPathComponent(hookFileName).path)
    }

    // MARK: - Home discovery

    private static func hooksDir(for home: URL) -> URL {
        home.appendingPathComponent("hooks")
    }

    /// $COPILOT_HOME if set and present, else ~/.copilot if it exists.
    private static func copilotHome() -> URL? {
        let fm = FileManager.default

        if let envHome = Foundation.ProcessInfo.processInfo.environment["COPILOT_HOME"], !envHome.isEmpty {
            let url = URL(fileURLWithPath: (envHome as NSString).expandingTildeInPath)
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }

        let defaultHome = fm.homeDirectoryForCurrentUser.appendingPathComponent(".copilot")
        return fm.fileExists(atPath: defaultHome.path) ? defaultHome : nil
    }
}

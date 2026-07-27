//
//  CodexHookInstaller.swift
//  ClaudeIsland
//
//  Installs the shared claude-island-state.py hook into every Codex home
//  (~/.codex, ~/.codex-work, $CODEX_HOME, ...) as `--source codex`.
//
//  Codex hooks.json is the same schema as Claude's settings.json hooks block,
//  so this mirrors HookInstaller but:
//   - discovers and writes to ALL Codex homes (multi-account desktop app)
//   - points at the SAME script file (installed once by HookInstaller) with
//     `--source codex`, so we don't ship a second copy
//   - keeps the command string STABLE (absolute path, fixed args, no version)
//     so Codex's trusted_hash stays valid across app updates (plan §5.2)
//   - detects whether the user has trusted our hooks yet (plan §2.6)
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "CodexHooks")

enum CodexHookInstaller {

    /// Marker used to identify our own hook entries when merging shared files.
    private static let scriptMarker = "claude-island-state.py"

    // MARK: - Install

    /// Discover every Codex home and install/refresh our hooks there.
    /// Never throws — a failure in one home must not block Claude install or crash.
    static func installIfNeeded() {
        let version = detectCodexVersion()
        if let version, version < CodexVersion(major: 0, minor: 140, patch: 0) {
            logger.info("Codex \(version.description, privacy: .public) predates hooks; writing anyway (older codex ignores hooks.json)")
        }

        let command = hookCommand()
        let homes = discoverCodexHomes()
        guard !homes.isEmpty else {
            logger.debug("No Codex homes found; skipping Codex hook install")
            return
        }

        for home in homes {
            installHooks(at: home, command: command)
        }
    }

    /// The stable hook command string: `python3 '<abs>/claude-island-state.py' --source codex`.
    private static func hookCommand() -> String {
        "\(HookInstaller.detectPython()) \(ClaudePaths.hookScriptShellPath) --source codex"
    }

    private static func installHooks(at home: URL, command: String) {
        let hooksFile = home.appendingPathComponent("hooks.json")

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: hooksFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        // Strip any prior Claude Island entries from every event (idempotent
        // re-install), preserving OTHER tools' hooks untouched (plan §5.2).
        var hooks = HooksFileMerger.stripMarkedHooks(from: json["hooks"] as? [String: Any] ?? [:], marker: scriptMarker)

        // Append our entries for the verified-working Codex event set.
        for (event, entry) in hookEvents(command: command) {
            let existing = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = existing + [entry]
        }

        json["hooks"] = hooks

        // Diff before writing — an unchanged file must not be rewritten, or
        // Codex would drop the trusted_hash and re-prompt for trust (plan §5.2).
        guard let newData = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        if let oldData = try? Data(contentsOf: hooksFile),
           let oldObj = try? JSONSerialization.jsonObject(with: oldData),
           let oldNormalized = try? JSONSerialization.data(withJSONObject: oldObj, options: [.prettyPrinted, .sortedKeys]),
           oldNormalized == newData {
            logger.debug("Codex hooks.json unchanged at \(home.lastPathComponent, privacy: .public)")
            return
        }

        do {
            try newData.write(to: hooksFile)
            logger.info("Installed Codex hooks at \(home.path, privacy: .public)")
        } catch {
            logger.error("Failed to write Codex hooks at \(home.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ordered (event, entry) pairs for Codex. PermissionRequest wants a long
    /// timeout (user may take a while to decide); the rest are quick.
    private static func hookEvents(command: String) -> [(String, [String: Any])] {
        [
            ("SessionStart",     hookEntry(command: command, timeout: 5,    matcher: nil)),
            ("UserPromptSubmit", hookEntry(command: command, timeout: 5,    matcher: nil)),
            ("PreToolUse",       hookEntry(command: command, timeout: 5,    matcher: "")),
            ("PermissionRequest", hookEntry(command: command, timeout: 7260, matcher: nil)),
            ("PostToolUse",      hookEntry(command: command, timeout: 5,    matcher: "")),
            ("Stop",             hookEntry(command: command, timeout: 5,    matcher: nil)),
        ]
    }

    private static func hookEntry(command: String, timeout: Int, matcher: String?) -> [String: Any] {
        var entry: [String: Any] = [
            "hooks": [["type": "command", "command": command, "timeout": timeout]]
        ]
        if let matcher {
            entry["matcher"] = matcher
        }
        return entry
    }

    // MARK: - Uninstall / status

    /// Remove our hooks from every Codex home. Leaves other tools' hooks intact.
    static func uninstall() {
        for home in discoverCodexHomes() {
            HooksFileMerger.uninstall(fileURL: home.appendingPathComponent("hooks.json"), marker: scriptMarker)
        }
    }

    /// Whether our hook is present in any Codex home.
    static func isInstalled() -> Bool {
        discoverCodexHomes().contains { installedInHome($0.appendingPathComponent("hooks.json")) }
    }

    /// True when our hooks are installed in at least one home but not yet trusted
    /// there. Best-effort: Codex records `[hooks.state."<home>/hooks.json:..."]`
    /// entries in config.toml only after the user runs `/hooks` and trusts them.
    /// We do NOT compute trusted_hash ourselves (undocumented; plan §2.6).
    static func needsTrustApproval() -> Bool {
        for home in discoverCodexHomes() {
            let hooksFile = home.appendingPathComponent("hooks.json")
            guard installedInHome(hooksFile) else { continue }

            let configFile = home.appendingPathComponent("config.toml")
            guard let toml = try? String(contentsOf: configFile, encoding: .utf8) else {
                // Hooks installed but no config.toml at all -> definitely untrusted.
                return true
            }
            // Look for a trust-state marker keyed to THIS home's hooks.json.
            let marker = "\(hooksFile.path):"
            if !toml.contains(marker) {
                return true
            }
        }
        return false
    }

    private static func installedInHome(_ hooksFile: URL) -> Bool {
        guard let data = try? Data(contentsOf: hooksFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }
        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in entryHooks where (hook["command"] as? String)?.contains(scriptMarker) == true {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Home discovery

    /// All Codex homes: $CODEX_HOME plus every `~/.codex*` directory that looks
    /// like a real Codex home (has config.toml or sessions/).
    static func discoverCodexHomes() -> [URL] {
        let fm = FileManager.default
        var homes: [URL] = []
        var seen = Set<String>()

        func consider(_ url: URL) {
            let standardized = url.standardizedFileURL
            let path = standardized.path
            guard !seen.contains(path) else { return }
            guard isCodexHome(standardized) else { return }
            seen.insert(path)
            homes.append(standardized)
        }

        if let envHome = Foundation.ProcessInfo.processInfo.environment["CODEX_HOME"], !envHome.isEmpty {
            consider(URL(fileURLWithPath: (envHome as NSString).expandingTildeInPath))
        }

        let home = fm.homeDirectoryForCurrentUser
        if let entries = try? fm.contentsOfDirectory(atPath: home.path) {
            for name in entries where name == ".codex" || name.hasPrefix(".codex-") {
                consider(home.appendingPathComponent(name))
            }
        }

        return homes
    }

    private static func isCodexHome(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let hasConfig = fm.fileExists(atPath: url.appendingPathComponent("config.toml").path)
        let hasSessions = fm.fileExists(atPath: url.appendingPathComponent("sessions").path)
        return hasConfig || hasSessions
    }

    // MARK: - Version detection (log-only; never blocks install, plan §5.8)

    typealias CodexVersion = SemanticVersion

    static func detectCodexVersion() -> CodexVersion? {
        SemanticVersion.detect(candidates: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex",
            "/usr/bin/codex",
        ])
    }
}

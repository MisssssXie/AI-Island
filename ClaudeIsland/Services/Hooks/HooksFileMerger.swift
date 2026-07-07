//
//  HooksFileMerger.swift
//  ClaudeIsland
//
//  Shared read-merge-strip-write logic for hook config files. Claude's
//  settings.json and Codex's hooks.json share the same
//  `{"hooks": {"<Event>": [{"matcher": ..., "hooks": [{"type": "command", "command": ...}]}]}}`
//  shape, so both installers merge/strip entries the same way — only the
//  file path and the set of events they write differ.
//

import Foundation

enum HooksFileMerger {

    /// True if a hook entry whose command contains `marker` exists anywhere in `fileURL`.
    static func isInstalled(at fileURL: URL, marker: String) -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }
        return containsMarkedHook(in: hooks, marker: marker)
    }

    private static func containsMarkedHook(in hooks: [String: Any], marker: String) -> Bool {
        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { continue }
                for hook in entryHooks where (hook["command"] as? String)?.contains(marker) == true {
                    return true
                }
            }
        }
        return false
    }

    /// Removes any hook whose command contains `marker` from a single matcher entry.
    /// Returns nil if the entry has no hooks left, so the caller can drop it.
    static func removingMarkedHooks(from entry: [String: Any], marker: String) -> [String: Any]? {
        guard var entryHooks = entry["hooks"] as? [[String: Any]] else {
            return entry
        }
        entryHooks.removeAll { ($0["command"] as? String)?.contains(marker) == true }
        guard !entryHooks.isEmpty else { return nil }
        var updated = entry
        updated["hooks"] = entryHooks
        return updated
    }

    /// Strips marked hooks from every event in `hooks`, dropping events left with no entries.
    static func stripMarkedHooks(from hooks: [String: Any], marker: String) -> [String: Any] {
        var cleaned: [String: Any] = [:]
        for (event, value) in hooks {
            if let entries = value as? [[String: Any]] {
                let survivors = entries.compactMap { removingMarkedHooks(from: $0, marker: marker) }
                if !survivors.isEmpty {
                    cleaned[event] = survivors
                }
            } else {
                cleaned[event] = value
            }
        }
        return cleaned
    }

    /// Reads `fileURL`, strips every hook entry matching `marker`, and writes the
    /// result back. Leaves the file untouched if it doesn't parse as hooks JSON.
    static func uninstall(fileURL: URL, marker: String) {
        guard let data = try? Data(contentsOf: fileURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return
        }

        let cleaned = stripMarkedHooks(from: hooks, marker: marker)
        if cleaned.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = cleaned
        }

        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: fileURL)
        }
    }
}

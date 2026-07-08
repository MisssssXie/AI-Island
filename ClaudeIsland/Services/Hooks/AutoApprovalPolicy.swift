//
//  AutoApprovalPolicy.swift
//  ClaudeIsland
//
//  Decides whether a PermissionRequest should be auto-approved by the app
//  instead of surfacing an approval prompt in the notch. Applies to both
//  Claude and Codex (they share the same socket decision path).
//
//  SECURITY: the deny-list is a coarse safety net, NOT a security boundary —
//  it is trivially bypassed (chained/encoded/indirect commands). `.all` means
//  "trust the agent to run anything". Default is `.off` (plan §5.7).
//

import Foundation

/// Global auto-approval posture.
enum AutoApprovalMode: String, Codable, CaseIterable, Sendable {
    /// Every tool goes through manual approval (current behaviour).
    case off
    /// Only read-only / safe tools are auto-approved.
    case safeTools
    /// Everything auto-approves, except commands matching the deny-list.
    case all

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .safeTools: return "Safe tools"
        case .all: return "All"
        }
    }
}

enum AutoApprovalPolicy {

    /// Default deny-list (regular expressions). Editable via Settings.
    static let defaultDenyPatterns: [String] = [
        #"\bsudo\b"#,
        #"rm\s+-rf\s+/"#,
        #"git\s+push\s+.*--force"#,
        #">\s*/dev/"#,
        #"\bmkfs\b"#,
    ]

    /// Claude read-only / safe tools. Codex has no equivalent read-only tools
    /// (it drives everything through exec_command), so its safe set is empty —
    /// in `.safeTools` mode Codex never auto-approves.
    private static let claudeSafeTools: Set<String> = [
        "Read", "Glob", "Grep", "WebFetch", "WebSearch", "TodoWrite",
        "NotebookRead", "BashOutput",
    ]

    /// Pure decision function. `true` = auto-approve; `false` = prompt as usual.
    static func shouldAutoApprove(
        source: AgentSource,
        tool: String?,
        toolInput: [String: AnyCodable]?,
        mode: AutoApprovalMode,
        denyPatterns: [String]
    ) -> Bool {
        switch mode {
        case .off:
            return false

        case .safeTools:
            guard let tool else { return false }
            switch source {
            case .claude: return claudeSafeTools.contains(tool)
            case .codex, .copilot: return false
            }

        case .all:
            // Deny-list hit -> fall back to manual approval (NOT auto-deny).
            if let command = commandString(from: toolInput), matchesAny(command, patterns: denyPatterns) {
                return false
            }
            return true
        }
    }

    /// Extract a command-like string from tool input for deny-list matching.
    /// Claude Bash uses `command`; Codex exec_command uses `cmd` (string or array).
    static func commandString(from toolInput: [String: AnyCodable]?) -> String? {
        guard let input = toolInput else { return nil }
        for key in ["command", "cmd"] {
            guard let value = input[key]?.value else { continue }
            if let str = value as? String {
                return str
            }
            if let arr = value as? [Any] {
                return arr.compactMap { $0 as? String }.joined(separator: " ")
            }
        }
        return nil
    }

    private static func matchesAny(_ text: String, patterns: [String]) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let regex = compiledRegex(pattern) else { continue }
            if regex.firstMatch(in: text, range: range) != nil {
                return true
            }
        }
        return false
    }

    // Deny-list patterns are stable strings — compile each once and reuse.
    private static let regexCacheLock = NSLock()
    private nonisolated(unsafe) static var regexCache: [String: NSRegularExpression] = [:]

    private static func compiledRegex(_ pattern: String) -> NSRegularExpression? {
        regexCacheLock.lock()
        defer { regexCacheLock.unlock() }
        if let cached = regexCache[pattern] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        regexCache[pattern] = regex
        return regex
    }
}

//
//  AgentSource.swift
//  ClaudeIsland
//
//  Identifies which agent a session belongs to (Claude Code vs OpenAI Codex)
//  and, for Codex, which host launched it. Kept intentionally tiny so it can be
//  used from any isolation context.
//

import Foundation

/// Which agent produced a session. Defaults to `.claude` so existing Claude
/// code paths (and payloads without a `source` field) are unaffected.
enum AgentSource: String, Codable, Sendable, Equatable {
    case claude
    case codex

    /// Decode from the optional `source` field on a hook payload.
    /// nil / unknown → `.claude` (preserves legacy behaviour).
    static func from(_ raw: String?) -> AgentSource {
        guard let raw else { return .claude }
        return AgentSource(rawValue: raw) ?? .claude
    }
}

/// Which Codex entry point hosts a session. Only meaningful when
/// `AgentSource == .codex`.
enum CodexHost: String, Codable, Sendable, Equatable {
    /// Interactive terminal (`codex` TUI). Has a real tty; pid dies on exit.
    case cli
    /// Codex desktop app (`/Applications/Codex.app`). Long-lived engine pid.
    case desktop
    /// VS Code extension host.
    case vscode
    /// Non-interactive `codex exec`.
    case exec

    static func from(_ raw: String?) -> CodexHost? {
        guard let raw else { return nil }
        return CodexHost(rawValue: raw)
    }

    /// Display suffix for the source badge, e.g. "codex · desktop".
    var badgeLabel: String {
        switch self {
        case .cli: return "codex · cli"
        case .desktop: return "codex · desktop"
        case .vscode: return "codex · vscode"
        case .exec: return "codex · exec"
        }
    }

    /// Whether this host has a per-session process that dies when the session
    /// ends (so the pid-liveness check can archive it). Desktop/vscode share a
    /// long-lived engine pid and need idle-timeout archiving instead.
    var hasEphemeralProcess: Bool {
        self == .cli || self == .exec
    }
}

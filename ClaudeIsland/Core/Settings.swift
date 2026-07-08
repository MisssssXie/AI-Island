//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let claudeDirectoryName = "claudeDirectoryName"
        static let enableCodexDetection = "enableCodexDetection"
        static let enableCopilotDetection = "enableCopilotDetection"
        static let autoApprovalMode = "autoApprovalMode"
        static let autoApproveDenyPatterns = "autoApproveDenyPatterns"
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Claude Directory

    /// The name of the Claude config directory under the user's home folder.
    /// Defaults to ".claude" (standard Claude Code installation).
    /// Change to ".claude-internal" (or similar) for enterprise/custom distributions.
    static var claudeDirectoryName: String {
        get {
            let value = defaults.string(forKey: Keys.claudeDirectoryName) ?? ""
            return value.isEmpty ? ".claude" : value
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.claudeDirectoryName)
        }
    }

    // MARK: - Codex Detection

    /// Whether to detect and display OpenAI Codex sessions.
    /// Defaults to on when a `~/.codex` directory exists on first launch.
    static var enableCodexDetection: Bool {
        get {
            if let value = defaults.object(forKey: Keys.enableCodexDetection) as? Bool {
                return value
            }
            return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.codex")
        }
        set {
            defaults.set(newValue, forKey: Keys.enableCodexDetection)
        }
    }

    // MARK: - Copilot Detection

    /// Whether to detect and display GitHub Copilot CLI sessions.
    /// Defaults to on when a `~/.copilot` directory exists on first launch.
    static var enableCopilotDetection: Bool {
        get {
            if let value = defaults.object(forKey: Keys.enableCopilotDetection) as? Bool {
                return value
            }
            return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.copilot")
        }
        set {
            defaults.set(newValue, forKey: Keys.enableCopilotDetection)
        }
    }

    // MARK: - Auto Approval

    /// Global auto-approval posture. Defaults to `.off` (all manual).
    static var autoApprovalMode: AutoApprovalMode {
        get {
            guard let raw = defaults.string(forKey: Keys.autoApprovalMode),
                  let mode = AutoApprovalMode(rawValue: raw) else {
                return .off
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.autoApprovalMode)
        }
    }

    /// Regex deny-list applied in `.all` mode; a hit falls back to manual approval.
    static var autoApproveDenyPatterns: [String] {
        get {
            defaults.stringArray(forKey: Keys.autoApproveDenyPatterns)
                ?? AutoApprovalPolicy.defaultDenyPatterns
        }
        set {
            defaults.set(newValue, forKey: Keys.autoApproveDenyPatterns)
        }
    }
}

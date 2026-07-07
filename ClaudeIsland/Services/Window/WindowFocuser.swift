//
//  WindowFocuser.swift
//  ClaudeIsland
//
//  Focuses windows using yabai or native macOS APIs
//

import AppKit
import Foundation

/// Focuses windows using yabai or native macOS APIs
actor WindowFocuser {
    static let shared = WindowFocuser()

    private init() {}

    /// Focus a window by ID (yabai)
    func focusWindow(id: Int) async -> Bool {
        guard let yabaiPath = await WindowFinder.shared.getYabaiPath() else { return false }

        do {
            _ = try await ProcessExecutor.shared.run(yabaiPath, arguments: [
                "-m", "window", "--focus", String(id)
            ])
            return true
        } catch {
            return false
        }
    }

    /// Focus the tmux window for a terminal (yabai)
    func focusTmuxWindow(terminalPid: Int, windows: [YabaiWindow]) async -> Bool {
        // Try to find actual tmux window
        if let tmuxWindow = WindowFinder.shared.findTmuxWindow(forTerminalPid: terminalPid, windows: windows) {
            return await focusWindow(id: tmuxWindow.id)
        }

        // Fall back to any non-Claude window
        if let window = WindowFinder.shared.findNonClaudeWindow(forTerminalPid: terminalPid, windows: windows) {
            return await focusWindow(id: window.id)
        }

        return false
    }

    /// Focus the terminal app for a Claude session using native macOS APIs (no yabai needed)
    /// Uses Accessibility API to raise the specific window matching the project.
    func focusTerminalNatively(forClaudePid claudePid: Int, projectName: String? = nil, cwd: String? = nil) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()

        // For tmux sessions, switch to the correct pane first
        if ProcessTreeBuilder.shared.isInTmux(pid: claudePid, tree: tree) {
            if let target = await TmuxController.shared.findTmuxTarget(forClaudePid: claudePid) {
                _ = await TmuxController.shared.switchToPane(target: target)
            }
        }

        // Find the terminal/editor app
        let runningApps = NSWorkspace.shared.runningApplications
        var targetApp: NSRunningApplication?

        for app in runningApps {
            guard let bundleId = app.bundleIdentifier,
                  TerminalAppRegistry.isTerminalBundle(bundleId) else { continue }

            let appPid = Int(app.processIdentifier)
            if ProcessTreeBuilder.shared.isDescendant(targetPid: claudePid, ofAncestor: appPid, tree: tree) {
                targetApp = app
                break
            }
        }

        // Fallback: walk up process tree
        if targetApp == nil, let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: claudePid, tree: tree) {
            targetApp = NSRunningApplication(processIdentifier: pid_t(terminalPid))
        }

        guard let app = targetApp else {
            print("[WindowFocuser] No target app found for claudePid: \(claudePid)")
            return false
        }

        // Build search terms
        let folderName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        let searchTerms = [projectName, folderName].compactMap { $0?.lowercased() }

        print("[WindowFocuser] Focusing: app=\(app.localizedName ?? "?"), pid=\(claudePid), searchTerms=\(searchTerms), projectName=\(projectName ?? "nil"), cwd=\(cwd ?? "nil")")

        // Strategies A/B: raise the specific window via AppleScript, then AX.
        if await raiseWindow(forApp: app, searchTerms: searchTerms) {
            return true
        }

        // Strategy C: editors (VS Code & friends) accept a folder via
        // LaunchServices — opening an already-open folder raises that project's
        // window. Unlike A/B this needs no Automation/Accessibility permission.
        if let cwd,
           let bundleId = app.bundleIdentifier,
           TerminalAppRegistry.isEditorBundle(bundleId),
           let bundleURL = app.bundleURL {
            print("[WindowFocuser] Trying Strategy C (open project folder in editor)...")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            do {
                _ = try await NSWorkspace.shared.open(
                    [URL(fileURLWithPath: cwd, isDirectory: true)],
                    withApplicationAt: bundleURL,
                    configuration: config
                )
                print("[WindowFocuser] Strategy C succeeded")
                return true
            } catch {
                print("[WindowFocuser] Strategy C failed: \(error)")
            }
        }

        // Strategy D: Just activate the app
        print("[WindowFocuser] Falling back to Strategy D (activate app)")
        activateApp(app)
        return true
    }

    /// Focus the terminal for a session by working directory (fallback when no PID)
    func focusTerminalNatively(forWorkingDirectory cwd: String, projectName: String? = nil) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()

        for (pid, info) in tree {
            let command = info.command.lowercased()
            guard command.contains("claude") || command.contains("codex") else { continue }
            guard let processCwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: pid),
                  processCwd == cwd else { continue }

            return await focusTerminalNatively(forClaudePid: pid, projectName: projectName, cwd: cwd)
        }

        return false
    }

    /// Focus the GUI app hosting an agent session (Codex desktop / VS Code extension).
    ///
    /// These sessions run inside an editor/Electron app, not a terminal, so there
    /// is no tty to chase — but we still know the project folder.
    /// 1. Resolve the hosting app: walk up the session pid's process tree to the
    ///    first regular app, falling back to a running app matching `bundleIdentifiers`.
    /// 2. Raise the window whose title matches the project (AppleScript, then AX).
    /// 3. If no window matched and `openProjectURL` is set, open that folder with
    ///    the app — VS Code focuses the existing window for an already-open folder,
    ///    or opens the project fresh. Needs no Automation/Accessibility permission.
    /// 4. Last resort: just activate the app.
    func focusGUIApp(
        sessionPid: Int?,
        bundleIdentifiers: [String],
        searchTerms: [String],
        openProjectURL: URL?
    ) async -> Bool {
        let app = hostingApp(forSessionPid: sessionPid, bundleIdentifiers: bundleIdentifiers)
        print("[WindowFocuser] focusGUIApp: app=\(app?.localizedName ?? "nil"), pid=\(sessionPid ?? -1), searchTerms=\(searchTerms), openProjectURL=\(openProjectURL?.path ?? "nil")")

        if let app, await raiseWindow(forApp: app, searchTerms: searchTerms) {
            return true
        }

        if let openProjectURL,
           let bundleURL = app?.bundleURL ?? bundleIdentifiers.lazy
               .compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
               .first {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            do {
                _ = try await NSWorkspace.shared.open([openProjectURL], withApplicationAt: bundleURL, configuration: config)
                return true
            } catch {
                print("[WindowFocuser] open project with app failed: \(error)")
            }
        }

        if let app {
            activateApp(app)
            return true
        }
        return false
    }

    /// Resolve the GUI app hosting a session: first regular app in the pid's
    /// ancestor chain (exact instance, handles VS Code forks), else any running
    /// app matching the expected bundle ids.
    private nonisolated func hostingApp(forSessionPid sessionPid: Int?, bundleIdentifiers: [String]) -> NSRunningApplication? {
        if let sessionPid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            let ancestor = ProcessTreeBuilder.shared.findFirstAncestor(of: sessionPid, tree: tree) { candidate in
                NSRunningApplication(processIdentifier: pid_t(candidate))?.activationPolicy == .regular
            }
            if let ancestor {
                return NSRunningApplication(processIdentifier: pid_t(ancestor))
            }
        }

        for bundleId in bundleIdentifiers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                return app
            }
        }
        return nil
    }

    // MARK: - App Activation

    /// Activate an app reliably on macOS 14+.
    /// Uses NSWorkspace.openApplication which works even from a non-activating panel.
    private func activateApp(_ app: NSRunningApplication) {
        guard let bundleURL = app.bundleURL else {
            app.activate()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, error in
            if let error = error {
                print("[WindowFocuser] NSWorkspace.openApplication failed: \(error), falling back to activate()")
                app.activate()
            }
        }
    }

    // MARK: - AppleScript Window Raising

    /// Raise a specific window using AppleScript via System Events.
    /// This is the most reliable method for switching between windows in VS Code, Cursor, etc.
    /// Targets the process by unix id when available — System Events process names
    /// come from the executable (VS Code is "Code", not "Visual Studio Code"), so
    /// name lookups are unreliable across apps.
    private func raiseWindowViaAppleScript(processId: Int?, appName: String?, searchTerms: [String]) async -> Bool {
        let processSelector: String
        if let processId {
            processSelector = "first application process whose unix id is \(processId)"
        } else if let appName {
            processSelector = "process \"\(appName)\""
        } else {
            return false
        }

        // Build AppleScript that finds and raises the window matching our search terms
        // We check each window's name against all search terms
        let conditions = searchTerms.map { term in
            "name of w contains \"\(term)\""
        }.joined(separator: " or ")

        let script = """
        tell application "System Events"
            tell (\(processSelector))
                set frontmost to true
                repeat with w in windows
                    if \(conditions) then
                        perform action "AXRaise" of w
                        return true
                    end if
                end repeat
            end tell
        end tell
        return false
        """

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let appleScript = NSAppleScript(source: script)
                var error: NSDictionary?
                let result = appleScript?.executeAndReturnError(&error)
                if let error = error {
                    let number = error[NSAppleScript.errorNumber] ?? "?"
                    let message = error[NSAppleScript.errorMessage] ?? error[NSAppleScript.errorBriefMessage] ?? ""
                    print("[WindowFocuser] AppleScript error \(number): \(message) (-1743 = Automation permission not granted)")
                }
                let success = result?.booleanValue ?? false
                print("[WindowFocuser] AppleScript result: \(success), process: \(appName ?? String(processId ?? -1)), searchTerms: \(searchTerms)")
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - Combined Window Raising

    /// Raise the app's window matching `searchTerms`: AppleScript via System
    /// Events first (most reliable for VS Code, Cursor, Terminal), falling
    /// back to the Accessibility API. Returns false if neither found a match.
    private func raiseWindow(forApp app: NSRunningApplication, searchTerms: [String]) async -> Bool {
        if !searchTerms.isEmpty {
            print("[WindowFocuser] Trying AppleScript raise...")
            if await raiseWindowViaAppleScript(
                processId: Int(app.processIdentifier),
                appName: app.localizedName,
                searchTerms: searchTerms
            ) {
                print("[WindowFocuser] AppleScript raise succeeded")
                return true
            }
            print("[WindowFocuser] AppleScript raise failed")
        }

        print("[WindowFocuser] Trying AX raise...")
        guard raiseWindowViaAX(forApp: app, searchTerms: searchTerms) else {
            print("[WindowFocuser] AX raise failed")
            return false
        }
        print("[WindowFocuser] AX raise succeeded")
        activateApp(app)
        return true
    }

    // MARK: - Accessibility API Window Raising (Fallback)

    /// Raise a specific window of an app by matching the project name in the window title.
    /// Uses the Accessibility API (requires Accessibility permission).
    private nonisolated func raiseWindowViaAX(forApp app: NSRunningApplication, searchTerms: [String]) -> Bool {
        guard !searchTerms.isEmpty else { return false }

        let appPid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(appPid)

        // Get the app's windows
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            return false
        }

        // Find the window whose title matches
        for window in windows {
            var titleRef: CFTypeRef?
            let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            guard titleResult == .success, let title = titleRef as? String else { continue }

            let titleLower = title.lowercased()
            for term in searchTerms {
                if titleLower.contains(term) {
                    // Raise this window
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    return true
                }
            }
        }

        return false
    }
}

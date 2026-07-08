import AppKit
import Sparkle
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private var updateCheckTimer: Timer?
    private var hideShortcutMonitor: HideShortcutMonitor?

    static var shared: AppDelegate?
    let updater: SPUUpdater
    private let userDriver: NotchUserDriver

    var windowController: NotchWindowController? {
        windowManager?.windowController
    }

    override init() {
        userDriver = NotchUserDriver()
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: nil
        )
        super.init()
        AppDelegate.shared = self

        do {
            try updater.start()
        } catch {
            print("Failed to start Sparkle updater: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        HookInstaller.installIfNeeded()
        // Resolve the (possibly filesystem-derived) default once and persist it,
        // so later reads — e.g. every publishState — hit a stored bool instead of
        // re-stat'ing ~/.codex.
        let codexEnabled = AppSettings.enableCodexDetection
        AppSettings.enableCodexDetection = codexEnabled
        if codexEnabled {
            // Codex install spawns `codex --version` + `which python3` and scans/
            // writes every home — keep it off the launch path (plan §5.8).
            DispatchQueue.global(qos: .utility).async {
                CodexHookInstaller.installIfNeeded()
            }
        }
        let copilotEnabled = AppSettings.enableCopilotDetection
        AppSettings.enableCopilotDetection = copilotEnabled
        if copilotEnabled {
            DispatchQueue.global(qos: .utility).async {
                CopilotHookInstaller.installIfNeeded()
            }
        }
        NSApplication.shared.setActivationPolicy(.accessory)

        windowManager = WindowManager()
        _ = windowManager?.setupNotchWindow()

        screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }

        // Control+Option + triple-tap "x" (⌃⌥X ×2) hides / shows the island
        // (same as the minimize button), so it stops covering web content when
        // you need the space.
        hideShortcutMonitor = HideShortcutMonitor { [weak self] in
            self?.toggleIslandHidden()
        }
        hideShortcutMonitor?.start()

        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        }

        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let updater = self?.updater, updater.canCheckForUpdates else { return }
            updater.checkForUpdates()
        }
    }

    private func handleScreenChange() {
        _ = windowManager?.setupNotchWindow()
    }

    /// Flip the island's manual-hide flag (reuses the minimize-button flag).
    /// NSEvent monitor callbacks are delivered on the main thread, so it's safe
    /// to touch the @MainActor view model here.
    private func toggleIslandHidden() {
        guard let viewModel = windowController?.viewModel else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if viewModel.isManuallyHidden {
                viewModel.isManuallyHidden = false
            } else {
                viewModel.notchClose()
                viewModel.isManuallyHidden = true
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateCheckTimer?.invalidate()
        screenObserver = nil
        hideShortcutMonitor?.stop()
        hideShortcutMonitor = nil
    }

    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.farouqaldori.ClaudeIsland"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }
}

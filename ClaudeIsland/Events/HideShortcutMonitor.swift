//
//  HideShortcutMonitor.swift
//  ClaudeIsland
//
//  Registers a system-wide ⌃⌥X hot key and toggles the island after three
//  quick presses (⌃⌥X ⌃⌥X ⌃⌥X). Uses Carbon's RegisterEventHotKey so it fires
//  no matter which app is focused and needs NO Accessibility permission
//  (a global NSEvent key monitor would silently do nothing until the app is
//  trusted for Accessibility).
//
//  ⌃⌥X (Control+Option+X) is essentially never bound by macOS or apps, so
//  consuming it system-wide is safe. Change `hotKeyCode` / `hotKeyModifiers`
//  below to pick a different combo.
//

import AppKit
import Carbon.HIToolbox

final class HideShortcutMonitor {
    /// Max time allowed between consecutive presses to still count as a streak.
    private let maxGap: TimeInterval = 0.6
    /// Number of presses required to trigger the toggle.
    private let requiredCount = 2
    /// Virtual key code of the hot key. kVK_ANSI_X ("x").
    private let hotKeyCode = UInt32(kVK_ANSI_X)
    /// Modifier(s) that must be held. `controlKey | optionKey` == ⌃⌥.
    private let hotKeyModifiers = UInt32(controlKey | optionKey)

    private let onTriggered: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var count = 0
    private var lastPressAt: Date?

    init(onTriggered: @escaping () -> Void) {
        self.onTriggered = onTriggered
    }

    func start() {
        guard hotKeyRef == nil else { return }

        // Handle "hot key pressed" events on the application event target;
        // Carbon delivers these on the main thread.
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let monitor = Unmanaged<HideShortcutMonitor>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.handleHotKey() }
                return noErr
            },
            1,
            &spec,
            context,
            &handlerRef
        )

        // Register the hot key system-wide.
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(
            hotKeyCode,
            hotKeyModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    deinit {
        stop()
    }

    // MARK: - Handling

    private func handleHotKey() {
        let now = Date()
        if let last = lastPressAt, now.timeIntervalSince(last) <= maxGap {
            count += 1
        } else {
            count = 1
        }
        lastPressAt = now

        if count >= requiredCount {
            reset()
            onTriggered()
        }
    }

    private func reset() {
        count = 0
        lastPressAt = nil
    }

    /// Four-char code ('AILD') tagging our hot key registration.
    private static let signature = OSType(0x4149_4C44)
}

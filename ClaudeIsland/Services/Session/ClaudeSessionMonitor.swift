//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    private var cancellables = Set<AnyCancellable>()

    /// Hook events must reach `SessionStore` in the exact order the socket
    /// delivered them. Wrapping each in its own `Task { await process(…) }`
    /// let them enter the actor out of order: e.g. a `PostToolUse` applied
    /// *after* its trailing `Stop` flips the session waitingForInput →
    /// processing (a legal transition) and strands it there — the "working"
    /// mascot that never stops. Funnel every event through one FIFO stream
    /// drained by a single consumer so ordering is preserved end-to-end.
    private let eventContinuation: AsyncStream<SessionEvent>.Continuation
    private var eventConsumer: Task<Void, Never>?

    init() {
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
        self.eventContinuation = continuation

        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self

        // Single consumer: awaits each event to completion before the next,
        // so events are applied strictly in arrival order (no actor-reentrancy
        // interleaving between them).
        eventConsumer = Task {
            for await event in stream {
                await SessionStore.shared.process(event)
            }
        }
    }

    deinit {
        eventContinuation.finish()
        eventConsumer?.cancel()
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        // Start periodic status rechecking
        Task {
            await SessionStore.shared.startPeriodicStatusCheck()
        }

        HookSocketServer.shared.start(
            onEvent: { [eventContinuation] event in
                // Preserve arrival order (see eventContinuation docs): yield to
                // the FIFO stream instead of spawning an unordered Task.
                eventContinuation.yield(.hookReceived(event))

                // The JSONLInterruptWatcher only understands Claude JSONL. Codex
                // and Copilot interrupt detection is handled by their own parsers
                // (or not at all yet) — never by this Claude-only watcher.
                if event.sessionPhase == .processing && event.agentSource == .claude {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd
                        )
                    }
                }

                if event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
        Task {
            await SessionStore.shared.stopPeriodicStatusCheck()
        }
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "allow"
            )

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "deny",
                reason: reason
            )

            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
            )
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    /// Toggle per-session auto-approval (bolt): force-on when not already forced,
    /// otherwise clear the override so the session follows the global setting
    /// again (there must always be a path back to "follow global").
    func toggleAutoApprove(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId) else { return }
            let newValue: Bool? = (session.autoApproveOverride == true) ? nil : true
            await SessionStore.shared.setAutoApproveOverride(sessionId: sessionId, newValue)
        }
    }

    /// Approve every session currently waiting for approval.
    func approveAllPermissions() {
        Task {
            let sessions = await SessionStore.shared.allSessions()
            for session in sessions where session.phase.isWaitingForApproval {
                approvePermission(sessionId: session.sessionId)
            }
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        pendingInstances = sessions.filter { $0.needsAttention }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }
}

// MARK: - Interrupt Watcher Delegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}

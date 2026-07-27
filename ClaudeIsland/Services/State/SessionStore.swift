//
//  SessionStore.swift
//  ClaudeIsland
//
//  Central state manager for all Claude sessions.
//  Single source of truth - all state mutations flow through process().
//

import Combine
import Foundation
import os.log

/// Central state manager for all Claude sessions
/// Uses Swift actor for thread-safe state mutations
actor SessionStore {
    static let shared = SessionStore()

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.claudeisland", category: "Session")

    // MARK: - State

    /// All sessions keyed by sessionId
    private var sessions: [String: SessionState] = [:]

    /// Pending file syncs (debounced)
    private var pendingSyncs: [String: Task<Void, Never>] = [:]

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000

    /// Periodic status check task
    private var statusCheckTask: Task<Void, Never>?

    /// Startup rollout recovery only needs to run once per app process.
    private var didRestoreCodexSessions = false

    /// Status check interval (3 seconds)
    private let statusCheckIntervalSeconds: UInt64 = 3

    /// Archive sessions that have remained in a safe resting phase for this
    /// long. CLI processes can stay alive indefinitely while waiting at their
    /// prompt, so pid liveness alone is not enough to remove stale sessions.
    private let idleArchiveSeconds: TimeInterval = 30 * 60

    /// 用戶端將 waitingForInput → idle 的閒置逾時。Codex 與 Copilot 完全沒有
    /// 對應 Claude `Notification`／`idle_prompt` 的 hook，而 Claude 也只會在特定條件下
    /// （例如終端機失去焦點）觸發 idle_prompt，因此所有來源都需要此備援機制，
    /// 否則吉祥物可能會永遠停留在「開心」姿勢。
    private let waitingForInputIdleTimeoutSeconds: TimeInterval = 1 * 60

    /// 針對卡在 processing／compacting 的工作階段所設的自我修復逾時：hook 會平行執行，
    /// 無法保證傳送順序或一定送達，而按 Esc 中斷也不會觸發 Stop hook，
    /// 因此結束事件可能永遠不會抵達。若超過此時間未收到任何事件，且已知沒有工具執行中
    /// （長時間執行的 Bash／Task 會在 PreToolUse 至 PostToolUse 期間保留 inProgress 項目），
    /// 則將狀態降級為 waitingForInput。
    private let processingStaleTimeoutSeconds: TimeInterval = 5 * 60

    // MARK: - Published State (for UI)

    /// Publisher for session state changes (nonisolated for Combine subscription from any context)
    private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])

    /// Public publisher for UI subscription
    nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Event Processing

    /// Process any session event - the ONLY way to mutate state
    func process(_ event: SessionEvent) async {
        Self.logger.debug("Processing: \(String(describing: event), privacy: .public)")

        switch event {
        case .hookReceived(let hookEvent):
            await processHookEvent(hookEvent)

        case .permissionApproved(let sessionId, let toolUseId):
            await processPermissionApproved(sessionId: sessionId, toolUseId: toolUseId)

        case .permissionDenied(let sessionId, let toolUseId, let reason):
            await processPermissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason)

        case .permissionSocketFailed(let sessionId, let toolUseId):
            await processSocketFailure(sessionId: sessionId, toolUseId: toolUseId)

        case .fileUpdated(let payload):
            await processFileUpdate(payload)

        case .interruptDetected(let sessionId):
            await processInterrupt(sessionId: sessionId)

        case .clearDetected(let sessionId):
            await processClearDetected(sessionId: sessionId)

        case .sessionEnded(let sessionId):
            await processSessionEnd(sessionId: sessionId)

        case .loadHistory(let sessionId, let cwd):
            await loadHistoryFromFile(sessionId: sessionId, cwd: cwd)

        case .historyLoaded(let sessionId, let messages, let completedTools, let toolResults, let structuredResults, let conversationInfo):
            await processHistoryLoaded(
                sessionId: sessionId,
                messages: messages,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                conversationInfo: conversationInfo
            )

        case .toolCompleted(let sessionId, let toolUseId, let result):
            await processToolCompleted(sessionId: sessionId, toolUseId: toolUseId, result: result)

        // MARK: - Subagent Events

        case .subagentStarted(let sessionId, let taskToolId):
            processSubagentStarted(sessionId: sessionId, taskToolId: taskToolId)

        case .subagentToolExecuted(let sessionId, let tool):
            processSubagentToolExecuted(sessionId: sessionId, tool: tool)

        case .subagentToolCompleted(let sessionId, let toolId, let status):
            processSubagentToolCompleted(sessionId: sessionId, toolId: toolId, status: status)

        case .subagentStopped(let sessionId, let taskToolId):
            processSubagentStopped(sessionId: sessionId, taskToolId: taskToolId)

        case .agentFileUpdated:
            // No longer used - subagent tools are populated from JSONL completion
            break
        }

        publishState()
    }

    // MARK: - Hook Event Processing

    private func processHookEvent(_ event: HookEvent) async {
        var event = event
        var sessionId = event.sessionId
        var transcriptPath = event.transcriptPath

        if event.agentSource == .codex {
            guard let routed = await routeCodexHook(event) else { return }
            event = routed.event
            sessionId = routed.sessionId
            transcriptPath = routed.transcriptPath
        }

        var session = sessions[sessionId] ?? createSession(from: event, transcriptPath: transcriptPath)

        session.approvalTimeoutMessage = nil
        session.pid = event.pid
        if let pid = event.pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        }
        if let tty = event.tty {
            session.tty = tty.replacingOccurrences(of: "/dev/", with: "")
        }
        // Codex: keep transcript path / host fresh (resume swaps the rollout file).
        if let transcriptPath {
            session.transcriptPath = transcriptPath
        }
        if let host = CodexHost.from(event.codexHost) {
            session.codexHost = host
        }
        session.lastActivity = Date()

        if event.status == "ended" {
            if session.source == .codex {
                // Codex 結束只代表聊天已完成；列仍需從此刻保留 30 分鐘。
                session.phase = .waitingForInput
                session.pid = nil
                sessions[sessionId] = session
            } else {
                sessions.removeValue(forKey: sessionId)
                cancelPendingSync(sessionId: sessionId)
            }
            return
        }

        // Auto-approval: if the policy says yes, respond "allow" over the socket
        // (via the same path as manual approval — the pending was already
        // registered by HookSocketServer) and skip waitingForApproval entirely,
        // so the notch never expands and no attention sound fires (plan §4b).
        let autoApprove = event.expectsResponse && AutoApprovalPolicy.shouldAutoApprove(
            source: session.source,
            tool: event.tool,
            toolInput: event.toolInput,
            mode: session.effectiveAutoApprovalMode,
            denyPatterns: AppSettings.autoApproveDenyPatterns
        )
        if autoApprove, let toolUseId = event.toolUseId {
            HookSocketServer.shared.respondToPermission(toolUseId: toolUseId, decision: "allow")
            Self.logger.info("auto-approved \(event.tool ?? "?", privacy: .public) for \(sessionId.prefix(8), privacy: .public)")
        }

        let newPhase: SessionPhase? = autoApprove ? .processing : event.determinePhase()

        // 處於休息狀態的工作階段（Stop 後的 waitingForInput，或中斷／idle_prompt 後的 idle）
        // 不應被「延遲抵達」的事件拉回 processing。PostToolUse、PostToolUseFailure、
        // PermissionDenied、SubagentStart、SubagentStop 與 PostCompact 都會回報
        // "processing"，但它們不可能是新回合的第一個事件；真正的新回合會透過
        // UserPromptSubmit 或 PreToolUse 宣告開始。hook 會以不同處理程序平行執行並競相連線
        // 至 socket，因此這些事件即使在邏輯上較早發生，仍可能晚於該回合的 Stop 抵達，
        // 或在中斷監看器已將工作階段設為 idle 後才抵達，導致吉祥物被切回「工作中」並卡住。
        // 遇到這種情況時應忽略狀態變更。
        let cannotStartTurn = ["PostToolUse", "PostToolUseFailure", "PermissionDenied",
                               "SubagentStart", "SubagentStop", "PostCompact"].contains(event.event)
        let isResting = session.phase == .waitingForInput || session.phase == .idle
        if let newPhase {
            if isResting, newPhase == .processing, cannotStartTurn {
                Self.logger.debug("Ignoring trailing \(event.event, privacy: .public) that would revive resting session \(sessionId.prefix(8), privacy: .public)")
            } else if session.source == .codex,
                      session.phase.isWaitingForApproval,
                      newPhase == .waitingForInput || newPhase == .idle,
                      nextPermissionContext(for: session, excluding: "") != nil {
                // Codex orchestrator 可以在 sub-agent 還掛著授權時就結束自己的回合
                // （「我先不空等」）——父 thread 的 Stop 會把父列拉去 waitingForInput，
                // Allow／Deny 就消失了。只要這列（含子 thread）還有未解決的授權，
                // 就守住 waitingForApproval。
                Self.logger.debug("Holding waitingForApproval on \(sessionId.prefix(8), privacy: .public) — pending permission(s) unresolved (\(event.event, privacy: .public) arrived)")
            } else if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
            } else {
                Self.logger.debug("Invalid transition: \(String(describing: session.phase), privacy: .public) -> \(String(describing: newPhase), privacy: .public), ignoring")
            }
        }

        // Claude drives its chat items (tool placeholders, subagents) from hook
        // events. Codex chat content is built entirely by CodexConversationParser
        // from the rollout — its hook tool ids don't match rollout call_ids, so
        // hook-driven placeholders would duplicate. Codex hooks only drive phase.
        if session.source == .claude {
            if event.event == "PermissionRequest", let toolUseId = event.toolUseId {
                // Auto-approved tools go straight to running; keep the manual
                // path unchanged (waitingForApproval).
                let status: ToolStatus = autoApprove ? .running : .waitingForApproval
                updateToolStatus(in: &session, toolId: toolUseId, status: status)
            }

            processToolTracking(event: event, session: &session)
            processSubagentTracking(event: event, session: &session)

            if event.event == "Stop" {
                session.subagentState = SubagentState()
            }
        }

        sessions[sessionId] = session
        publishState()

        if event.shouldSyncFile {
            scheduleFileSync(sessionId: sessionId, cwd: event.cwd)
        }
    }

    /// Codex chat-row rule:
    /// - An existing user row keeps receiving its own events.
    /// - A new row requires SessionStart/UserPromptSubmit + thread_source=user.
    /// - Everything else is internal. Ignore it, except a permission may reuse
    ///   an already-visible parent row.
    private func routeCodexHook(
        _ event: HookEvent
    ) async -> (event: HookEvent, sessionId: String, transcriptPath: String?)? {
        let sessionId = event.sessionId
        let canCreate = event.event == "SessionStart" || event.event == "UserPromptSubmit"

        // Current Codex payload: session_id is the visible parent, agent_id is
        // the internal child. No rollout lookup is needed.
        if let agentId = event.agentId, agentId != sessionId {
            return routeInternalCodexHook(event, parentId: sessionId)
        }

        let existing = sessions[sessionId]
        let pathChanged = event.transcriptPath != nil
            && event.transcriptPath != existing?.transcriptPath
        if let existing, event.agentId == nil, !pathChanged {
            return (event, sessionId, event.transcriptPath ?? existing.transcriptPath)
        }

        // Unseen ordinary tool/stop/notification events never create rows.
        guard existing != nil || canCreate || event.expectsResponse || event.agentId != nil else { return nil }
        guard let resolved = await resolveCodexThreadInfo(
            sessionId: sessionId,
            suggestedPath: event.transcriptPath
        ) else {
            passPermissionThroughToCodex(event)
            return nil
        }

        if (existing != nil || canCreate),
           resolved.info.isUserThread,
           resolved.info.threadId == sessionId {
            return (event, sessionId, resolved.path)
        }
        let parentId = resolved.info.parentThreadId
            ?? (!resolved.info.isUserThread && resolved.info.threadId != sessionId ? sessionId : nil)
        return routeInternalCodexHook(event, parentId: parentId)
    }

    private func routeInternalCodexHook(
        _ event: HookEvent,
        parentId: String?
    ) -> (event: HookEvent, sessionId: String, transcriptPath: String?)? {
        if let parentId, var parent = sessions[parentId] {
            parent.lastActivity = Date()
            sessions[parentId] = parent
        }

        guard event.expectsResponse,
              let parentId,
              let parent = sessions[parentId] else {
            passPermissionThroughToCodex(event)
            return nil
        }

        if event.sessionId != parentId, let toolUseId = event.toolUseId {
            HookSocketServer.shared.movePendingPermission(
                toolUseId: toolUseId,
                toSessionId: parentId
            )
        }

        return (event, parentId, parent.transcriptPath)
    }

    /// Resolve a real Codex rollout without assuming the file already exists at
    /// the exact instant the first hook arrives. The wait is bounded so helper
    /// threads (which never write a rollout) cannot stall the event queue.
    private func resolveCodexRolloutPath(sessionId: String, suggestedPath: String?) async -> String? {
        let fileManager = FileManager.default

        // In normal payloads Codex gives us the exact path. Allow the writer up
        // to 150 ms to create it before falling back to a filesystem lookup.
        if let suggestedPath, !suggestedPath.isEmpty {
            for attempt in 0..<4 {
                if fileManager.fileExists(atPath: suggestedPath) {
                    return suggestedPath
                }
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        } else {
            // A missing transcript_path is also allowed by Codex. Give the
            // rollout writer the same small window before searching by id.
            try? await Task.sleep(for: .milliseconds(150))
        }

        return findCodexRolloutPath(sessionId: sessionId, fileManager: fileManager)
    }

    /// hook 與 Codex rollout writer 會並行。檔案已存在不代表第一行
    /// session_meta 已完整落盤，因此取得 path 後仍需短暫重試解析。逾時就回傳
    /// nil，呼叫端不建列，等待下一個 hook 再試。
    private func resolveCodexThreadInfo(
        sessionId: String,
        suggestedPath: String?
    ) async -> (path: String, info: CodexThreadInfo)? {
        guard let path = await resolveCodexRolloutPath(
            sessionId: sessionId,
            suggestedPath: suggestedPath
        ) else { return nil }

        for attempt in 0..<8 {
            if let info = codexThreadInfo(atPath: path) {
                return (path, info)
            }
            if attempt < 7 {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return nil
    }

    /// Fallback for hook payloads with a missing/stale transcript_path. Rollout
    /// filenames contain the session UUID in both active and archived stores.
    private func findCodexRolloutPath(sessionId: String, fileManager: FileManager) -> String? {
        for home in CodexHookInstaller.discoverCodexHomes() {
            let roots = [
                home.appendingPathComponent("sessions", isDirectory: true),
                home.appendingPathComponent("archived_sessions", isDirectory: true),
            ]

            for root in roots {
                guard let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for case let url as URL in enumerator {
                    guard url.pathExtension == "jsonl",
                          url.lastPathComponent.contains(sessionId) else { continue }
                    return url.path
                }
            }
        }
        return nil
    }

    /// Codex rollout 第一行 session_meta 解出的 thread 屬性。
    private struct CodexThreadInfo {
        /// rollout 自己的 thread id。hook 的 session_id 在 alternate internal
        /// 事件可能是父 id，必須用這個欄位避免把父 thread 誤標成 sub-agent。
        let threadId: String
        /// 是否為真正的使用者 thread（唯一可自成 island 列的種類）。
        let isUserThread: Bool
        /// 父 thread id（僅 sub-agent 類 thread 有；session_meta 頂層
        /// `parent_thread_id`，或 `source.subagent.thread_spawn.parent_thread_id`）。
        let parentThreadId: String?
        /// User thread 的工作目錄與來源 host，用於 app 重啟後恢復聊天列。
        let cwd: String?
        let codexHost: CodexHost?
    }

    /// 判別某個 rollout 屬於哪一類 Codex thread。最新的 ThreadSource enum 為
    /// user／subagent／memory_consolidation／Feature(任意字串)，而 SubAgentSource
    /// 還有 review、compact 等 —— 因此規則是「**只有 `thread_source == "user"`
    /// 才算使用者 thread**」，而不是列舉所有非 user 值。欄位缺席（舊版 rollout）
    /// 時退回檢查 `source.subagent`。讀不到、第一行尚未寫完、JSON 不完整或
    /// 缺少 thread id 時回傳 nil；呼叫端會短暫重試，仍無法辨識就不建列。
    private func codexThreadInfo(atPath path: String) -> CodexThreadInfo? {
        guard let firstLine = Self.readFirstLine(atPath: path, maxBytes: 512 * 1024) else {
            return nil
        }
        // 結構化解析：容忍空白、欄位順序不同，並順手取出父 thread id。
        guard let data = firstLine.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let type = root["type"] as? String, type != "session_meta" { return nil }
        let payload = (root["payload"] as? [String: Any]) ?? root
        guard let threadId = (payload["id"] as? String) ?? (payload["session_id"] as? String),
              !threadId.isEmpty else {
            return nil
        }

        var isUser = true
        if let threadSource = payload["thread_source"] as? String {
            isUser = threadSource == "user"
        } else if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
            // 舊版無 thread_source：以 source.subagent 判別。
            isUser = false
        }

        var parentThreadId = payload["parent_thread_id"] as? String
        if parentThreadId == nil,
           let source = payload["source"] as? [String: Any],
           let subagent = source["subagent"] as? [String: Any],
           let spawn = subagent["thread_spawn"] as? [String: Any] {
            parentThreadId = spawn["parent_thread_id"] as? String
        }

        let cwd = payload["cwd"] as? String
        let rawSource = (payload["source"] as? String)?.lowercased()
        let originator = (payload["originator"] as? String)?.lowercased()
        let codexHost: CodexHost?
        switch rawSource {
        case "cli":
            codexHost = .cli
        case "vscode":
            codexHost = .vscode
        case "exec":
            codexHost = .exec
        case "desktop", "app_server", "app-server":
            codexHost = .desktop
        default:
            codexHost = originator?.contains("desktop") == true ? .desktop : nil
        }

        return CodexThreadInfo(
            threadId: threadId,
            isUserThread: isUser,
            parentThreadId: parentThreadId,
            cwd: cwd,
            codexHost: codexHost
        )
    }

    /// 讀取檔案的第一行（以換行為界），最多讀 `maxBytes` 位元組。rollout 的
    /// session_meta 第一行含完整 base_instructions，可能達數十 KB，但遠低於上限；
    /// 分塊讀取，一遇到換行即回傳，避免把 MB 級的 rollout 整個載入。
    private static func readFirstLine(atPath path: String, maxBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        let chunkSize = 64 * 1024
        while buffer.count < maxBytes {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                return String(data: buffer[buffer.startIndex..<newlineIndex], encoding: .utf8)
            }
        }
        if buffer.isEmpty { return nil }
        return String(data: buffer.prefix(maxBytes), encoding: .utf8)
    }

    /// A permission event must never be the reason a Codex chat row exists.
    /// When its real user session is not already visible, answer "ask" so the
    /// hook exits immediately and Codex can show its own native approval UI.
    private func passPermissionThroughToCodex(_ event: HookEvent) {
        guard event.expectsResponse else { return }
        if let toolUseId = event.toolUseId {
            HookSocketServer.shared.respondToPermission(
                toolUseId: toolUseId,
                decision: "ask"
            )
        } else {
            HookSocketServer.shared.respondToPermissionBySession(
                sessionId: event.sessionId,
                decision: "ask"
            )
        }
    }

    private func createSession(from event: HookEvent, transcriptPath: String? = nil) -> SessionState {
        SessionState(
            sessionId: event.sessionId,
            cwd: event.cwd,
            projectName: URL(fileURLWithPath: event.cwd).lastPathComponent,
            source: event.agentSource,
            transcriptPath: transcriptPath ?? event.transcriptPath,
            codexHost: CodexHost.from(event.codexHost),
            pid: event.pid,
            tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
            isInTmux: false,  // Will be updated
            phase: .idle
        )
    }

    private func processToolTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if let toolUseId = event.toolUseId, let toolName = event.tool {
                session.toolTracker.startTool(id: toolUseId, name: toolName)

                // Skip creating top-level placeholder for subagent tools
                // They'll appear under their parent Task instead
                let isSubagentTool = session.subagentState.hasActiveSubagent && !ToolCallItem.isSubagentContainerName(toolName)
                if isSubagentTool {
                    return
                }

                let toolExists = session.chatItems.contains { $0.id == toolUseId }
                if !toolExists {
                    var input: [String: String] = [:]
                    if let hookInput = event.toolInput {
                        for (key, value) in hookInput {
                            if let str = value.value as? String {
                                input[key] = str
                            } else if let num = value.value as? Int {
                                input[key] = String(num)
                            } else if let bool = value.value as? Bool {
                                input[key] = bool ? "true" : "false"
                            }
                        }
                    }

                    let placeholderItem = ChatHistoryItem(
                        id: toolUseId,
                        type: .toolCall(ToolCallItem(
                            name: toolName,
                            input: input,
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: Date()
                    )
                    session.chatItems.append(placeholderItem)
                    Self.logger.debug("Created placeholder tool entry for \(toolUseId.prefix(16), privacy: .public)")
                }
            }

        case "PostToolUseFailure", "PermissionDenied":
            // 無論是哪一種情況，工具都已結束；移除 inProgress 項目，避免卡住 processing
            // 的監看機制永遠受到阻擋。結果／狀態會透過 JSONL（toolCompleted）進行協調。
            if let toolUseId = event.toolUseId {
                session.toolTracker.completeTool(id: toolUseId, success: false)
            }

        case "PostToolUse":
            if let toolUseId = event.toolUseId {
                session.toolTracker.completeTool(id: toolUseId, success: true)
                // Update chatItem status - tool completed (possibly approved via terminal)
                // Only update if still waiting for approval or running
                for i in 0..<session.chatItems.count {
                    if session.chatItems[i].id == toolUseId,
                       case .toolCall(var tool) = session.chatItems[i].type,
                       tool.status == .waitingForApproval || tool.status == .running {
                        tool.status = .success
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseId,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp
                        )
                        break
                    }
                }
            }

        default:
            break
        }
    }

    private func processSubagentTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if ToolCallItem.isSubagentContainerName(event.tool), let toolUseId = event.toolUseId {
                let description = event.toolInput?["description"]?.value as? String
                session.subagentState.startTask(taskToolId: toolUseId, description: description)
                Self.logger.debug("Started Task/Agent subagent tracking: \(toolUseId.prefix(12), privacy: .public)")
            } else if let toolName = event.tool,
                      let toolUseId = event.toolUseId,
                      session.subagentState.hasActiveSubagent {
                // A subagent's inner tool is starting. Add it to the parent Task/Agent's
                // subagent list and sync to chatItems so the UI updates live (rather
                // than only after the parent Agent completes).
                var input: [String: String] = [:]
                if let hookInput = event.toolInput {
                    for (key, value) in hookInput {
                        if let str = value.value as? String {
                            input[key] = str
                        } else if let num = value.value as? Int {
                            input[key] = String(num)
                        } else if let bool = value.value as? Bool {
                            input[key] = bool ? "true" : "false"
                        }
                    }
                }
                let subagentTool = SubagentToolCall(
                    id: toolUseId,
                    name: toolName,
                    input: input,
                    status: .running,
                    timestamp: Date()
                )
                session.subagentState.addSubagentTool(subagentTool)
                syncSubagentToolsToChatItems(session: &session)
            }

        case "PostToolUse":
            if ToolCallItem.isSubagentContainerName(event.tool), let toolUseId = event.toolUseId {
                // Agent tool returned — the subagent has finished. Stop
                // tracking so subsequent tools in the parent turn don't get
                // attached to this dead task.
                session.subagentState.stopTask(taskToolId: toolUseId)
                Self.logger.debug("Stopped subagent tracking for \(toolUseId.prefix(12), privacy: .public)")
            } else if let toolUseId = event.toolUseId,
                      session.subagentState.hasActiveSubagent {
                // A subagent's inner tool completed. Update its status in the
                // parent's subagent list and sync.
                session.subagentState.updateSubagentToolStatus(toolId: toolUseId, status: .success)
                syncSubagentToolsToChatItems(session: &session)
            }

        case "SubagentStop":
            // SubagentStop fires when a subagent completes - stop tracking
            // Subagent tools are populated from agent file in processFileUpdated
            Self.logger.debug("SubagentStop received")

        default:
            break
        }
    }

    /// Push the current subagent tool lists from subagentState into the
    /// corresponding ChatHistoryItem.subagentTools so the UI renders them live.
    private func syncSubagentToolsToChatItems(session: inout SessionState) {
        for (taskToolId, context) in session.subagentState.activeTasks {
            guard !context.subagentTools.isEmpty else { continue }
            for i in 0..<session.chatItems.count {
                if session.chatItems[i].id == taskToolId,
                   case .toolCall(var tool) = session.chatItems[i].type {
                    tool.subagentTools = context.subagentTools
                    session.chatItems[i] = ChatHistoryItem(
                        id: taskToolId,
                        type: .toolCall(tool),
                        timestamp: session.chatItems[i].timestamp
                    )
                    break
                }
            }
        }
    }

    // MARK: - Subagent Event Handlers

    /// Handle subagent started event
    private func processSubagentStarted(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.startTask(taskToolId: taskToolId)
        sessions[sessionId] = session
    }

    /// Handle subagent tool executed event
    private func processSubagentToolExecuted(sessionId: String, tool: SubagentToolCall) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.addSubagentTool(tool)
        sessions[sessionId] = session
    }

    /// Handle subagent tool completed event
    private func processSubagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.updateSubagentToolStatus(toolId: toolId, status: status)
        sessions[sessionId] = session
    }

    /// Handle subagent stopped event
    private func processSubagentStopped(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.stopTask(taskToolId: taskToolId)
        sessions[sessionId] = session
        // Subagent tools will be populated from agent file in processFileUpdated
    }

    /// Parse ISO8601 timestamp string
    private func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let str = timestampStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Permission Processing

    /// Shared "resolve a pending permission" flow for approve/deny: mark the
    /// tool's status, then either advance to the next pending permission or
    /// fall back to `.processing` if none remain.
    private func advancePastPermission(sessionId: String, toolUseId: String, resolvedStatus: ToolStatus, logSuffix: String = "") async {
        guard var session = sessions[sessionId] else { return }

        updateToolStatus(in: &session, toolId: toolUseId, status: resolvedStatus)

        // Check if there are other tools still waiting for approval
        let nextContext = nextPermissionContext(for: session, excluding: toolUseId)
        if let nextContext {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(nextContext)
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending permission\(logSuffix): \(nextContext.toolUseId.prefix(12), privacy: .public)")
            }
        } else if case .waitingForApproval = session.phase {
            // No more pending permissions - transition to processing
            if session.phase.canTransition(to: .processing) {
                session.phase = .processing
            }
        }

        sessions[sessionId] = session
    }

    private func processPermissionApproved(sessionId: String, toolUseId: String) async {
        await advancePastPermission(sessionId: sessionId, toolUseId: toolUseId, resolvedStatus: .running)
    }

    // MARK: - Tool Completion Processing

    /// Process a tool completion event (from JSONL detection)
    /// This is the authoritative handler for tool completions - ensures consistent state updates
    private func processToolCompleted(sessionId: String, toolUseId: String, result: ToolCompletionResult) async {
        guard var session = sessions[sessionId] else { return }

        // JSONL 是具權威性的完成訊號；即使 PostToolUse hook 在平行競爭中遺失，
        // 仍應清除 inProgress 項目。
        session.toolTracker.completeTool(id: toolUseId, success: result.status == .success)

        // Check if this tool is already completed (avoid duplicate processing)
        if let existingItem = session.chatItems.first(where: { $0.id == toolUseId }),
           case .toolCall(let tool) = existingItem.type,
           tool.status == .success || tool.status == .error || tool.status == .interrupted {
            // Already completed, skip
            return
        }

        // Update the tool status
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolUseId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                Self.logger.debug("Tool \(toolUseId.prefix(12), privacy: .public) completed with status: \(String(describing: result.status), privacy: .public)")
                break
            }
        }

        // Update session phase if needed
        // If the completed tool was the one in the phase context, switch to next pending or processing
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            if let nextContext = nextPermissionContext(for: session, excluding: toolUseId) {
                session.phase = .waitingForApproval(nextContext)
                Self.logger.debug("Switched to next pending permission after completion: \(nextContext.toolUseId.prefix(12), privacy: .public)")
            } else if session.phase.canTransition(to: .processing) {
                session.phase = .processing
            }
        }

        sessions[sessionId] = session
    }

    /// Find the next tool waiting for approval (excluding a specific tool ID)
    private func findNextPendingTool(in session: SessionState, excluding toolId: String) -> (id: String, name: String, timestamp: Date)? {
        for item in session.chatItems {
            if item.id == toolId { continue }
            if case .toolCall(let tool) = item.type, tool.status == .waitingForApproval {
                return (id: item.id, name: tool.name, timestamp: item.timestamp)
            }
        }
        return nil
    }

    /// The next permission still awaiting a decision after `toolUseId` is resolved.
    ///
    /// Claude tracks pending permissions as waitingForApproval chat items, so we
    /// scan those. Codex has no such items (its chat is built from the rollout,
    /// whose call_ids don't match hook ids) — so for Codex we consult the socket
    /// server's live pending map, otherwise concurrent Codex permission requests
    /// would be stranded (button vanishes, hook blocks until timeout).
    private func nextPermissionContext(for session: SessionState, excluding toolUseId: String) -> PermissionContext? {
        if session.source == .codex {
            guard let next = HookSocketServer.shared.nextPendingPermission(
                sessionId: session.sessionId, excluding: toolUseId
            ) else { return nil }
            return PermissionContext(
                toolUseId: next.toolUseId,
                toolName: next.toolName ?? "unknown",
                toolInput: next.toolInput,
                receivedAt: next.receivedAt
            )
        }

        guard let nextPending = findNextPendingTool(in: session, excluding: toolUseId) else { return nil }
        return PermissionContext(
            toolUseId: nextPending.id,
            toolName: nextPending.name,
            toolInput: nil,
            receivedAt: nextPending.timestamp
        )
    }

    private func processPermissionDenied(sessionId: String, toolUseId: String, reason: String?) async {
        await advancePastPermission(sessionId: sessionId, toolUseId: toolUseId, resolvedStatus: .error, logSuffix: " after denial")
    }

    private func processSocketFailure(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Mark the failed tool's status as error
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        let nextContext = nextPermissionContext(for: session, excluding: toolUseId)
        if let nextContext {
            // Another tool is waiting - switch to that tool's context
            let newPhase = SessionPhase.waitingForApproval(nextContext)
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending permission after socket failure: \(nextContext.toolUseId.prefix(12), privacy: .public)")
            }
        } else if case .waitingForApproval = session.phase {
            // No more pending permissions - clear permission state
            session.applyApprovalTimeout()
        }

        sessions[sessionId] = session
    }

    // MARK: - File Update Processing

    private func processFileUpdate(_ payload: FileUpdatePayload) async {
        guard var session = sessions[payload.sessionId] else { return }

        // Update conversationInfo from the transcript (summary, lastMessage, tokens).
        let conversationInfo: ConversationInfo
        if session.source == .codex, let transcriptPath = session.transcriptPath {
            conversationInfo = await CodexConversationParser.shared.conversationInfo(
                sessionId: payload.sessionId,
                transcriptPath: transcriptPath
            )
        } else {
            conversationInfo = await ConversationParser.shared.parse(
                sessionId: payload.sessionId,
                cwd: session.cwd
            )
        }
        session.conversationInfo = conversationInfo

        // Handle /clear reconciliation - remove items that no longer exist in parser state
        if session.needsClearReconciliation {
            // Build set of valid IDs from the payload messages
            var validIds = Set<String>()
            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    switch block {
                    case .toolUse(let tool):
                        validIds.insert(tool.id)
                    case .text, .thinking, .image, .interrupted:
                        let itemId = "\(message.id)-\(block.typePrefix)-\(blockIndex)"
                        validIds.insert(itemId)
                    }
                }
            }

            // Filter chatItems to only keep valid items OR items that are very recent
            // (within last 2 seconds - these are hook-created placeholders for post-clear tools)
            let cutoffTime = Date().addingTimeInterval(-2)
            let previousCount = session.chatItems.count
            session.chatItems = session.chatItems.filter { item in
                validIds.contains(item.id) || item.timestamp > cutoffTime
            }

            // Also reset tool tracker
            session.toolTracker = ToolTracker()
            session.subagentState = SubagentState()

            session.needsClearReconciliation = false
            Self.logger.debug("Clear reconciliation: kept \(session.chatItems.count) of \(previousCount) items")
        }

        if payload.isIncremental {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }
        } else {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }

            session.chatItems.sort { $0.timestamp < $1.timestamp }
        }

        session.toolTracker.lastSyncTime = Date()

        // Task/Agent subagent nesting is Claude-specific (agent JSONL files).
        if session.source == .claude {
            await populateSubagentToolsFromAgentFiles(
                sessionId: payload.sessionId,
                session: &session,
                cwd: payload.cwd,
                structuredResults: payload.structuredResults
            )
        }

        sessions[payload.sessionId] = session

        await emitToolCompletionEvents(
            sessionId: payload.sessionId,
            session: session,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
    }

    /// Populate subagent tools for Task/Agent tools using their agent JSONL files
    private func populateSubagentToolsFromAgentFiles(
        sessionId: String,
        session: inout SessionState,
        cwd: String,
        structuredResults: [String: ToolResultData]
    ) async {
        for i in 0..<session.chatItems.count {
            guard case .toolCall(var tool) = session.chatItems[i].type,
                  tool.isSubagentContainer,
                  let structuredResult = structuredResults[session.chatItems[i].id],
                  case .task(let taskResult) = structuredResult,
                  !taskResult.agentId.isEmpty else { continue }

            let taskToolId = session.chatItems[i].id

            // Store agentId → description mapping for AgentOutputTool display
            if let description = session.subagentState.activeTasks[taskToolId]?.description {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            } else if let description = tool.input["description"] {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            }

            let subagentToolInfos = await ConversationParser.shared.parseSubagentTools(
                sessionId: sessionId,
                agentId: taskResult.agentId,
                cwd: cwd
            )

            guard !subagentToolInfos.isEmpty else { continue }

            tool.subagentTools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }

            session.chatItems[i] = ChatHistoryItem(
                id: taskToolId,
                type: .toolCall(tool),
                timestamp: session.chatItems[i].timestamp
            )

            Self.logger.debug("Populated \(subagentToolInfos.count) subagent tools for Task \(taskToolId.prefix(12), privacy: .public) from agent \(taskResult.agentId.prefix(8), privacy: .public)")
        }
    }

    /// Emit toolCompleted events for tools that have results in JSONL but aren't marked complete yet
    private func emitToolCompletionEvents(
        sessionId: String,
        session: SessionState,
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData]
    ) async {
        for item in session.chatItems {
            guard case .toolCall(let tool) = item.type else { continue }

            // Only emit for tools that are running or waiting but have results in JSONL
            guard tool.status == .running || tool.status == .waitingForApproval else { continue }
            guard completedToolIds.contains(item.id) else { continue }

            let result = ToolCompletionResult.from(
                parserResult: toolResults[item.id],
                structuredResult: structuredResults[item.id]
            )

            // Process the completion event (this will update state and phase consistently)
            await process(.toolCompleted(sessionId: sessionId, toolUseId: item.id, result: result))
        }
    }

    /// Create chat item (checks existingIds to avoid duplicates)
    private func createChatItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        existingIds: Set<String>,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        switch block {
        case .text(let text):
            let itemId = "\(message.id)-text-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            // Skip empty text blocks — assistant turns with only tool calls
            // produce empty text blocks that would render as orphan dots/gaps.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            if message.role == .user {
                return ChatHistoryItem(id: itemId, type: .user(text), timestamp: message.timestamp)
            } else {
                return ChatHistoryItem(id: itemId, type: .assistant(text), timestamp: message.timestamp)
            }

        case .toolUse(let tool):
            guard toolTracker.markSeen(tool.id) else { return nil }

            let isCompleted = completedTools.contains(tool.id)
            let status: ToolStatus = isCompleted ? .success : .running

            // Extract result text for completed tools
            var resultText: String? = nil
            if isCompleted, let parserResult = toolResults[tool.id] {
                if let stdout = parserResult.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = parserResult.content, !content.isEmpty {
                    resultText = content
                }
            }

            return ChatHistoryItem(
                id: tool.id,
                type: .toolCall(ToolCallItem(
                    name: tool.name,
                    input: tool.input,
                    status: status,
                    result: resultText,
                    structuredResult: structuredResults[tool.id],
                    subagentTools: []
                )),
                timestamp: message.timestamp
            )

        case .thinking(let text):
            let itemId = "\(message.id)-thinking-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            // Skip empty thinking blocks — streaming can briefly produce empty
            // ones that would render as orphan grey dots.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            return ChatHistoryItem(id: itemId, type: .thinking(text), timestamp: message.timestamp)

        case .image(let imageBlock):
            let itemId = "\(message.id)-image-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .image(imageBlock), timestamp: message.timestamp)

        case .interrupted:
            let itemId = "\(message.id)-interrupted-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .interrupted, timestamp: message.timestamp)
        }
    }

    private func updateToolStatus(in session: inout SessionState, toolId: String, status: ToolStatus) {
        var found = false
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                found = true
                break
            }
        }
        if !found {
            let count = session.chatItems.count
            Self.logger.warning("Tool \(toolId.prefix(16), privacy: .public) not found in chatItems (count: \(count))")
        }
    }

    // MARK: - Interrupt Processing

    private func processInterrupt(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Clear subagent state
        session.subagentState = SubagentState()

        // 遭中斷的工具不會收到 PostToolUse；移除其 inProgress 項目，
        // 避免卡住 processing 的監看機制被殘留項目阻擋。
        session.toolTracker.inProgress.removeAll()

        // Mark running tools as interrupted
        for i in 0..<session.chatItems.count {
            if case .toolCall(var tool) = session.chatItems[i].type,
               tool.status == .running {
                tool.status = .interrupted
                session.chatItems[i] = ChatHistoryItem(
                    id: session.chatItems[i].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
            }
        }

        // Transition to idle
        if session.phase.canTransition(to: .idle) {
            session.phase = .idle
        }

        sessions[sessionId] = session
    }

    // MARK: - Clear Processing

    private func processClearDetected(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        Self.logger.info("Processing /clear for session \(sessionId.prefix(8), privacy: .public)")

        // Mark that a clear happened - the next fileUpdated will reconcile
        // by removing items that no longer exist in the parser's state
        session.needsClearReconciliation = true
        sessions[sessionId] = session

        Self.logger.info("/clear processed for session \(sessionId.prefix(8), privacy: .public) - marked for reconciliation")
    }

    // MARK: - Session End Processing

    private func processSessionEnd(sessionId: String) async {
        let session = sessions.removeValue(forKey: sessionId)
        cancelPendingSync(sessionId: sessionId)
        if session?.source == .codex {
            await CodexConversationParser.shared.resetState(for: sessionId)
        }
    }

    // MARK: - History Loading

    private func loadHistoryFromFile(sessionId: String, cwd: String) async {
        // Codex sessions load their history from the rollout JSONL.
        if let session = sessions[sessionId], session.source == .codex,
           let transcriptPath = session.transcriptPath {
            let messages = await CodexConversationParser.shared.parseFullConversation(
                sessionId: sessionId, transcriptPath: transcriptPath
            )
            let completedTools = await CodexConversationParser.shared.completedToolIds(for: sessionId)
            let toolResults = await CodexConversationParser.shared.toolResults(for: sessionId)
            let structuredResults = await CodexConversationParser.shared.structuredResults(for: sessionId)
            let conversationInfo = await CodexConversationParser.shared.conversationInfo(
                sessionId: sessionId, transcriptPath: transcriptPath
            )
            await process(.historyLoaded(
                sessionId: sessionId,
                messages: messages,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                conversationInfo: conversationInfo
            ))
            return
        }

        // Parse file asynchronously
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd
        )
        let completedTools = await ConversationParser.shared.completedToolIds(for: sessionId)
        let toolResults = await ConversationParser.shared.toolResults(for: sessionId)
        let structuredResults = await ConversationParser.shared.structuredResults(for: sessionId)

        // Also parse conversationInfo (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: sessionId,
            cwd: cwd
        )

        // Process loaded history
        await process(.historyLoaded(
            sessionId: sessionId,
            messages: messages,
            completedTools: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            conversationInfo: conversationInfo
        ))
    }

    private func processHistoryLoaded(
        sessionId: String,
        messages: [ChatMessage],
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        conversationInfo: ConversationInfo
    ) async {
        guard var session = sessions[sessionId] else { return }

        // Update conversationInfo (summary, lastMessage, etc.)
        session.conversationInfo = conversationInfo

        // Convert messages to chat items
        let existingIds = Set(session.chatItems.map { $0.id })

        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                let item = createChatItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    existingIds: existingIds,
                    completedTools: completedTools,
                    toolResults: toolResults,
                    structuredResults: structuredResults,
                    toolTracker: &session.toolTracker
                )

                if let item = item {
                    session.chatItems.append(item)
                }
            }
        }

        // Sort by timestamp
        session.chatItems.sort { $0.timestamp < $1.timestamp }

        sessions[sessionId] = session
    }

    // MARK: - File Sync Scheduling

    private func scheduleFileSync(sessionId: String, cwd: String) {
        // Cancel existing sync
        cancelPendingSync(sessionId: sessionId)

        // Codex sessions parse their rollout JSONL (transcript_path) instead of a
        // cwd-derived Claude path.
        if let session = sessions[sessionId], session.source == .codex {
            guard let transcriptPath = session.transcriptPath else { return }
            pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
                try? await Task.sleep(nanoseconds: syncDebounceNs)
                guard !Task.isCancelled else { return }

                let result = await CodexConversationParser.shared.parseIncremental(
                    sessionId: sessionId,
                    transcriptPath: transcriptPath
                )

                if result.interruptDetected {
                    await self?.process(.interruptDetected(sessionId: sessionId))
                }

                // Always drive a fileUpdated (even with no new messages): it
                // refreshes token/last-message info and reconciles tool
                // completions against results that arrived in this read.
                let payload = FileUpdatePayload(
                    sessionId: sessionId,
                    cwd: cwd,
                    messages: result.newMessages,
                    isIncremental: true,
                    completedToolIds: result.completedToolIds,
                    toolResults: result.toolResults,
                    structuredResults: result.structuredResults
                )
                await self?.process(.fileUpdated(payload))
            }
            return
        }

        // Schedule new debounced sync
        pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }

            // Parse incrementally - only get NEW messages since last call
            let result = await ConversationParser.shared.parseIncremental(
                sessionId: sessionId,
                cwd: cwd
            )

            if result.clearDetected {
                await self?.process(.clearDetected(sessionId: sessionId))
            }

            guard !result.newMessages.isEmpty || result.clearDetected else {
                return
            }

            let payload = FileUpdatePayload(
                sessionId: sessionId,
                cwd: cwd,
                messages: result.newMessages,
                isIncremental: !result.clearDetected,
                completedToolIds: result.completedToolIds,
                toolResults: result.toolResults,
                structuredResults: result.structuredResults
            )

            await self?.process(.fileUpdated(payload))
        }
    }

    private func cancelPendingSync(sessionId: String) {
        pendingSyncs[sessionId]?.cancel()
        pendingSyncs.removeValue(forKey: sessionId)
    }

    // MARK: - Codex Startup Recovery

    /// SessionStore 本身不落盤，所以 app 重啟時從最近 30 分鐘的 Codex rollout
    /// 恢復真正的 user sessions。判斷刻意保持單純：
    ///   - thread_source == user：顯示
    ///   - subagent/review/memory 等其他來源：不顯示
    /// 這也讓已在進行中的 VS Code/Desktop 任務不必等下一個 hook 才重新出現。
    func restoreRecentCodexUserSessions() async {
        guard !didRestoreCodexSessions else { return }
        didRestoreCodexSessions = true

        let fileManager = FileManager.default
        let cutoff = Date().addingTimeInterval(-idleArchiveSeconds)
        var candidates: [String: (path: String, info: CodexThreadInfo, modifiedAt: Date)] = [:]

        for home in CodexHookInstaller.discoverCodexHomes() {
            let roots = [
                home.appendingPathComponent("sessions", isDirectory: true),
                home.appendingPathComponent("archived_sessions", isDirectory: true),
            ]

            for root in roots {
                guard let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for case let url as URL in enumerator {
                    guard url.pathExtension == "jsonl",
                          let values = try? url.resourceValues(
                            forKeys: [.isRegularFileKey, .contentModificationDateKey]
                          ),
                          values.isRegularFile == true,
                          let modifiedAt = values.contentModificationDate,
                          modifiedAt >= cutoff,
                          let info = codexThreadInfo(atPath: url.path),
                          info.isUserThread,
                          let cwd = info.cwd,
                          !cwd.isEmpty else {
                        continue
                    }

                    // 同一 session 若同時存在 active/archive rollout，取較新的檔案。
                    if let existing = candidates[info.threadId],
                       existing.modifiedAt >= modifiedAt {
                        continue
                    }
                    candidates[info.threadId] = (url.path, info, modifiedAt)
                }
            }
        }

        var restored: [(sessionId: String, cwd: String)] = []
        for candidate in candidates.values.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            let sessionId = candidate.info.threadId
            guard sessions[sessionId] == nil, let cwd = candidate.info.cwd else { continue }

            sessions[sessionId] = SessionState(
                sessionId: sessionId,
                cwd: cwd,
                projectName: URL(fileURLWithPath: cwd).lastPathComponent,
                source: .codex,
                transcriptPath: candidate.path,
                codexHost: candidate.info.codexHost,
                phase: restoredCodexPhase(
                    atPath: candidate.path,
                    modifiedAt: candidate.modifiedAt
                ),
                lastActivity: candidate.modifiedAt,
                createdAt: candidate.modifiedAt
            )
            restored.append((sessionId, cwd))
        }

        guard !restored.isEmpty else { return }
        publishState()
        Self.logger.info("Restored \(restored.count) recent Codex user session(s) from rollout")

        // 補回標題、訊息與 token；active sessions 之後也會由 periodic sync 持續更新。
        for item in restored {
            await loadHistoryFromFile(sessionId: item.sessionId, cwd: item.cwd)
        }
    }

    /// 從 rollout 尾端判斷最後一個 user turn 是否已結束。找不到 lifecycle marker
    /// 時用檔案最近是否仍在更新作為保守 fallback。
    private func restoredCodexPhase(atPath path: String, modifiedAt: Date) -> SessionPhase {
        guard let tail = Self.readFileTail(atPath: path, maxBytes: 1024 * 1024) else {
            return Date().timeIntervalSince(modifiedAt) < processingStaleTimeoutSeconds
                ? .processing
                : .waitingForInput
        }

        let started = tail.range(of: "\"type\":\"task_started\"", options: .backwards)
        let completed = tail.range(of: "\"type\":\"task_complete\"", options: .backwards)
        let aborted = tail.range(of: "\"type\":\"turn_aborted\"", options: .backwards)
        let stopped = [completed, aborted]
            .compactMap { $0 }
            .max { $0.lowerBound < $1.lowerBound }

        if let stopped, started == nil || stopped.lowerBound > started!.lowerBound {
            return .waitingForInput
        }
        if started != nil {
            return .processing
        }
        return Date().timeIntervalSince(modifiedAt) < processingStaleTimeoutSeconds
            ? .processing
            : .waitingForInput
    }

    private nonisolated static func readFileTail(atPath path: String, maxBytes: UInt64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Periodic Status Check

    /// Start periodic status checking for all sessions
    func startPeriodicStatusCheck() {
        guard statusCheckTask == nil else { return }

        let intervalSeconds = statusCheckIntervalSeconds
        statusCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.recheckAllSessions()
            }
        }
        Self.logger.info("Started periodic status check (every \(intervalSeconds)s)")
    }

    /// Stop periodic status checking
    func stopPeriodicStatusCheck() {
        statusCheckTask?.cancel()
        statusCheckTask = nil
        Self.logger.info("Stopped periodic status check")
    }

    /// Recheck status of all active sessions
    private func recheckAllSessions() async {
        var stateChanged = false

        for (sessionId, session) in Array(sessions) {
            if session.phase == .ended {
                if session.source == .codex {
                    var updated = session
                    updated.phase = .waitingForInput
                    updated.pid = nil
                    updated.lastActivity = Date()
                    sessions[sessionId] = updated
                    Self.logger.info("Retaining ended Codex session \(sessionId.prefix(8), privacy: .public) for 30 minutes")
                } else {
                    sessions.removeValue(forKey: sessionId)
                    cancelPendingSync(sessionId: sessionId)
                }
                stateChanged = true
                continue
            }

            // A CLI process may remain alive indefinitely at its prompt, while
            // Codex desktop/vscode use a long-lived shared engine. In both cases
            // pid liveness alone would leave stale sessions on the island, so
            // archive every source after 30 minutes in a safe resting phase.
            let idle = Date().timeIntervalSince(session.lastActivity)
            let archivable = session.phase == .idle || session.phase == .waitingForInput
            if archivable && idle > idleArchiveSeconds {
                Self.logger.info("Archiving idle \(session.source.rawValue, privacy: .public) session \(sessionId.prefix(8), privacy: .public)")
                sessions.removeValue(forKey: sessionId)
                cancelPendingSync(sessionId: sessionId)
                if session.source == .codex {
                    await CodexConversationParser.shared.resetState(for: sessionId)
                }
                stateChanged = true
                continue
            }

            // Codex 的 PID 死亡不能刪列：CLI/exec 結束也必須進入完成狀態並保留
            // 30 分鐘。desktop/vscode 的 PID 本來就是共用常駐程序，不做存活檢查。
            let shouldCheckPid = session.source != .codex
                || (session.codexHost?.hasEphemeralProcess ?? true)
            if shouldCheckPid, let pid = session.pid {
                let isRunning = isProcessRunning(pid: pid)
                if !isRunning {
                    if session.source == .codex {
                        var updated = session
                        updated.pid = nil
                        if !archivable {
                            updated.phase = .waitingForInput
                            updated.lastActivity = Date()
                        }
                        sessions[sessionId] = updated
                        Self.logger.info("Codex process \(pid) ended; retaining completed session \(sessionId.prefix(8), privacy: .public) for 30 minutes")
                    } else {
                        Self.logger.info("Process \(pid) no longer running, ending session \(sessionId.prefix(8))")
                        sessions.removeValue(forKey: sessionId)
                        cancelPendingSync(sessionId: sessionId)
                    }
                    stateChanged = true
                    continue
                }
            }

            // 所有來源的 waitingForInput → idle 備援機制：Codex／Copilot 完全沒有
            // idle_prompt hook，而 Claude 也只會在特定條件下觸發；若無此機制，
            // 「開心」姿勢將永遠不會回到休息狀態。
            if session.phase == .waitingForInput {
                let idle = Date().timeIntervalSince(session.lastActivity)
                if idle > waitingForInputIdleTimeoutSeconds {
                    var updated = session
                    updated.phase = .idle
                    sessions[sessionId] = updated
                    stateChanged = true
                }
            }

            // 自動修復卡住的 processing／compacting：結束事件（Stop／PostCompact）可能完全遺失，
            // 因為 hook 是無法保證送達的平行處理程序，而按 Esc 中斷也完全不會觸發 Stop。
            // 僅在已知沒有工具執行中時才降級，避免提前中止長時間執行的 Bash／Task
            // （已收到 PreToolUse，但仍在等待 PostToolUse）。
            if session.phase.isActive,
               session.toolTracker.inProgress.isEmpty,
               Date().timeIntervalSince(session.lastActivity) > processingStaleTimeoutSeconds {
                Self.logger.info("Session \(sessionId.prefix(8), privacy: .public) stuck in \(String(describing: session.phase), privacy: .public) for >\(Int(self.processingStaleTimeoutSeconds))s with no running tool — demoting to waitingForInput")
                var updated = session
                if updated.phase.canTransition(to: .waitingForInput) {
                    updated.phase = .waitingForInput
                    updated.lastActivity = Date()
                    sessions[sessionId] = updated
                    stateChanged = true
                }
            }

            let needsSync: Bool
            switch session.phase {
            case .processing, .waitingForApproval:
                needsSync = true
            default:
                needsSync = false
            }
            if needsSync {
                scheduleFileSync(sessionId: sessionId, cwd: session.cwd)
            }
        }

        if stateChanged {
            publishState()
        }
    }

    /// Check if a process is still running
    private nonisolated func isProcessRunning(pid: Int) -> Bool {
        return kill(Int32(pid), 0) == 0
    }

    // MARK: - State Publishing

    private func publishState() {
        var values = Array(sessions.values)
        // Hide Codex sessions when detection is disabled.
        if !AppSettings.enableCodexDetection {
            values.removeAll { $0.source == .codex }
        }
        let sortedSessions = values.sorted { $0.projectName < $1.projectName }
        sessionsSubject.send(sortedSessions)
    }

    /// Force a state republish (e.g. after toggling Codex detection, which
    /// changes which sessions are filtered out in publishState).
    func refreshPublish() {
        publishState()
    }

    /// Set the per-session auto-approval override (nil = follow global).
    func setAutoApproveOverride(sessionId: String, _ value: Bool?) {
        guard var session = sessions[sessionId] else { return }
        session.autoApproveOverride = value
        sessions[sessionId] = session
        publishState()
    }

    // MARK: - Queries

    /// Get a specific session
    func session(for sessionId: String) -> SessionState? {
        sessions[sessionId]
    }

    /// Check if there's an active permission for a session
    func hasActivePermission(sessionId: String) -> Bool {
        guard let session = sessions[sessionId] else { return false }
        if case .waitingForApproval = session.phase {
            return true
        }
        return false
    }

    /// Get all current sessions
    func allSessions() -> [SessionState] {
        Array(sessions.values)
    }
}

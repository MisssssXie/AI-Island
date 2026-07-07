//
//  CodexConversationParser.swift
//  ClaudeIsland
//
//  Incrementally parses a Codex rollout JSONL (the `transcript_path` a hook
//  hands us) into the same ChatMessage / ToolResult / ConversationInfo shapes
//  the Claude ConversationParser produces, so SessionStore can reuse its whole
//  chatItem-building pipeline unchanged. See docs/codex-hook-samples/ for the
//  verified line formats.
//

import Foundation
import os.log

actor CodexConversationParser {
    static let shared = CodexConversationParser()

    nonisolated static let logger = Logger(subsystem: "com.claudeisland", category: "CodexParser")

    /// Fallback for rollout timestamps without a fractional-seconds component
    /// (the fractional formatter returns nil for those).
    private nonisolated static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Known machinery Codex injects as user-role turns. We match only these
    /// tags (not "any `<tag`") so real user messages opening with markup or
    /// generics — `<div>`, `<T>`, `<html>` — are kept.
    private nonisolated static let injectedTags: Set<String> = [
        "environment_context", "user_instructions", "permissions",
        "permissions_instructions", "skills_instructions", "plugins_instructions",
        "agents_instructions", "subagent_notification", "turn_aborted", "skill",
        "image", "system_reminder", "local-command-caveat",
    ]

    private nonisolated static func isInjectedUserText(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("<") else { return false }
        var tag = ""
        for ch in trimmed.dropFirst() {
            if ch == ">" || ch == " " || ch == "\n" || ch == "\t" || ch == "/" { break }
            tag.append(ch)
        }
        return injectedTags.contains(tag.lowercased())
    }

    /// Per-session incremental parse state, keyed by sessionId.
    private var states: [String: State] = [:]

    private struct State {
        var lastOffset: UInt64 = 0
        var path: String?
        /// Bumped whenever the transcript is reset (file swapped/truncated) so
        /// regenerated message ids never collide with ids already in chatItems.
        var epoch: Int = 0
        var messages: [ChatMessage] = []
        var seenToolIds: Set<String> = []
        var toolIdToName: [String: String] = [:]
        var completedToolIds: Set<String> = []
        var toolResults: [String: ConversationParser.ToolResult] = [:]
        var structuredResults: [String: ToolResultData] = [:]
        var usage: UsageInfo = UsageInfo()
        var firstUserMessage: String?
        var lastUserMessage: String?
        var lastUserMessageDate: Date?
        var lastAssistantMessage: String?
        var lastAgentMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?
        var seq: Int = 0
        var interruptPending: Bool = false
    }

    struct IncrementalResult {
        let newMessages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ConversationParser.ToolResult]
        let structuredResults: [String: ToolResultData]
        let conversationInfo: ConversationInfo
        let interruptDetected: Bool
    }

    // MARK: - Public API (mirrors ConversationParser, keyed by transcriptPath)

    func parseIncremental(sessionId: String, transcriptPath: String) -> IncrementalResult {
        var state = states[sessionId] ?? State()
        let newMessages = parseNewLines(path: transcriptPath, state: &state)
        let interrupt = state.interruptPending
        state.interruptPending = false
        states[sessionId] = state

        return IncrementalResult(
            newMessages: newMessages,
            completedToolIds: state.completedToolIds,
            toolResults: state.toolResults,
            structuredResults: state.structuredResults,
            conversationInfo: buildInfo(state),
            interruptDetected: interrupt
        )
    }

    func parseFullConversation(sessionId: String, transcriptPath: String) -> [ChatMessage] {
        var state = states[sessionId] ?? State()
        _ = parseNewLines(path: transcriptPath, state: &state)
        states[sessionId] = state
        return state.messages
    }

    func conversationInfo(sessionId: String, transcriptPath: String) -> ConversationInfo {
        // Build from cached state — do NOT parse again here. The caller
        // (scheduleFileSync / loadHistory) has already parsed up to EOF; a second
        // parse would advance the shared offset and swallow lines that arrived in
        // between, so they'd never become chat items.
        buildInfo(states[sessionId] ?? State())
    }

    func completedToolIds(for sessionId: String) -> Set<String> {
        states[sessionId]?.completedToolIds ?? []
    }

    func toolResults(for sessionId: String) -> [String: ConversationParser.ToolResult] {
        states[sessionId]?.toolResults ?? [:]
    }

    func structuredResults(for sessionId: String) -> [String: ToolResultData] {
        states[sessionId]?.structuredResults ?? [:]
    }

    func resetState(for sessionId: String) {
        states.removeValue(forKey: sessionId)
    }

    // MARK: - Parsing

    private func parseNewLines(path: String, state: inout State) -> [ChatMessage] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        let fileSize: UInt64
        do { fileSize = try handle.seekToEnd() } catch { return [] }

        // Transcript swapped (resume) or truncated -> reparse from scratch, but
        // bump the epoch so regenerated message ids can't collide with ids
        // already sitting in the session's chatItems.
        if (state.path != nil && state.path != path) || fileSize < state.lastOffset {
            let nextEpoch = state.epoch + 1
            state = State()
            state.epoch = nextEpoch
        }
        state.path = path

        if fileSize == state.lastOffset {
            return []
        }
        do { try handle.seek(toOffset: state.lastOffset) } catch { return state.messages }

        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        // Only consume up to the last newline — a trailing fragment is a
        // half-written record; leave its bytes for the next read so we don't
        // skip it (and its completion) permanently.
        guard let lastNewline = content.lastIndex(of: "\n") else {
            return []
        }
        let complete = content[...lastNewline]

        var newMessages: [ChatMessage] = []
        for line in complete.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            if let msg = handleLine(obj, state: &state) {
                newMessages.append(msg)
                state.messages.append(msg)
            }
        }

        // Advance only past the bytes we actually consumed.
        state.lastOffset += UInt64(complete.utf8.count)
        return newMessages
    }

    /// Returns a ChatMessage when the line produces visible chat content.
    private func handleLine(_ obj: [String: Any], state: inout State) -> ChatMessage? {
        let type = obj["type"] as? String
        let payload = obj["payload"] as? [String: Any] ?? [:]
        let payloadType = payload["type"] as? String
        let timestamp = Self.parseTimestamp(obj["timestamp"] as? String) ?? Date()

        switch (type, payloadType) {
        case ("event_msg", "token_count"):
            applyTokenCount(payload, state: &state)
            return nil

        case ("event_msg", "task_complete"):
            if let last = payload["last_agent_message"] as? String, !last.isEmpty {
                state.lastAgentMessage = last
            }
            return nil

        case ("event_msg", "turn_aborted"):
            state.interruptPending = true
            return nil

        case ("response_item", "message"):
            return handleMessage(payload, timestamp: timestamp, state: &state)

        case ("response_item", "reasoning"):
            return handleReasoning(payload, timestamp: timestamp, state: &state)

        case ("response_item", "function_call"):
            return handleFunctionCall(payload, timestamp: timestamp, state: &state, argsKey: "arguments", argsAreJSON: true)

        case ("response_item", "custom_tool_call"):
            return handleFunctionCall(payload, timestamp: timestamp, state: &state, argsKey: "input", argsAreJSON: false)

        case ("response_item", "function_call_output"),
             ("response_item", "custom_tool_call_output"):
            handleToolOutput(payload, state: &state)
            return nil

        default:
            return nil
        }
    }

    private func applyTokenCount(_ payload: [String: Any], state: inout State) {
        guard let info = payload["info"] as? [String: Any],
              let usage = info["total_token_usage"] as? [String: Any] else { return }
        // total_token_usage is cumulative — last write wins.
        state.usage.inputTokens = (usage["input_tokens"] as? Int) ?? state.usage.inputTokens
        state.usage.outputTokens = (usage["output_tokens"] as? Int) ?? state.usage.outputTokens
        state.usage.cacheReadTokens = (usage["cached_input_tokens"] as? Int) ?? state.usage.cacheReadTokens
    }

    private func handleMessage(_ payload: [String: Any], timestamp: Date, state: inout State) -> ChatMessage? {
        let role = payload["role"] as? String ?? ""
        // Drop system-injected turns entirely.
        guard role == "user" || role == "assistant" else { return nil }

        let text = extractText(from: payload["content"])
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if role == "user" {
            // Skip environment_context / instructions / notification injections.
            if Self.isInjectedUserText(trimmed) {
                return nil
            }
            if state.firstUserMessage == nil {
                state.firstUserMessage = trimmed
            }
            state.lastUserMessage = Self.truncate(trimmed)
            state.lastUserMessageDate = timestamp
            state.lastMessageRole = "user"
            return message(role: .user, text: text, timestamp: timestamp, state: &state)
        } else {
            state.lastAssistantMessage = Self.truncate(trimmed)
            state.lastMessageRole = "assistant"
            return message(role: .assistant, text: text, timestamp: timestamp, state: &state)
        }
    }

    private func handleReasoning(_ payload: [String: Any], timestamp: Date, state: inout State) -> ChatMessage? {
        guard let summary = payload["summary"] as? [[String: Any]] else { return nil }
        let text = summary.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        state.seq += 1
        return ChatMessage(
            id: "codex-\(state.epoch)-\(state.seq)",
            role: .assistant,
            timestamp: timestamp,
            content: [.thinking(text)]
        )
    }

    private func handleFunctionCall(_ payload: [String: Any], timestamp: Date, state: inout State, argsKey: String, argsAreJSON: Bool) -> ChatMessage? {
        guard let callId = payload["call_id"] as? String,
              let name = payload["name"] as? String else { return nil }
        guard state.seenToolIds.insert(callId).inserted else { return nil }
        state.toolIdToName[callId] = name

        var input: [String: String] = [:]
        if argsAreJSON, let argsStr = payload[argsKey] as? String,
           let d = argsStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in obj {
                input[k] = Self.stringify(v)
            }
        } else if let raw = payload[argsKey] as? String {
            // custom_tool_call (e.g. apply_patch) — input is a raw string.
            if name == "apply_patch", let file = Self.applyPatchFile(from: raw) {
                input["file_path"] = file
            }
            input["input"] = String(raw.prefix(2000))
        }

        state.lastMessageRole = "tool"
        state.lastToolName = name

        state.seq += 1
        return ChatMessage(
            id: "codex-\(state.epoch)-\(state.seq)",
            role: .assistant,
            timestamp: timestamp,
            content: [.toolUse(ToolUseBlock(id: callId, name: name, input: input))]
        )
    }

    private func handleToolOutput(_ payload: [String: Any], state: inout State) {
        guard let callId = payload["call_id"] as? String else { return }
        let output = payload["output"] as? String ?? ""
        // Codex reports the exit status inside the output text ("Process exited
        // with code N" / "Exit code: N") — a non-zero code is an error.
        let isError = Self.exitIndicatesError(output)
        state.completedToolIds.insert(callId)
        state.toolResults[callId] = ConversationParser.ToolResult(
            content: output, stdout: isError ? nil : output, stderr: isError ? output : nil, isError: isError
        )
        // Shell-style tools render nicely through the bash result view.
        let name = state.toolIdToName[callId] ?? ""
        if name == "exec_command" || name == "shell" || name == "local_shell" {
            state.structuredResults[callId] = .bash(BashResult(
                stdout: isError ? "" : output,
                stderr: isError ? output : "",
                interrupted: false,
                isImage: false,
                returnCodeInterpretation: isError ? "Command exited with a non-zero status" : nil,
                backgroundTaskId: nil
            ))
        }
    }

    /// Detect a non-zero exit from Codex tool output text.
    private static func exitIndicatesError(_ output: String) -> Bool {
        let patterns = [#"exited with code (\d+)"#, #"[Ee]xit code:\s*(\d+)"#]
        let range = NSRange(output.startIndex..., in: output)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            if let m = regex.firstMatch(in: output, range: range), m.numberOfRanges >= 2,
               let r = Range(m.range(at: 1), in: output), let code = Int(output[r]) {
                return code != 0
            }
        }
        return false
    }

    // MARK: - Helpers

    private func message(role: ChatRole, text: String, timestamp: Date, state: inout State) -> ChatMessage {
        state.seq += 1
        return ChatMessage(
            id: "codex-\(state.epoch)-\(state.seq)",
            role: role,
            timestamp: timestamp,
            content: [.text(text)]
        )
    }

    private func buildInfo(_ state: State) -> ConversationInfo {
        let lastMessage: String? = state.lastMessageRole == "user"
            ? state.lastUserMessage
            : (state.lastAgentMessage.map { Self.truncate($0) } ?? state.lastAssistantMessage)
        return ConversationInfo(
            summary: state.firstUserMessage.map { Self.truncate($0, max: 100) },
            lastMessage: lastMessage,
            lastMessageRole: state.lastMessageRole,
            lastToolName: state.lastToolName,
            firstUserMessage: state.firstUserMessage,
            lastUserMessage: state.lastUserMessage,
            lastUserMessageDate: state.lastUserMessageDate,
            usage: state.usage
        )
    }

    /// Concatenate the text of a `content` block array (input_text/output_text).
    private func extractText(from content: Any?) -> String {
        guard let blocks = content as? [[String: Any]] else {
            return content as? String ?? ""
        }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func stringify(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        case let b as Bool: return b ? "true" : "false"
        case let arr as [Any]:
            return arr.map { stringify($0) }.joined(separator: " ")
        default:
            if let data = try? JSONSerialization.data(withJSONObject: value),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return String(describing: value)
        }
    }

    /// Pull the target file out of an apply_patch body (`*** Update/Add/Delete File: X`).
    private static func applyPatchFile(from patch: String) -> String? {
        for line in patch.components(separatedBy: "\n") {
            let markers = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
            for m in markers where line.hasPrefix(m) {
                return String(line.dropFirst(m.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func truncate(_ text: String, max: Int = 80) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        return collapsed.count > max ? String(collapsed.prefix(max)) + "…" : collapsed
    }

    private static func parseTimestamp(_ str: String?) -> Date? {
        guard let str else { return nil }
        return ConversationParser.isoFormatter.date(from: str) ?? isoFormatterNoFrac.date(from: str)
    }
}

#!/usr/bin/env python3
"""
Codex 多 thread 歸併閘門的假事件測試（打 /tmp/claude-island.sock）。

驗證 SessionStore 的「同一個邏輯 session 整合為一列」設計：
  1. user thread（thread_source="user"）→ 建列
  2. sub-agent thread 的 UserPromptSubmit/PreToolUse（帶 agent_id）→ 不建列，fold 進父列
  3. sub-agent thread 的 PermissionRequest → 掛到父列（父列 waitingForApproval），
     按 Allow/Deny 後父列回 processing，island 上不得出現 sub-agent 自己的列
  4. 內部 thread（thread_source="memory_consolidation"，無 agent_id）→ 不建列
  5. 無 rollout 的 helper thread → 不建列

用法：
  1. 先確認要測的 AI Island 版本正在跑（它持有 socket）
  2. python3 scripts/test-codex-threads.py
  3. 看 island UI ＋ log：
     log stream --predicate 'subsystem == "com.claudeisland"' --level debug
  4. 測完在 island 上把測試列 archive 掉

預期 log 關鍵字：
  - "Routing Codex sub-agent permission ... → parent ..."
  - "Ignoring ... for Codex non-user thread ... folded into parent"
  - "Holding waitingForApproval on ..."（若父 Stop 在授權未決時抵達）
"""
import json
import os
import socket
import sys
import tempfile
import time
import uuid

SOCKET_PATH = "/tmp/claude-island.sock"

# 測試用假 rollout 放在暫存目錄（島上 resolveCodexRolloutPath 會用
# transcript_path 直接檢查存在性，所以不必放進 ~/.codex/sessions）
WORK = tempfile.mkdtemp(prefix="ai-island-codex-test-")
CWD = "/tmp/ai-island-test-project"

PARENT_ID = str(uuid.uuid4())
CHILD_ID = str(uuid.uuid4())
MEMORY_ID = str(uuid.uuid4())
HELPER_ID = str(uuid.uuid4())


def write_rollout(session_id, thread_source, parent_thread_id=None):
    path = os.path.join(WORK, f"rollout-test-{session_id}.jsonl")
    payload = {
        "session_id": session_id,
        "id": session_id,
        "timestamp": "2026-07-21T10:00:00.000Z",
        "cwd": CWD,
        "originator": "Codex Desktop",
        "cli_version": "0.145.0-alpha.18",
        "thread_source": thread_source,
    }
    if parent_thread_id:
        payload["parent_thread_id"] = parent_thread_id
        payload["source"] = {"subagent": {"thread_spawn": {
            "parent_thread_id": parent_thread_id, "depth": 1,
            "agent_nickname": "TestAgent", "agent_role": "default"}}}
    else:
        payload["source"] = "vscode"
    with open(path, "w") as f:
        f.write(json.dumps({"type": "session_meta", "payload": payload}) + "\n")
    return path


def send(state, wait_response=False):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(300 if wait_response else 5)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps(state).encode())
    if wait_response:
        print(f"    [等待 island 上的 Allow/Deny…]")
        data = sock.recv(4096)
        sock.close()
        return json.loads(data.decode()) if data else None
    sock.close()
    return None


def event(session_id, name, status, transcript=None, **extra):
    state = {
        "session_id": session_id, "cwd": CWD, "event": name, "status": status,
        "pid": os.getpid(), "tty": None, "source": "codex", "codex_host": "desktop",
    }
    if transcript:
        state["transcript_path"] = transcript
    state.update(extra)
    return state


def main():
    if not os.path.exists(SOCKET_PATH):
        sys.exit(f"socket 不存在：{SOCKET_PATH}（AI Island 沒在跑？）")

    parent_rollout = write_rollout(PARENT_ID, "user")
    child_rollout = write_rollout(CHILD_ID, "subagent", parent_thread_id=PARENT_ID)
    memory_rollout = write_rollout(MEMORY_ID, "memory_consolidation")

    print(f"parent  = {PARENT_ID[:8]}  (user thread，應出現一列)")
    print(f"child   = {CHILD_ID[:8]}  (sub-agent，永不自成一列)")
    print(f"memory  = {MEMORY_ID[:8]}  (內部 thread，永不出現)")
    print(f"helper  = {HELPER_ID[:8]}  (無 rollout，永不出現)")
    print()

    print("[1] parent UserPromptSubmit → 應建一列 ai-island-test-project (processing)")
    send(event(PARENT_ID, "UserPromptSubmit", "processing", parent_rollout))
    time.sleep(1)

    print("[2] child UserPromptSubmit（帶 agent_id）→ 不得多列")
    send(event(CHILD_ID, "UserPromptSubmit", "processing", child_rollout, agent_id=CHILD_ID))
    time.sleep(0.5)

    print("[3] child PreToolUse（帶 agent_id）→ 不得多列")
    send(event(CHILD_ID, "PreToolUse", "running_tool", child_rollout,
               agent_id=CHILD_ID, tool="exec_command",
               tool_input={"cmd": "echo test-child-tool"}))
    time.sleep(0.5)

    print("[4] memory thread UserPromptSubmit（無 agent_id，靠 rollout 判別）→ 不得多列")
    send(event(MEMORY_ID, "UserPromptSubmit", "processing", memory_rollout))
    time.sleep(0.5)

    print("[5] helper thread UserPromptSubmit（無 rollout）→ 不得多列")
    send(event(HELPER_ID, "UserPromptSubmit", "processing"))
    time.sleep(0.5)

    print("[6] parent Stop → 父列變 Ready")
    send(event(PARENT_ID, "Stop", "waiting_for_input", parent_rollout))
    time.sleep(1)

    print("[7] child PermissionRequest → 授權應出現在【父列】上（不得多列）")
    resp = send(event(CHILD_ID, "PermissionRequest", "waiting_for_approval",
                      child_rollout, agent_id=CHILD_ID, tool="exec_command",
                      tool_input={"cmd": "echo need-approval"}),
                wait_response=True)
    print(f"    island 回覆：{resp}")
    time.sleep(1)

    print("[8] 決定後父列應回 processing；island 上不得有 child/memory/helper 的列")
    print()
    print("完成。請目視 island：整場測試應只有一列（ai-island-test-project）。")
    print(f"假 rollout 在 {WORK}，測完可刪。")


if __name__ == "__main__":
    main()

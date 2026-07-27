#!/usr/bin/env python3
"""
Codex 多 thread 歸併閘門的假事件測試（打 /tmp/claude-island.sock）。

驗證 SessionStore 的「同一個邏輯 session 整合為一列」設計：
  1. user thread 的 SessionStart 或第一個 UserPromptSubmit → 建列
  2. 單獨的 PermissionRequest／工具／Stop 事件 → 不得建列
  3. sub-agent thread 的 UserPromptSubmit/PreToolUse
     （Codex 0.145 格式：session_id=父、agent_id=子）→ 不建列，fold 進父列
  4. alternate internal hook（session_id=父、無 agent_id、rollout=子）
     → 不得把父 id 誤記成 sub-agent
  5. sub-agent thread 的 PermissionRequest → 只更新已存在的父列，
     按 Allow/Deny 後父列回 processing，island 上不得出現 sub-agent 自己的列
  6. rollout 已建立但 session_meta 稍後才寫完 → 等待解析後才建列
  7. 內部 thread（thread_source="memory_consolidation"，無 agent_id）→ 不建列
  8. 無 rollout 的 helper thread → 不建列
  9. parent Stop → 完成列保留 30 分鐘

用法：
  1. 先確認要測的 AI Island 版本正在跑（它持有 socket）
  2. python3 scripts/test-codex-threads.py
  3. 看 island UI ＋ log：
     log stream --predicate 'subsystem == "com.claudeisland"' --level debug
  4. 測完在 island 上把測試列 archive 掉

預期 log 關鍵字：
  - "event cannot create a chat row"
  - "Routing inline Codex sub-agent permission ... → parent ..."
  - "Ignoring ... inline Codex sub-agent ... folded into parent"
"""
import json
import os
import socket
import sys
import tempfile
import threading
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
APPROVAL_ONLY_ID = str(uuid.uuid4())


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
    approval_only_rollout = write_rollout(APPROVAL_ONLY_ID, "user")

    print(f"parent  = {PARENT_ID[:8]}  (user thread，應出現一列)")
    print(f"child   = {CHILD_ID[:8]}  (sub-agent，永不自成一列)")
    print(f"memory  = {MEMORY_ID[:8]}  (內部 thread，永不出現)")
    print(f"helper  = {HELPER_ID[:8]}  (無 rollout，永不出現)")
    print(f"approval= {APPROVAL_ONLY_ID[:8]}  (只有核准事件，永不出現)")
    print()

    print("[1] approval-only PermissionRequest → 應立即回 ask，且不得建列")
    approval_response = send(
        event(
            APPROVAL_ONLY_ID,
            "PermissionRequest",
            "waiting_for_approval",
            approval_only_rollout,
            tool="exec_command",
            tool_input={"cmd": "echo approval-only"},
        ),
        wait_response=True,
    )
    print(f"    island 回覆：{approval_response}")
    time.sleep(0.5)

    print("[2] parent SessionStart → 應建一列 ai-island-test-project (waiting)")
    # 模擬 rollout writer race：檔案存在，但第一行只寫了一半；120 ms 後
    # 才補成合法 session_meta。SessionStore 應等待 metadata，而不是 fail-open。
    with open(parent_rollout, "w") as f:
        f.write('{"type":"session_meta","payload":')
    threading.Timer(
        0.12,
        lambda: write_rollout(PARENT_ID, "user"),
    ).start()
    send(event(PARENT_ID, "SessionStart", "waiting_for_input", parent_rollout))
    time.sleep(1)

    print("[3] parent 第一個 UserPromptSubmit → 同一列轉 processing")
    send(event(PARENT_ID, "UserPromptSubmit", "processing", parent_rollout))
    time.sleep(1)

    print("[4] child UserPromptSubmit（session_id=父、agent_id=子）→ 不得多列")
    send(event(PARENT_ID, "UserPromptSubmit", "processing", child_rollout, agent_id=CHILD_ID))
    time.sleep(0.5)

    print("[5] child PreToolUse（session_id=父、agent_id=子）→ 不得多列")
    send(event(PARENT_ID, "PreToolUse", "running_tool", child_rollout,
               agent_id=CHILD_ID, tool="exec_command",
               tool_input={"cmd": "echo test-child-tool"}))
    time.sleep(0.5)

    print("[6] alternate child hook（session_id=父、無 agent_id、rollout=子）→ 不得汙染父 id")
    send(event(PARENT_ID, "UserPromptSubmit", "processing", child_rollout))
    time.sleep(0.5)

    print("[7] alternate hook 後再送 parent prompt → 原父列必須正常 processing")
    send(event(PARENT_ID, "UserPromptSubmit", "processing", parent_rollout))
    time.sleep(0.5)

    print("[8] memory thread UserPromptSubmit（無 agent_id，靠 rollout 判別）→ 不得多列")
    send(event(MEMORY_ID, "UserPromptSubmit", "processing", memory_rollout))
    time.sleep(0.5)

    print("[9] helper thread UserPromptSubmit（無 rollout）→ 不得多列")
    send(event(HELPER_ID, "UserPromptSubmit", "processing"))
    time.sleep(0.5)

    print("[10] parent Stop → 父列變 Ready，但不得移除")
    send(event(PARENT_ID, "Stop", "waiting_for_input", parent_rollout))
    time.sleep(1)

    print("[11] child PermissionRequest（session_id=父）→ 只更新【既有父列】，不得多列")
    resp = send(event(PARENT_ID, "PermissionRequest", "waiting_for_approval",
                      child_rollout, agent_id=CHILD_ID, tool="exec_command",
                      tool_input={"cmd": "echo need-approval"}),
                wait_response=True)
    print(f"    island 回覆：{resp}")
    time.sleep(1)

    print("[12] 決定後父列應回 processing；不得有 child/memory/helper/approval 列")
    print("[13] 再送父 UserPromptSubmit → 父列必須繼續顯示")
    send(event(PARENT_ID, "UserPromptSubmit", "processing", parent_rollout))
    time.sleep(1)
    print("[14] parent Stop → 最終只留父列，並從現在開始保留 30 分鐘")
    send(event(PARENT_ID, "Stop", "waiting_for_input", parent_rollout))
    time.sleep(1)
    print()
    print("完成。請目視 island：整場測試只能有一列（ai-island-test-project）。")
    print(f"假 rollout 在 {WORK}，測完可刪。")


if __name__ == "__main__":
    main()

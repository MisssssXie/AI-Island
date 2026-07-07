#!/usr/bin/env python3
"""
Claude Island Hook
- Sends session state to ClaudeIsland.app via Unix socket
- For PermissionRequest: waits for user decision from the app

Serves two agents from one script:
- Claude Code (default, no args) — original behaviour, unchanged.
- OpenAI Codex (`--source codex`) — same socket protocol, plus a `source`
  marker, the rollout `transcript_path`, and process-tree host detection.
"""
import json
import os
import socket
import sys

SOCKET_PATH = "/tmp/claude-island.sock"
TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions


def _parse_source():
    """Read `--source <name>` / `--source=<name>` from argv (default claude)."""
    argv = sys.argv
    for i, arg in enumerate(argv):
        if arg == "--source" and i + 1 < len(argv):
            return argv[i + 1]
        if arg.startswith("--source="):
            return arg.split("=", 1)[1]
    return "claude"


SOURCE = _parse_source()


def get_tty():
    """Get the TTY of the Claude process (parent)"""
    import subprocess

    # Get parent PID (Claude process)
    ppid = os.getppid()

    # Try to get TTY from ps command for the parent process
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2
        )
        tty = result.stdout.strip()
        if tty and tty != "??" and tty != "-":
            # ps returns just "ttys001", we need "/dev/ttys001"
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except Exception:
        pass

    # Fallback: try current process stdin/stdout
    try:
        return os.ttyname(sys.stdin.fileno())
    except (OSError, AttributeError):
        pass
    try:
        return os.ttyname(sys.stdout.fileno())
    except (OSError, AttributeError):
        pass
    return None


def _build_process_map():
    """pid -> (ppid, full_command) for the whole process tree, in one `ps` call."""
    import subprocess

    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,ppid=,command="],
            capture_output=True,
            text=True,
            timeout=3,
        )
    except Exception:
        return {}

    procs = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        cmd = parts[2] if len(parts) > 2 else ""
        procs[pid] = (ppid, cmd)
    return procs


def _walk_for_codex(tty):
    """Walk up the ancestor chain from this hook to find the owning Codex
    process and classify its host. Returns (pid, host).

    - Codex.app/Contents in an ancestor command -> desktop (long-lived engine)
    - .vscode + codex -> vscode
    - a `codex` binary ancestor -> cli (has tty) or exec (no tty)
    Falls back to the direct parent when nothing matches (old/unknown codex)."""
    procs = _build_process_map()
    start = os.getppid()
    has_tty = bool(tty) and tty not in ("??", "-", "")

    cur = start
    codex_pid = None
    seen = 0
    while cur and cur > 1 and seen < 15:
        entry = procs.get(cur)
        if entry is None:
            break
        ppid, cmd = entry
        lowered = cmd.lower()
        if "codex.app/contents" in lowered:
            return cur, "desktop"
        if ".vscode" in lowered and "codex" in lowered:
            return cur, "vscode"
        if codex_pid is None:
            first = cmd.split(None, 1)[0] if cmd else ""
            base = os.path.basename(first)
            if base == "codex" or base.startswith("codex-"):
                codex_pid = cur
        cur = ppid
        seen += 1

    if codex_pid is not None:
        return codex_pid, ("cli" if has_tty else "exec")
    return start, ("cli" if has_tty else "exec")


def _codex_cache_path(session_id):
    safe = "".join(c for c in session_id if c.isalnum() or c in "-_") or "unknown"
    return "/tmp/claude-island-codex-%s.json" % safe


def detect_codex_host_and_pid(tty, session_id):
    """Cached wrapper around _walk_for_codex: the owning pid/host is stable for a
    session, so we compute it once and reuse it — avoids a full `ps` scan on
    every hook event. The cached pid is revalidated with kill(pid, 0) so a
    resumed session (new pid) recomputes."""
    cache = _codex_cache_path(session_id)
    try:
        with open(cache) as f:
            data = json.load(f)
        pid = int(data["pid"])
        host = data["host"]
        try:
            os.kill(pid, 0)
            return pid, host  # still alive
        except ProcessLookupError:
            pass  # dead -> recompute below
        except PermissionError:
            return pid, host  # alive, just not ours
    except Exception:
        pass

    pid, host = _walk_for_codex(tty)
    try:
        with open(cache, "w") as f:
            json.dump({"pid": pid, "host": host}, f)
    except Exception:
        pass
    return pid, host


def send_event(state):
    """Send event to app, return response if any"""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode())

        # For permission requests, wait for response
        if state.get("status") == "waiting_for_approval":
            response = sock.recv(4096)
            sock.close()
            if response:
                return json.loads(response.decode())
        else:
            sock.close()

        return None
    except (socket.error, OSError, json.JSONDecodeError):
        return None


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")
    tool_input = data.get("tool_input", {})

    # Get process info. For Codex, walk the ancestor chain to find the owning
    # engine pid + host; for Claude keep the original naive getppid() behaviour.
    tty = get_tty()
    if SOURCE == "codex":
        owner_pid, codex_host = detect_codex_host_and_pid(tty, session_id)
    else:
        owner_pid = os.getppid()
        codex_host = None

    # Build state object
    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": owner_pid,
        "tty": tty,
    }

    # Codex-only fields (absent on Claude payloads -> Swift treats as .claude)
    if SOURCE == "codex":
        state["source"] = "codex"
        transcript_path = data.get("transcript_path")
        if transcript_path:
            state["transcript_path"] = transcript_path
        if codex_host:
            state["codex_host"] = codex_host

    # Map events to status
    if event == "UserPromptSubmit":
        # User just sent a message - Claude is now processing
        state["status"] = "processing"

    elif event == "PreToolUse":
        state["status"] = "running_tool"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id to Swift for caching
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PostToolUse":
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # Send tool_use_id so Swift can cancel the specific pending permission
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PostToolUseFailure":
        # Tool errored or was interrupted — main session continues processing
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        state["tool_error"] = data.get("error") or data.get("message")
        tool_use_id_from_event = data.get("tool_use_id")
        if tool_use_id_from_event:
            state["tool_use_id"] = tool_use_id_from_event

    elif event == "PermissionDenied":
        # Auto-mode classifier denied a tool call — surface to the app so the
        # user can see what was blocked instead of a silent skip
        state["status"] = "processing"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        state["denial_reason"] = data.get("reason") or data.get("message")

    elif event == "PermissionRequest":
        # This is where we can control the permission
        state["status"] = "waiting_for_approval"
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        # tool_use_id lookup handled by Swift-side cache from PreToolUse

        # Send to app and wait for decision
        response = send_event(state)

        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")

            if decision == "allow":
                # Output JSON to approve
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"},
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "deny":
                # Output JSON to deny
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via ClaudeIsland",
                        },
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

        # No response or "ask" - let Claude Code show its normal UI
        sys.exit(0)

    elif event == "Notification":
        notification_type = data.get("notification_type")
        # Skip permission_prompt - PermissionRequest hook handles this with better info
        if notification_type == "permission_prompt":
            sys.exit(0)
        elif notification_type == "idle_prompt":
            state["status"] = "waiting_for_input"
        else:
            state["status"] = "notification"
        state["notification_type"] = notification_type
        state["message"] = data.get("message")

    elif event == "Stop":
        state["status"] = "waiting_for_input"

    elif event == "StopFailure":
        # Turn ended via API error (rate limit, auth, billing). Mark waiting
        # so the user sees it's done (not stuck), with the error surfaced
        state["status"] = "waiting_for_input"
        state["stop_error"] = data.get("error") or data.get("message")

    elif event == "SubagentStart":
        # A subagent task is beginning — main session is still processing
        state["status"] = "processing"

    elif event == "SubagentStop":
        # SubagentStop fires when a subagent completes - main session continues processing
        state["status"] = "processing"

    elif event == "SessionStart":
        # New session starts waiting for user input
        state["status"] = "waiting_for_input"

    elif event == "SessionEnd":
        state["status"] = "ended"

    elif event == "PreCompact":
        # Context is being compacted (manual or auto)
        state["status"] = "compacting"

    elif event == "PostCompact":
        # Compaction finished — return to processing so UI exits .compacting phase
        state["status"] = "processing"

    else:
        state["status"] = "unknown"

    # Send to socket (fire and forget for non-permission events)
    send_event(state)


if __name__ == "__main__":
    main()

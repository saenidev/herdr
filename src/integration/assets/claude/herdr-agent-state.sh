#!/bin/sh
# installed by herdr
# managed by herdr; reinstalling or updating the integration overwrites this file.
# add custom hooks beside this file instead of editing it.
# HERDR_INTEGRATION_ID=claude
# HERDR_INTEGRATION_VERSION=11

set -eu

action="${1:-}"
hook_input_file="$(mktemp "${TMPDIR:-/tmp}/herdr-claude-hook.XXXXXX")" || exit 0
trap 'rm -f "$hook_input_file"' EXIT HUP INT TERM
cat >"$hook_input_file" 2>/dev/null || true

case "$action" in
  session) ;;
  *) exit 0 ;;
esac

[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_SOCKET_PATH:-}" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

HERDR_ACTION="$action" HERDR_HOOK_INPUT_FILE="$hook_input_file" python3 - <<'PY'
import json
import os
import random
import re
import socket
import subprocess
import time

source = "herdr:claude"
action = os.environ.get("HERDR_ACTION", "")
pane_id = os.environ.get("HERDR_PANE_ID")
socket_path = os.environ.get("HERDR_SOCKET_PATH")
hook_input_file = os.environ.get("HERDR_HOOK_INPUT_FILE")

if not pane_id or not socket_path:
    raise SystemExit(0)

hook_input = {}
if hook_input_file:
    try:
        with open(hook_input_file, encoding="utf-8") as handle:
            content = handle.read()
        if content.strip():
            hook_input = json.loads(content)
    except Exception:
        hook_input = {}

if "CURSOR_VERSION" in os.environ or "cursor_version" in hook_input:
    raise SystemExit(0)
hook_event_name = str(hook_input.get("hook_event_name") or "")
if hook_event_name != "SessionStart":
    raise SystemExit(0)
is_subagent = bool(hook_input.get("agent_id"))
if is_subagent:
    raise SystemExit(0)
request_id = f"{source}:{int(time.time() * 1000)}:{random.randrange(1_000_000):06d}"
report_seq = time.time_ns()
session_id = hook_input.get("session_id")
agent_session_id = session_id if isinstance(session_id, str) and session_id else None
transcript_path = hook_input.get("transcript_path")
agent_session_path = transcript_path if isinstance(transcript_path, str) and transcript_path else None
session_start_source = hook_input.get("source") if hook_event_name == "SessionStart" else None
if not isinstance(session_start_source, str) or not session_start_source:
    session_start_source = None


def remote_control_session_id():
    # `claude remote-control` spawns each session as a child process that
    # carries its remote session id as `--session-id`. Walk up from this hook
    # to that child; the hook may run under one or more shells.
    pid = os.getppid()
    for _ in range(8):
        if pid <= 1:
            return None
        try:
            line = subprocess.run(
                ["ps", "-o", "ppid=", "-o", "args=", "-p", str(pid)],
                capture_output=True,
                text=True,
                timeout=1,
            ).stdout.strip()
        except Exception:
            return None
        parent, _, args = line.partition(" ")
        match = re.search(r"--session-id[ =]((?:cse|session)_[A-Za-z0-9]+)(?:\s|$)", args)
        if match:
            return match.group(1)
        try:
            pid = int(parent)
        except ValueError:
            return None
    return None


params = {
    "pane_id": pane_id,
    "source": source,
    "agent": "claude",
    "seq": report_seq,
}
if os.environ.get("CLAUDE_CODE_ENVIRONMENT_KIND") == "bridge":
    # A Remote Control session is resumed by reattaching to it, not with
    # `claude --resume <local id>`, so report the reattach command instead.
    remote_session_id = remote_control_session_id()
    if not remote_session_id:
        raise SystemExit(0)
    params["resume_argv"] = ["claude", "remote-control", "--session-id", remote_session_id]
elif agent_session_id:
    params["agent_session_id"] = agent_session_id
    if agent_session_path:
        params["agent_session_path"] = agent_session_path
else:
    raise SystemExit(0)
if session_start_source:
    params["session_start_source"] = session_start_source
request = {
    "id": request_id,
    "method": "pane.report_agent_session",
    "params": params,
}


def send(request):
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(0.5)
        client.connect(socket_path)
        client.sendall((json.dumps(request) + "\n").encode())
        try:
            response = client.recv(4096)
        except Exception:
            response = b""
        client.close()
        return response
    except Exception:
        return b""


# Remote Control spawns its first session right away, sometimes before Herdr
# has identified Claude in the pane, and Herdr refuses a resume command until
# then. Retry briefly in that case.
for attempt in range(6):
    if b"resume_not_accepted" not in send(request):
        break
    time.sleep(0.5)
    request["params"]["seq"] = time.time_ns()

if "resume_argv" in params:
    # Label Remote Control panes so they are not mistaken for interactive
    # Claude sessions. Herdr drops the label when the Claude process exits.
    send({
        "id": f"{request_id}:metadata",
        "method": "pane.report_metadata",
        "params": {
            "pane_id": pane_id,
            "source": source,
            "agent": "claude",
            "display_agent": "claude RC",
            "seq": time.time_ns(),
        },
    })
PY

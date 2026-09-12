#!/usr/bin/env python3
# Exercise the production stdio protocol with deterministic screen/action turns and fragmented output.
import json
import os
import sys
import time

turn = 0
stage = 0
approval_test = False
screen_id = None
read_only = os.environ.get("COMET_MOCK_CODEX_READ_ONLY") == "1"


# Split each envelope to ensure the transport buffers partial lines and never parses fragments.
def send(value):
    data = json.dumps(value) + "\n"
    middle = len(data) // 2
    sys.stdout.write(data[:middle])
    sys.stdout.flush()
    sys.stdout.write(data[middle:])
    sys.stdout.flush()


# Tool requests use the actual app-server schema, including thread and turn identity.
def tool(name, arguments):
    send(
        {
            "id": "tool-" + str(turn) + "-" + str(stage),
            "method": "item/tool/call",
            "params": {
                "threadId": "fixture-thread",
                "turnId": str(turn),
                "callId": "call-" + str(stage),
                "tool": name,
                "arguments": arguments,
            },
        }
    )


# Finish with streamed Markdown to verify deltas and the authoritative completion message agree.
def complete(status="completed"):
    if status == "completed":
        for delta in (
            ["Remote screen ", "inspected."]
            if read_only
            else ["Created a ", "**poem about apples**."]
        ):
            send(
                {
                    "method": "item/agentMessage/delta",
                    "params": {
                        "threadId": "fixture-thread",
                        "turnId": str(turn),
                        "itemId": "reply-" + str(turn),
                        "delta": delta,
                    },
                }
            )
    send(
        {
            "method": "turn/completed",
            "params": {
                "threadId": "fixture-thread",
                "turn": {"id": str(turn), "status": status},
            },
        }
    )


# Respond only to the methods needed by the controller, then drive the remote computer through its tools.
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    request_id = message.get("id")
    if method == "initialize":
        send({"id": request_id, "result": {"userAgent": "fixture"}})
    elif method == "account/read":
        send(
            {
                "id": request_id,
                "result": {"account": {"type": "apiKey"}, "requiresOpenaiAuth": True},
            }
        )
    elif method == "config/read":
        send(
            {
                "id": request_id,
                "result": {"config": {"mcp_servers": {"unrelated": {"enabled": True}}}},
            }
        )
    elif method == "thread/start":
        assert message["params"]["config"]["mcp_servers.unrelated.enabled"] is False
        assert message["params"]["sandbox"] == "read-only"
        assert message["params"]["ephemeral"] is True
        send({"id": request_id, "result": {"thread": {"id": "fixture-thread"}}})
    elif method == "turn/start":
        approval_test = os.environ.get("COMET_MOCK_CODEX_REVIEW_TEST") == "1" and "Approval fixture" in message["params"]["input"][0]["text"]
        read_only = read_only or "Read only" in message["params"]["input"][0]["text"]
        turn += 1
        stage = 0
        send(
            {
                "id": request_id,
                "result": {"turn": {"id": str(turn), "status": "inProgress"}},
            }
        )
        tool("comet_screen", {})
    elif method == "turn/interrupt":
        send({"id": request_id, "result": {}})
        complete("interrupted")
    elif method is None and str(request_id).startswith("tool-"):
        if not message.get("result", {}).get("success"):
            continue
        items = message["result"]["contentItems"]
        assert items[1]["imageUrl"].startswith("data:image/")
        screen_id = items[0]["text"].split("screenId: ")[1]
        stage += 1
        if approval_test:
            # A wait has no HID effects but passes through the same immutable approval boundary as typing.
            if stage == 1:
                tool("comet_action", {"screenId": screen_id, "action": "wait", "milliseconds": 0})
            else:
                complete()
        elif read_only:
            if stage <= 5:
                # Observation-only fixtures never request input; a short UI-only delay leaves time to pause.
                if os.environ.get("COMET_MOCK_CODEX_READ_ONLY") == "1":
                    time.sleep(1)
                tool("comet_screen", {})
            else:
                complete()
        elif stage == 1:
            tool(
                "comet_action",
                {"screenId": screen_id, "action": "click", "x": 25, "y": 30},
            )
        elif stage == 2:
            tool(
                "comet_action",
                {
                    "screenId": screen_id,
                    "action": "type",
                    "text": "Apples glow in morning light.",
                },
            )
        else:
            complete()

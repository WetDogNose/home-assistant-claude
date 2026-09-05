---
name: claude-automation-api
description: Let Home Assistant call Claude — the add-on's Automation API lets automations, scripts, blueprints and rest_commands run a non-interactive `claude -p` prompt and use the reply, synchronously or as a background job that fires an event when it finishes. Use this whenever the user wants Home Assistant to trigger Claude, wants an automation that "asks Claude" or "gets Claude to" do something, wants Claude to react to an event/webhook/schedule from HA, wants to ask Claude by voice through Assist, wants a conversation that remembers earlier calls, wants to send prompts from Telegram/Matrix/Discord via claude-bot, or asks about the API token, the port, the endpoint, the shipped blueprints, or the rest_command they need. Also use it when an existing HA→Claude call is failing or timing out — a rest_command that gives up after 10 seconds, or a 401, 403, 404, 429 or 503, each of which maps to a specific control described here.
---

# Triggering Claude from Home Assistant

The add-on runs an HTTP daemon (`claude-api-server`) that accepts a prompt and
runs `claude -p` non-interactively. That is what turns Claude from something a
person types at into something the house can call.

## The endpoint

```
POST http://claude_terminal_wdn:8128/api/prompt
```

- `/prompt` is accepted as an alias. **`/api/query` is not a route** — it
  answers 404, and has been the cause of every "the blueprint does nothing" report.
- Port `8128` is the default; it follows the `automation_api_port` option.
- The port is **not** published to the host. It is reachable only from other
  containers on Home Assistant's Docker network, which is a deliberate part of
  the security model, not an oversight.

**Address the add-on by slug, not by loopback.** From inside Home Assistant
Core's container `127.0.0.1` is Core itself, so `http://127.0.0.1:8128` fails
there. Use `http://claude_terminal_wdn:8128`. From *inside this terminal*,
`127.0.0.1` is correct.

Health check (no auth needed, `GET`):

```bash
curl -s http://127.0.0.1:8128/health | jq .
# {"status":"ok","claude_binary":"/data/home/.local/bin/claude","claude_available":true}
```

## Authentication

Send the token in either header:

```
X-API-Key: <token>
Authorization: Bearer <token>
```

The token is generated at startup and lives in `/data/automation_api_token`
(mode 600), unless the `automation_api_key` option is set, which overrides it:

```bash
cat /data/automation_api_token
```

It is a shared secret — paste it into the Home Assistant side, do not echo it
into a file under `/config` that gets committed, and do not put it in a
notification.

## Request and response

```bash
curl -s -X POST http://127.0.0.1:8128/api/prompt \
  -H "X-API-Key: $(cat /data/automation_api_token)" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Summarise today'"'"'s energy usage in one sentence", "timeout": 90}' | jq .
```

Request fields: `prompt` (required, non-empty), `timeout` (optional seconds,
clamped to 5–300, default 120), `async` (optional bool, see below) and
`session` (optional name, see below). Body limit 64 KB.

Response on success:

```json
{"success": true, "response": "…", "exit_code": 0, "duration_seconds": 3.42}
```

On failure `success` is `false` with `error` set and HTTP 500. Status codes map
to specific controls, which is what makes them diagnosable:

| Code | Meaning | Fix |
|---|---|---|
| 403 | Caller IP is not loopback or a private range | Call from within the Docker network, not from outside |
| 429 | More than 10 requests/minute from that IP | Debounce the automation; this limit also throttles token guessing |
| 401 | Bad or missing token | Re-read `/data/automation_api_token` |
| 404 | Wrong path | Use `/api/prompt` |
| 503 | Another prompt is already running | Requests are serialized by a mutex; retry, or stop firing overlapping automations |

Prompts run with `cwd=/config` and inherit `dangerously_skip_permissions` and
`claude_extra_args` from the add-on options. If prompts hang until timeout,
that is usually Claude waiting on a permission prompt that no one can answer —
either narrow the prompt to read-only work or enable the option knowingly.

## Async jobs — the right default for automations

**Home Assistant's `rest_command` gives up after 10 seconds by default.** Most
prompts worth asking take longer than that, which is why synchronous calls fail
for most real automations — the automation reports an error while Claude is
still working, and the answer is thrown away. Reach for async for anything that
is not answering a person in real time.

Add `"async": true` and the call returns **HTTP 202** immediately:

```json
{"job_id": "…", "status": "running", "session": null,
 "poll_url": "/api/jobs/…", "event": "claude_terminal_job_finished"}
```

When the run finishes the daemon fires the Home Assistant event
`claude_terminal_job_finished`, with `event_data`:

`job_id`, `status`, `success`, `session`, `duration_seconds`, `response`,
`truncated`, `error`.

`response` in the event is **truncated to 1000 characters** (`truncated` says
whether it was). For the whole thing, read the job back:

```bash
curl -s http://127.0.0.1:8128/api/jobs/<job_id> \
  -H "X-API-Key: $(cat /data/automation_api_token)" | jq -r .response
```

`GET /api/jobs` lists recent jobs, newest first, without their response bodies.

An automation reacts to the result with an `event` trigger:

```yaml
triggers:
  - trigger: event
    event_type: claude_terminal_job_finished
conditions:
  - "{{ trigger.event.data.success }}"
actions:
  - action: notify.persistent_notification
    data:
      message: "{{ trigger.event.data.response }}"
```

Jobs live **in memory only**, capped at 50, and are lost when the add-on
restarts. The fired event is the durable record — Home Assistant has it in the
event bus and whatever the automation did with it. Do not design anything that
depends on polling a job that finished hours ago.

Polling has its own rate limit of **120 requests/minute**, separate from the
10/minute limit on *starting* a prompt, so a tight poll loop will not lock out
the automation that needs to submit the next job.

## Sessions — a conversation that remembers

Pass `"session": "<name>"` (`[A-Za-z0-9_-]`, 1–64 characters) to keep context
across calls. The first call with a given name creates the conversation; later
calls with the same name resume it, so "and what about upstairs?" works from an
automation the way it does in the terminal.

If the underlying Claude session has since been pruned, the next call
transparently starts a fresh one rather than failing — context is lost, the
call is not.

Use a session for a genuine back-and-forth (a voice assistant, a chat bridge).
Leave it off for independent one-shot jobs: a shared session means every
scheduled report drags the previous one's context along, which costs tokens and
muddies the answer.

## Wiring it into Home Assistant

`rest_command` can only be defined in `configuration.yaml`. Add it once and
restart Home Assistant:

```yaml
rest_command:
  claude_terminal_query:
    url: "{{ url }}"
    method: POST
    headers:
      X-API-Key: "{{ token }}"
    content_type: "application/json"
    payload: '{"prompt": {{ prompt | to_json }}}'
```

`{{ prompt | to_json }}` is doing real work — it escapes quotes and newlines in
the prompt. Interpolating it raw produces malformed JSON the moment a prompt
contains an apostrophe.

To use the answer inside the automation, call it with `response_variable`:

```yaml
actions:
  - action: rest_command.claude_terminal_query
    data:
      url: "http://claude_terminal_wdn:8128/api/prompt"
      token: !secret claude_terminal_token
      prompt: "One sentence: is anything unusual about the house right now?"
    response_variable: claude
  - action: notify.persistent_notification
    data:
      message: "{{ claude.content.response }}"
```

## The shipped blueprints

Four blueprints are copied into `/config/blueprints/automation/` at add-on
start:

| Blueprint | What it is for |
|---|---|
| **Claude Terminal Task Trigger** | The original: any trigger fires a prompt |
| **Ask Claude with your voice** | An Assist sentence trigger, so "hey, ask Claude…" works spoken |
| **Scheduled Claude report** | A time-triggered report, submitted async |
| **Act on a finished Claude job** | Triggers on `claude_terminal_job_finished` and does something with the result |

The last two are designed to be used together: one submits the job, the other
picks up the event when it completes. That pairing is what makes a long prompt
usable from an automation at all.

All of them ask for a trigger or schedule, a prompt, the API URL (defaulting to
the slug hostname) and the token, and call the `rest_command` above — which
must exist first, or the automation fails at runtime with an unknown-service
error.

## claude-bot — forwarding from a chat platform

```bash
claude-bot status                  # config + resolved endpoint
claude-bot setup                   # how to wire up Telegram/Matrix/Discord
claude-bot forward "Turn off all lights"
```

`forward` posts to the Automation API using the token file and the configured
port. The messaging platform itself lives on the Home Assistant side — add the
Telegram/Matrix/Discord integration there and have an automation call the
`rest_command` with the incoming message text. `claude-bot` is the local test
path and the bridge for scripts running in this terminal.

## Turning it off

Set `enable_automation_api: false` in the add-on options if nothing needs it.
The daemon refuses to start without a token at all, so there is no unauthenticated mode.

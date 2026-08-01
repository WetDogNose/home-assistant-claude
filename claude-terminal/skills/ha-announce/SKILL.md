---
name: ha-announce
description: Reach the people in the house and control devices by intent — speak a message on a smart speaker with ha-tts, raise a Home Assistant notification with ha-notify, and issue natural-language commands through the Assist conversation pipeline with ha-assist. Use this whenever the user asks to announce, say, speak, broadcast or read something out, to notify or remind someone, to tell the household anything, or when a long-running task should report when it finishes. Also use ha-assist when the user asks to turn something on/off, lock, dim or set something and you do not know the exact entity ids — Assist resolves names the way the house already understands them. Prefer these over inventing raw service calls.
---

# Speaking, notifying and commanding

Three tools with different audiences. Choosing the wrong one is how a quiet
status update ends up shouted from the kitchen speaker at 3am.

| Intent | Use | Reaches |
|---|---|---|
| Say it out loud, now, in the room | `ha-tts` | Whoever is there |
| Leave a message to be seen later | `ha-notify` | Home Assistant's notification drawer |
| Do a thing ("turn off the lights") | `ha-assist` | Devices, via HA's own intent engine |

## ha-tts — speak on a speaker

```bash
ha-tts "<message>" [media_player_entity_id]
ha-tts "Front door motion detected"
ha-tts "Dinner is ready" media_player.kitchen_speaker
```

Without a target it uses `media_player.living_room_speaker`, which is a
placeholder default and often does not exist in a given instance. Pass the real
entity — list the candidates first:

```bash
curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/api/states \
  | jq -r '.[] | select(.entity_id | startswith("media_player.")) | .entity_id'
```

It calls `tts.google_translate_say`, and if that service is not available falls
back to `notify.notify` — so the message still lands somewhere, but as a
notification rather than as speech. It reports which path it took; read that
output before telling the user their announcement was spoken.

When the instance uses a modern TTS entity (Piper, Cloud, ElevenLabs), the
`tts.speak` service is the better call and lets you choose the voice:

```bash
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"entity_id": "tts.piper", "media_player_entity_id": "media_player.kitchen",
       "message": "The washing machine has finished"}' \
  http://supervisor/core/api/services/tts/speak
```

Speaking is intrusive — it interrupts whatever is playing and everyone in the
room hears it. Keep messages one sentence, and think about the hour before
announcing something that could have waited.

## ha-notify — a persistent notification

```bash
ha-notify "<title>" "<message>" [notification_id]
ha-notify "Backup complete" "Committed 14 changed files under /config"
```

Creates a Home Assistant persistent notification — the bell in the sidebar.
It is the right channel for anything the user should see but need not hear:
results of a long task, something that needs a decision later, a warning.

Reusing a `notification_id` replaces the previous notification instead of
stacking a new one, which is what you want for status that supersedes itself
(default id: `claude_terminal`). It no-ops without `SUPERVISOR_TOKEN` and never
returns non-zero, so it is safe to call from anywhere, including scripts under
`set -e`.

Markdown works in the message body, including links.

## ha-assist — command by name, not by entity id

```bash
ha-assist "<text>"
ha-assist "Are all the doors locked?"
ha-assist "Turn off the living room lights"
```

Sends the text to `conversation/process`, Home Assistant's own Assist pipeline,
and prints the spoken response. Its value is that it resolves names, areas and
aliases exactly as the household's voice assistants do — so "the lamp in the
snug" works without you knowing that it is `light.snug_corner_2`.

Two things to keep in mind:

- **It acts.** "Turn off the lights" turns them off. Use it for things the user
  asked for, and use the states API when you only need to *know* something.
- It answers with whatever the configured conversation agent produces. If Assist
  cannot match an intent it says so; that is a real answer ("Home Assistant
  doesn't recognise that device"), not a tool failure. If the instance routes
  Assist to an LLM agent, the reply is that agent's, not a guaranteed action.

When Assist cannot resolve something and you do know the entity, fall back to a
direct service call:

```bash
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  -H "Content-Type: application/json" -d '{"entity_id": "light.snug_corner_2"}' \
  http://supervisor/core/api/services/light/turn_off
```

## Acting on the user's behalf

Announcing, notifying and switching things off are visible to other people in
the house. Do them when asked; do not add an announcement to a task just
because it seems helpful. For anything irreversible or disruptive — unlocking
a door, disarming an alarm, turning off something that is clearly in use —
confirm first.

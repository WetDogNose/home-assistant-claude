// ha-entities — tell Home Assistant what OpenCode is doing.
//
// The OpenCode counterpart of the Claude Code hooks installed by claude-hooks:
// it turns session events into `ha-entity --agent opencode set ...` calls, which
// publish binary_sensor.opencode_busy and the sensor.opencode_* entities.
//
// Shipped in the image and found through OPENCODE_CONFIG_DIR, never copied into
// /data, so it cannot outlive the release that wrote it. It imports nothing
// that is not built in: a plugin with dependencies makes OpenCode run an
// install at startup, and nothing on a start path here may need the network.
//
// Reporting must never be able to slow or break the thing it reports on. Every
// publish is fire-and-forget in a detached process, and every failure is
// swallowed.

import { spawn } from "node:child_process"

export const HaEntities = async () => {
  // run.sh exports this only when both enable_opencode and enable_ha_entities
  // are on. Without it the plugin is inert rather than absent, so there is one
  // image regardless of options.
  if (process.env.CLAUDE_TERMINAL_OPENCODE_ENTITIES !== "1") return {}

  // Sessions currently working. A subagent is its own session and goes idle
  // while its parent is still busy, so "idle" is only true when this is empty.
  const busy = new Set()
  let lastPublished = ""
  let failed = false
  let model = ""

  const publish = (...pairs) => {
    // OpenCode repeats session.status "busy" many times per turn. Publishing
    // each one would spawn a process and POST to Home Assistant every time.
    const key = pairs.join("\u0000")
    if (key === lastPublished) return
    lastPublished = key
    try {
      const child = spawn("ha-entity", ["--agent", "opencode", "set", ...pairs], {
        stdio: "ignore",
        detached: true,
      })
      child.on("error", () => {})
      child.unref()
    } catch (_) {
      // ha-entity missing or not runnable: nothing to report to.
    }
  }

  const now = () => new Date().toISOString().replace(/\.\d+Z$/, "+00:00")

  // Free text from an error ends up as an entity attribute; keep it bounded
  // and on one line.
  const text = (value) => String(value ?? "").replace(/\s+/g, " ").trim().slice(0, 240)

  return {
    event: async ({ event }) => {
      try {
        const props = event?.properties ?? {}
        const session = props.sessionID ?? ""

        switch (event?.type) {
          case "message.updated": {
            const info = props.info ?? {}
            if (info.role === "assistant" && info.providerID && info.modelID) {
              model = `${info.providerID}/${info.modelID}`
            }
            break
          }

          case "session.status": {
            const status = props.status?.type
            if (status === "busy") {
              busy.add(session)
              failed = false
              publish("busy=true", "status=running")
            } else if (status === "retry") {
              busy.add(session)
              publish("busy=true", "status=retrying", `last_error=${text(props.status?.message)}`)
            }
            // "idle" is handled by session.idle, which fires alongside it.
            break
          }

          case "permission.asked":
            publish("busy=true", "status=waiting")
            break

          case "permission.replied":
            publish("busy=true", "status=running")
            break

          case "session.error": {
            busy.delete(session)
            failed = true
            const error = props.error ?? {}
            publish(
              "busy=false",
              "status=error",
              "last_result=error",
              `last_error=${text(error.data?.message ?? error.message ?? error.name ?? "unknown error")}`,
              `last_run=${now()}`,
            )
            break
          }

          case "session.idle": {
            busy.delete(session)
            if (busy.size > 0) break
            // A failed turn also goes idle. Do not let that overwrite the
            // error it has just reported with "ok".
            if (failed) break
            publish(
              "busy=false",
              "status=idle",
              "last_result=ok",
              "last_error=",
              `last_run=${now()}`,
              ...(model ? [`model=${model}`] : []),
            )
            break
          }
        }
      } catch (_) {
        // An event shape this was not written for must not surface in OpenCode.
      }
    },
  }
}

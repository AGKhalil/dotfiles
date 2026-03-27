/**
 * agent-notify — OpenCode plugin for session event detection.
 *
 * Detects idle, error, question, and permission events, writes them to a
 * shared SQLite registry.  The daemon polls the DB, sends notifications
 * via ntfy to the Mac listener, and escalates to Telegram if unacknowledged.
 *
 * The plugin is intentionally thin — it only writes to the DB and marks
 * events as responded when the user resumes activity.  All notification
 * display and dismiss logic lives in the daemon + listener.
 */

import type { Plugin } from "@opencode-ai/plugin";
import { resolve } from "node:path";

const AGENT_NOTIFY_DIR = resolve(import.meta.dir, "../../agent-notify");

const { openDB, upsertSession, updateSessionName, updateHeartbeat, deleteSessions, insertEvent, updateEventStatus, getPendingEventsForSession } = await import(
  resolve(AGENT_NOTIFY_DIR, "src/db.ts")
);

type EventType = "done" | "error" | "question" | "permission";

function uuid(): string {
  return crypto.randomUUID();
}

async function discoverPort(client: any): Promise<number> {
  try {
    const baseUrl: string | undefined =
      client?.baseUrl ??
      client?.options?.baseUrl ??
      client?._baseUrl ??
      client?._options?.baseUrl;
    if (baseUrl) {
      const url = new URL(baseUrl);
      if (url.port) return Number(url.port);
    }
  } catch {
    // ignore
  }
  try {
    await client.global.health();
    return 4096;
  } catch {
    return 4096;
  }
}

// ── Plugin ──────────────────────────────────────────────────────────────────

export const AgentNotifyPlugin: Plugin = async ({
  project,
  client,
  $,
  directory,
  worktree,
}) => {
  const db = openDB();
  const ownedSessions = new Set<string>();
  const port = await discoverPort(client);

  const basename = (p: string) => p.split("/").pop() ?? p;

  const projectRaw = typeof project === "string"
    ? project
    : project?.name ?? directory ?? "unknown";
  const projectName = basename(projectRaw);

  const worktreeRaw = typeof worktree === "string"
    ? worktree
    : (worktree as any)?.name ?? directory ?? "unknown";
  const worktreeName = basename(worktreeRaw);

  // ── Heartbeat ───────────────────────────────────────────────────────────
  const heartbeatInterval = setInterval(() => {
    try {
      const ids = Array.from(ownedSessions);
      if (ids.length > 0) updateHeartbeat(db, ids);
    } catch {
      // swallow — db may be closed during shutdown
    }
  }, 30_000);

  // ── Cleanup on exit ─────────────────────────────────────────────────────
  const cleanup = () => {
    clearInterval(heartbeatInterval);
    try {
      const ids = Array.from(ownedSessions);
      if (ids.length > 0) deleteSessions(db, ids);
    } catch {
      // best effort
    }
    try {
      db.close();
    } catch {
      // best effort
    }
  };

  process.on("SIGTERM", cleanup);
  process.on("SIGINT", cleanup);
  process.on("exit", cleanup);

  // ── Event helpers ───────────────────────────────────────────────────────

  const sessionNames = new Map<string, string>();
  const sessionsWithPendingEvents = new Set<string>();
  let currentSessionId = "";

  function writeEvent(sessionId: string, type: EventType, payload: object) {
    // Dismiss any existing pending events for this session — only the
    // latest event per session should be visible.
    markResponded(sessionId);

    try {
      insertEvent(db, {
        id: uuid(),
        session_id: sessionId,
        type,
        payload: JSON.stringify(payload),
      });
    } catch (err) {
      console.error("[agent-notify] Failed to write event:", err);
    }
  }

  /** Mark all pending events for a session as responded.
   *  The daemon will pick these up and send dismiss via ntfy. */
  function markResponded(sessionId: string) {
    try {
      const pending = getPendingEventsForSession(db, sessionId);
      for (const evt of pending) {
        updateEventStatus(db, evt.id, "responded");
      }
    } catch {
      // best effort
    }
  }

  // ── Classify idle reason ──────────────────────────────────────────────

  async function classifyIdle(sessionId: string): Promise<void> {
    try {
      // Skip subagent sessions — only notify for main sessions
      const sessionInfo = await client.session.get({ path: { id: sessionId } });
      if (sessionInfo?.data?.parentID) return;

      const msgs = await client.session.messages({ path: { id: sessionId } });
      if (!msgs?.data?.length) {
        writeEvent(sessionId, "done", { summary: "Session idle" });
        sessionsWithPendingEvents.add(sessionId);
        return;
      }

      const lastMsg = msgs.data[msgs.data.length - 1];
      const parts: any[] = lastMsg?.parts ?? [];

      for (const part of parts) {
        if (
          part?.type === "tool" &&
          part?.tool === "askquestion" &&
          part?.state === "waiting" &&
          part?.metadata
        ) {
          const question = part.metadata.question ?? part.metadata.text ?? "";
          const options: string[] = part.metadata.options ?? [];
          writeEvent(sessionId, "question", { text: question, options });
          sessionsWithPendingEvents.add(sessionId);
          return;
        }
      }

      const title =
        lastMsg?.info?.title ?? lastMsg?.info?.summary ?? "Session completed";
      writeEvent(sessionId, "done", { summary: title });
      sessionsWithPendingEvents.add(sessionId);
    } catch (err) {
      writeEvent(sessionId, "done", { summary: "Session idle" });
      sessionsWithPendingEvents.add(sessionId);
    }
  }

  // ── Return event hooks ────────────────────────────────────────────────

  return {
    event: async ({ event }: { event: any }) => {
      const type: string = event?.type;
      if (!type) return;

      const sessionId: string =
        event?.properties?.sessionID ??
        event?.properties?.info?.sessionID ??
        event?.properties?.part?.sessionID ??
        event?.properties?.id ??
        event?.sessionID ??
        event?.id ??
        "";

      // Ensure session is registered on any event that carries a session ID
      if (sessionId && !ownedSessions.has(sessionId)) {
        try {
          upsertSession(db, {
            id: sessionId,
            port,
            project: projectName,
            worktree: worktreeName,
            name: sessionNames.get(sessionId) ?? "",
          });
          ownedSessions.add(sessionId);
        } catch {
          // best effort
        }
      }

      switch (type) {
        case "session.idle": {
          if (!sessionId) break;
          currentSessionId = sessionId;
          await classifyIdle(sessionId);
          break;
        }

        case "session.error": {
          if (!sessionId) break;
          const message =
            event?.properties?.error ??
            event?.properties?.message ??
            "Unknown error";
          writeEvent(sessionId, "error", { message });
          sessionsWithPendingEvents.add(sessionId);
          break;
        }

        case "permission.asked": {
          if (!sessionId) break;
          const permissionId =
            event?.properties?.permissionID ??
            event?.properties?.id ??
            "";
          const tool = event?.properties?.tool ?? "unknown";
          const action =
            event?.properties?.action ??
            event?.properties?.command ??
            event?.properties?.description ??
            "";
          writeEvent(sessionId, "permission", {
            permissionId,
            tool,
            action,
          });
          sessionsWithPendingEvents.add(sessionId);
          break;
        }

        case "session.status": {
          if (!sessionId) break;
          const status = event?.properties?.status?.type ?? event?.properties?.status;
          currentSessionId = sessionId;
          if (status !== "idle") {
            if (sessionsWithPendingEvents.has(sessionId)) {
              markResponded(sessionId);
              sessionsWithPendingEvents.delete(sessionId);
            }
          }
          break;
        }

        case "session.updated": {
          const info = event?.properties?.info;
          const sid = info?.id ?? sessionId;
          const name = info?.title ?? info?.slug ?? "";
          if (sid && name) {
            sessionNames.set(sid, name);
            try {
              updateSessionName(db, sid, name);
            } catch {
              // best effort
            }
            // Rename tmux window only for the current active session
            if (process.env.TMUX && sid === currentSessionId) {
              try {
                const truncated = name.length > 30 ? name.slice(0, 27) + "..." : name;
                Bun.spawn(["tmux", "rename-window", truncated], {
                  stdout: "ignore",
                  stderr: "ignore",
                });
              } catch {
                // best effort
              }
            }
          }
          break;
        }

        default:
          break;
      }
    },
  };
};

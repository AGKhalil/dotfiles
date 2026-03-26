/**
 * agent-notify — OpenCode plugin for session event detection.
 *
 * Detects idle, error, question, and permission events, writes them to a
 * shared SQLite registry so the per-server daemon can pick them up and
 * route notifications (ntfy → Mac, escalation → Telegram).
 */

import type { Plugin } from "@opencode-ai/plugin";
import { resolve } from "node:path";

// Shared modules live in the agent-notify directory which is a sibling of
// the opencode directory in the dotfiles repo.  At runtime the plugin is
// loaded from ~/.config/opencode/plugins/ (a symlink).  We resolve the
// real path so relative imports work regardless of the symlink.
const AGENT_NOTIFY_DIR = resolve(import.meta.dir, "../../agent-notify");

const { openDB, upsertSession, updateHeartbeat, deleteSessions, insertEvent, updateEventStatus, getPendingEventsForSession } = await import(
  resolve(AGENT_NOTIFY_DIR, "src/db.ts")
);

type EventType = "done" | "error" | "question" | "permission";

// ── Helpers ─────────────────────────────────────────────────────────────────

function uuid(): string {
  return crypto.randomUUID();
}

/** Best-effort extraction of the OpenCode server port from the SDK client. */
async function discoverPort(client: any): Promise<number> {
  try {
    // The SDK client stores the base URL internally.  Try common locations.
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

  // Fallback: call the health endpoint to discover the port.  If the client
  // doesn't expose it directly we try the well-known default.
  try {
    const res = await client.global.health();
    // The response itself doesn't contain the port, but if we got here the
    // client is working.  Try to extract from the internal fetch URL.
    return 4096; // last resort default
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
  // Initialise database
  const db = openDB();

  // Track sessions owned by this plugin instance for heartbeat & cleanup.
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

  function writeEvent(sessionId: string, type: EventType, payload: object) {
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

  /** Mark all pending events for a session as responded (TUI-answered). */
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

  // Track which sessions are "idle with pending event" so we can detect
  // when they resume activity (TUI-answered detection).
  const sessionsWithPendingEvents = new Set<string>();

  // ── Classify idle reason ──────────────────────────────────────────────

  async function classifyIdle(sessionId: string): Promise<void> {
    try {
      const msgs = await client.session.messages({ path: { id: sessionId } });
      if (!msgs?.data?.length) {
        writeEvent(sessionId, "done", { summary: "Session idle" });
        sessionsWithPendingEvents.add(sessionId);
        return;
      }

      // Last assistant message
      const lastMsg = msgs.data[msgs.data.length - 1];
      const parts: any[] = lastMsg?.parts ?? [];

      // Check for askquestion tool part in waiting state
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

      // No askquestion → agent finished normally
      const title =
        lastMsg?.info?.title ?? lastMsg?.info?.summary ?? "Session completed";
      writeEvent(sessionId, "done", { summary: title });
      sessionsWithPendingEvents.add(sessionId);
    } catch (err) {
      // If we can't inspect messages, emit a generic done event
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
          });
          ownedSessions.add(sessionId);
        } catch {
          // best effort
        }
      }

      switch (type) {
        // ── Session idle (done or question) ───────────────────────────
        case "session.idle": {
          if (!sessionId) break;
          await classifyIdle(sessionId);
          break;
        }

        // ── Session error ─────────────────────────────────────────────
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

        // ── Permission requested ──────────────────────────────────────
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

        // ── Message updated (detect TUI-answered) ─────────────────────
        case "message.updated":
        case "message.part.updated": {
          if (!sessionId) break;
          if (sessionsWithPendingEvents.has(sessionId)) {
            markResponded(sessionId);
            sessionsWithPendingEvents.delete(sessionId);
          }
          break;
        }

        // ── Session status change (also detect TUI-answered) ──────────
        case "session.status": {
          if (!sessionId) break;
          const status = event?.properties?.status;
          // If session is running/busy and had pending events, mark responded
          if (
            status === "running" ||
            status === "busy" ||
            status === "prompting"
          ) {
            if (sessionsWithPendingEvents.has(sessionId)) {
              markResponded(sessionId);
              sessionsWithPendingEvents.delete(sessionId);
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

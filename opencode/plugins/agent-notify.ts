/**
 * agent-notify — OpenCode plugin for session event detection.
 *
 * Detects idle, error, question, and permission events, writes them to a
 * shared SQLite registry so the per-server daemon can pick them up and
 * route notifications (ntfy → Mac, escalation → Telegram).
 *
 * On macOS, the plugin shows notifications directly via terminal-notifier
 * (works from any tmux pane, including SSH inner sessions on the Mac).
 * When terminal-notifier is not available (remote server), the daemon
 * handles notification delivery via ntfy and Telegram.
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

// ── Direct macOS notifications via terminal-notifier ────────────────────────

let hasTerminalNotifier: boolean | null = null;

async function checkTerminalNotifier(): Promise<boolean> {
  if (hasTerminalNotifier !== null) return hasTerminalNotifier;
  try {
    const proc = Bun.spawn(["which", "terminal-notifier"], {
      stdout: "ignore",
      stderr: "ignore",
    });
    const code = await proc.exited;
    hasTerminalNotifier = code === 0;
  } catch {
    hasTerminalNotifier = false;
  }
  return hasTerminalNotifier;
}

async function showNotification(
  title: string,
  body: string,
  group: string
): Promise<void> {
  if (!(await checkTerminalNotifier())) return;
  try {
    const proc = Bun.spawn(
      ["terminal-notifier", "-title", title, "-message", body, "-group", group],
      { stdout: "ignore", stderr: "ignore" }
    );
    await proc.exited;
  } catch {
    // best effort
  }
}

async function dismissNotifications(): Promise<void> {
  if (!(await checkTerminalNotifier())) return;
  try {
    const proc = Bun.spawn(
      ["terminal-notifier", "-remove", "ALL"],
      { stdout: "ignore", stderr: "ignore" }
    );
    await proc.exited;
  } catch {
    // best effort
  }
}

function formatEventSummary(type: EventType, payload: any): string {
  switch (type) {
    case "done":
      return `Done: ${payload.summary ?? "Session completed"}`;
    case "error":
      return `Error: ${payload.message ?? "Agent error"}`;
    case "question":
      return `Question: ${payload.text ?? "Agent has a question"}`;
    case "permission":
      return `Permission: ${payload.tool}: ${payload.action}`;
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

  /** Track event IDs per session so we can dismiss them later. */
  const sessionEventIds = new Map<string, string[]>();

  function writeEvent(sessionId: string, type: EventType, payload: object) {
    const eventId = uuid();
    try {
      insertEvent(db, {
        id: eventId,
        session_id: sessionId,
        type,
        payload: JSON.stringify(payload),
      });
    } catch (err) {
      console.error("[agent-notify] Failed to write event:", err);
      return;
    }

    // Track event ID for later dismiss
    const ids = sessionEventIds.get(sessionId) ?? [];
    ids.push(eventId);
    sessionEventIds.set(sessionId, ids);

    // Show notification directly via terminal-notifier
    const body = formatEventSummary(type, payload);
    showNotification(projectName, body, eventId);
  }

  /** Mark all pending events for a session as responded and dismiss notifications. */
  async function markRespondedAndDismiss(sessionId: string) {
    // Dismiss notifications directly if terminal-notifier is available (Mac),
    // otherwise mark as responded so the daemon sends dismiss via ntfy.
    const canDismissLocally = await checkTerminalNotifier();
    if (canDismissLocally) {
      dismissNotifications();
    }
    sessionEventIds.delete(sessionId);

    // On Mac: mark dismissed directly (ctrl+n panel clears them).
    // On server: mark responded so daemon picks them up, sends dismiss
    // via ntfy to Mac listener, then moves to dismissed.
    const targetStatus = canDismissLocally ? "dismissed" : "responded";
    try {
      const pending = getPendingEventsForSession(db, sessionId);
      for (const evt of pending) {
        updateEventStatus(db, evt.id, targetStatus);
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

        // ── Session status change (detect user activity) ──────────────
        case "session.status": {
          if (!sessionId) break;
          const status = event?.properties?.status?.type ?? event?.properties?.status;
          // Any non-idle status means the session is active — user responded
          // to a prompt, granted permission, or sent a new message.
          if (status !== "idle" && sessionsWithPendingEvents.has(sessionId)) {
            markRespondedAndDismiss(sessionId);
            sessionsWithPendingEvents.delete(sessionId);
          }
          break;
        }

        default:
          break;
      }
    },
  };
};

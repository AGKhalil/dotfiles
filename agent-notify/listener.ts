#!/usr/bin/env bun
/**
 * agent-notify Mac listener — runs on the main machine (macOS).
 *
 * Subscribes to the ntfy events topic via SSE, displays native macOS
 * notifications via terminal-notifier (with dismissable groups), and
 * sends ACKs back so the daemon can suppress or delay Telegram escalation.
 * Also handles dismiss messages to clear notifications when the user
 * resumes work in the terminal.
 */

import { loadConfig } from "./src/config";
import { openDB, insertEvent, upsertSession, getEvent, updateEventStatus } from "./src/db";
import type { NtfyEventPayload, NtfyAckPayload, NtfyDismissPayload, EventType } from "./src/types";

const config = loadConfig();
const db = openDB();
const ntfyBase = config.ntfy.server ?? "https://ntfy.sh";

console.log("[listener] Starting agent-notify Mac listener");
console.log(`[listener] Subscribing to ${config.ntfy.events_topic}`);

// ── macOS notification (terminal-notifier) ──────────────────────────────────

async function showNotification(
  title: string,
  subtitle: string,
  body: string,
  group: string
): Promise<void> {
  try {
    const args = [
      "terminal-notifier",
      "-title", title,
      "-message", body,
      "-group", group,
    ];
    if (subtitle) args.push("-subtitle", subtitle);
    console.log(`[listener] Spawning: ${args.join(" ")}`);
    const proc = Bun.spawn(args, { stdout: "pipe", stderr: "pipe" });
    const exit = await proc.exited;
    const stdout = await new Response(proc.stdout).text();
    const stderr = await new Response(proc.stderr).text();
    console.log(`[listener] terminal-notifier exit=${exit} stdout=${stdout.trim()} stderr=${stderr.trim()}`);
  } catch (err) {
    console.error("[listener] Failed to show notification:", err);
  }
}

async function dismissNotification(eventId: string): Promise<void> {
  // Remove all terminal-notifier notifications (per-group removal is unreliable)
  try {
    const proc = Bun.spawn(
      ["terminal-notifier", "-remove", "ALL"],
      { stdout: "ignore", stderr: "ignore" }
    );
    await proc.exited;
    console.log(`[listener] Dismissed notifications for event ${eventId}`);
  } catch (err) {
    console.error("[listener] Failed to dismiss notification:", err);
  }
}

function formatEvent(type: EventType, summary: string): string {
  switch (type) {
    case "done":
      return `Done: ${summary}`;
    case "error":
      return `Error: ${summary}`;
    case "question":
      return `Question: ${summary}`;
    case "permission":
      return `Permission: ${summary}`;
  }
}

// ── ACK sender ──────────────────────────────────────────────────────────────

async function sendAck(eventId: string): Promise<void> {
  const payload: NtfyAckPayload = { event_id: eventId };
  try {
    await fetch(`${ntfyBase}/${config.ntfy.ack_topic}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    console.log(`[listener] ACK sent for event ${eventId}`);
  } catch (err) {
    console.error("[listener] Failed to send ACK:", err);
  }
}

// ── SSE subscription ────────────────────────────────────────────────────────

async function subscribe(): Promise<void> {
  let retryDelay = 1000;

  const connect = async () => {
    const url = `${ntfyBase}/${config.ntfy.events_topic}/sse`;
    console.log(`[listener] Connecting to ${url}`);

    try {
      const res = await fetch(url);
      if (!res.ok || !res.body) {
        throw new Error(`ntfy SSE: ${res.status}`);
      }

      retryDelay = 1000; // reset on success
      console.log("[listener] Connected to ntfy SSE");

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });

        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";

        for (const line of lines) {
          if (!line.startsWith("data:")) continue;
          try {
            const raw = line.slice(5).trim();
            const ntfyEvent = JSON.parse(raw);
            // Skip ntfy control events (open, keepalive)
            if (!ntfyEvent.message) continue;
            const message = ntfyEvent.message;
            const parsed =
              typeof message === "string" ? JSON.parse(message) : message;
            // Handle dismiss messages
            if (parsed.dismiss && parsed.event_id) {
              await dismissNotification(parsed.event_id);
              // Update local DB so ctrl+n panel clears the event
              try {
                const evt = getEvent(db, parsed.event_id);
                if (evt) {
                  updateEventStatus(db, parsed.event_id, "dismissed");
                }
              } catch { /* best effort */ }
              continue;
            }
            const eventPayload: NtfyEventPayload = parsed;
            // Skip if missing required fields
            if (!eventPayload.event_id || !eventPayload.type) continue;
            await handleEvent(eventPayload);
          } catch {
            // Skip non-JSON lines (keepalive, etc.)
          }
        }
      }
    } catch (err) {
      console.error("[listener] SSE error:", err);
    }

    // Reconnect with exponential backoff
    console.log(`[listener] Reconnecting in ${retryDelay / 1000}s...`);
    retryDelay = Math.min(retryDelay * 2, 60_000);
    setTimeout(connect, retryDelay);
  };

  connect();
}

async function handleEvent(event: NtfyEventPayload): Promise<void> {
  console.log(`[listener] Event received: ${event.type} (${event.event_id})`);

  // Write to local SQLite for the ctrl+n panel
  try {
    // Ensure a session row exists for grouping
    const sessionId = `${event.server_label}:${event.project}`;
    upsertSession(db, {
      id: sessionId,
      port: 0,
      project: event.project,
      worktree: event.worktree,
    });

    // Skip duplicate events (same event_id from retries)
    if (!getEvent(db, event.event_id)) {
      insertEvent(db, {
        id: event.event_id,
        session_id: sessionId,
        type: event.type,
        payload: JSON.stringify({
          summary: event.summary,
          server_label: event.server_label,
        }),
      });
    }
  } catch (err) {
    console.error("[listener] Failed to write to SQLite:", err);
  }

  // Show macOS notification
  const title = event.server_label === config.server_label
    ? "main"
    : event.server_label;

  const hasWorktree = event.worktree
    && event.worktree !== event.project
    && event.worktree !== "unknown";

  const bodyLines = [event.project];
  if (hasWorktree) bodyLines.push(event.worktree);
  bodyLines.push(formatEvent(event.type, event.summary));
  const body = bodyLines.join("\n");

  await showNotification(title, "", body, event.event_id);
  await sendAck(event.event_id);
}

// ── Start ───────────────────────────────────────────────────────────────────

subscribe();

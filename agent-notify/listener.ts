#!/usr/bin/env bun
/**
 * agent-notify Mac listener — runs on the main machine (macOS).
 *
 * Subscribes to the ntfy events topic via SSE, displays native macOS
 * notifications via osascript, and sends ACKs back so the daemon can
 * suppress or delay Telegram escalation.
 */

import { loadConfig } from "./src/config";
import type { NtfyEventPayload, NtfyAckPayload, EventType } from "./src/types";
import { $ } from "bun";

const config = loadConfig();
const ntfyBase = config.ntfy.server ?? "https://ntfy.sh";

console.log("[listener] Starting agent-notify Mac listener");
console.log(`[listener] Subscribing to ${config.ntfy.events_topic}`);

// ── macOS notification ──────────────────────────────────────────────────────

async function showNotification(
  title: string,
  subtitle: string,
  body: string
): Promise<void> {
  try {
    const esc = (s: string) =>
      s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
    const parts = [
      `display notification "${esc(body)}"`,
      `with title "${esc(title)}"`,
    ];
    if (subtitle) {
      parts.push(`subtitle "${esc(subtitle)}"`);
    }
    await $`osascript -e ${parts.join(" ")}`;
  } catch (err) {
    console.error("[listener] Failed to show notification:", err);
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
            // ntfy wraps the user payload in a `message` field
            const message = ntfyEvent.message ?? raw;
            const eventPayload: NtfyEventPayload =
              typeof message === "string" ? JSON.parse(message) : message;
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

  const title = config.role === "main"
    ? event.project
    : `${event.server_label} — ${event.project}`;

  const hasWorktree = event.worktree
    && event.worktree !== event.project
    && event.worktree !== "unknown";
  const subtitle = hasWorktree ? event.worktree : "";

  const body = formatEvent(event.type, event.summary);

  await showNotification(title, subtitle, body);
  await sendAck(event.event_id);
}

// ── Start ───────────────────────────────────────────────────────────────────

subscribe();

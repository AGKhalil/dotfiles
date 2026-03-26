#!/usr/bin/env bun
/**
 * agent-notify daemon — per-server background process.
 *
 * Reads pending events from SQLite, sends ntfy → Mac notifications,
 * manages escalation timers, sends Telegram notifications, polls
 * getUpdates for responses, and routes them back to OpenCode.
 */

import { loadConfig } from "./src/config";
import {
  openDB,
  getPendingEvents,
  getEventsByStatus,
  getRespondedEvents,
  getEventsForStaleSessions,
  getStaleSessions,
  getSession,
  getSessionByPrefix,
  getEvent,
  getEventByTelegramMsgId,
  updateEventStatus,
  setTelegramMsgId,
  deleteSessions,
} from "./src/db";
import {
  sendMessage,
  editMessageText,
  answerCallbackQuery,
  getUpdates,
  formatNotification,
  buildKeyboard,
  decodeCallback,
  type TgUpdate,
  type DecodedCallback,
} from "./src/telegram";
import type {
  AppConfig,
  EventRow,
  SessionRow,
  QuestionPayload,
  PermissionPayload,
  NtfyEventPayload,
  NtfyAckPayload,
  EventType,
} from "./src/types";
import type { Database } from "bun:sqlite";

// ── Init ────────────────────────────────────────────────────────────────────

const config = loadConfig();
const db = openDB();

const hasTelegram = !!(config.telegram.bot_token && config.telegram.chat_id);

console.log(`[daemon] Starting agent-notify daemon (${config.server_label})`);
console.log(`[daemon] Role: ${config.role}, Telegram: ${hasTelegram ? "yes" : "no"}`);

// ── Escalation state ────────────────────────────────────────────────────────

/** Events waiting for Mac ACK before escalating to Telegram. */
const escalationTimers = new Map<string, Timer>();

/** Events where we sent a "Type custom — reply to this message" prompt.
 *  Maps Telegram message_id → event ID. */
const customReplyPrompts = new Map<number, string>();

// ── ntfy helpers ────────────────────────────────────────────────────────────

const ntfyBase = config.ntfy.server ?? "https://ntfy.sh";

async function sendNtfy(eventPayload: NtfyEventPayload): Promise<void> {
  try {
    await fetch(`${ntfyBase}/${config.ntfy.events_topic}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(eventPayload),
    });
  } catch (err) {
    console.error("[daemon] Failed to send ntfy:", err);
  }
}

// ── ntfy ACK listener (SSE) ─────────────────────────────────────────────────

async function startAckListener(): Promise<void> {
  const url = `${ntfyBase}/${config.ntfy.ack_topic}/sse`;
  let retryDelay = 1000;

  const connect = async () => {
    try {
      const res = await fetch(url);
      if (!res.ok || !res.body) {
        throw new Error(`ntfy ACK SSE: ${res.status}`);
      }
      retryDelay = 1000; // reset on successful connect
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
            // ntfy wraps the payload in an event object
            const ntfyEvent = JSON.parse(raw);
            const message = ntfyEvent.message ?? raw;
            const ack: NtfyAckPayload = typeof message === "string"
              ? JSON.parse(message)
              : message;
            handleAck(ack);
          } catch {
            // not valid JSON, skip
          }
        }
      }
    } catch (err) {
      console.error("[daemon] ACK SSE error:", err);
    }

    // Reconnect with backoff
    retryDelay = Math.min(retryDelay * 2, 60_000);
    setTimeout(connect, retryDelay);
  };

  connect();
}

function handleAck(ack: NtfyAckPayload): void {
  const eventId = ack.event_id;
  if (!eventId) return;

  // Cancel the escalation timer
  const timer = escalationTimers.get(eventId);
  if (timer) {
    clearTimeout(timer);
    escalationTimers.delete(eventId);
    updateEventStatus(db, eventId, "mac_acked");
    console.log(`[daemon] ACK received for event ${eventId}, Telegram suppressed`);
  }
}

// ── Escalation pipeline ─────────────────────────────────────────────────────

function getDelay(eventType: EventType): number {
  return (config.delays[eventType] ?? 60) * 1000;
}

async function processEvent(event: EventRow): Promise<void> {
  const session = getSession(db, event.session_id);
  const payload = JSON.parse(event.payload);

  // 1. Send ntfy for Mac listener
  const ntfyPayload: NtfyEventPayload = {
    event_id: event.id,
    type: event.type as EventType,
    project: session?.project ?? "unknown",
    worktree: session?.worktree ?? "unknown",
    server_label: config.server_label,
    summary: summarizeEvent(event.type as EventType, payload),
  };
  await sendNtfy(ntfyPayload);

  // 2. If Telegram is configured, start escalation timer; otherwise mark done
  if (hasTelegram) {
    const delay = getDelay(event.type as EventType);
    const timer = setTimeout(() => {
      escalationTimers.delete(event.id);
      sendTelegramNotification(event, session, payload);
    }, delay);
    escalationTimers.set(event.id, timer);
  } else {
    // No Telegram — ntfy sent, nothing more to do
    updateEventStatus(db, event.id, "mac_acked");
  }
}

function summarizeEvent(type: EventType, payload: any): string {
  switch (type) {
    case "done":
      return payload.summary ?? "Agent finished";
    case "error":
      return payload.message ?? "Agent error";
    case "question":
      return payload.text ?? "Agent has a question";
    case "permission":
      return `${payload.tool}: ${payload.action}`;
  }
}

async function sendTelegramNotification(
  event: EventRow,
  session: SessionRow | null,
  payload: any
): Promise<void> {
  try {
    const { text } = formatNotification(
      config.server_label,
      session?.worktree ?? "unknown",
      event.type as EventType,
      payload
    );
    const keyboard = buildKeyboard(
      event.type as EventType,
      (session?.id ?? event.session_id).slice(0, 8),
      payload
    );

    const msg = await sendMessage(
      config.telegram.bot_token,
      config.telegram.chat_id,
      text,
      keyboard
    );

    setTelegramMsgId(db, event.id, msg.message_id);
    updateEventStatus(db, event.id, "tg_sent");
    console.log(`[daemon] Telegram notification sent for event ${event.id}`);
  } catch (err) {
    console.error(`[daemon] Failed to send Telegram for event ${event.id}:`, err);
  }
}

// ── Event watcher ───────────────────────────────────────────────────────────

async function pollEvents(): Promise<void> {
  while (true) {
    try {
      const pending = getPendingEvents(db);
      for (const event of pending) {
        await processEvent(event);
      }

      // Check for TUI-responded events that need Telegram update
      await updateRespondedMessages();

      // Check for stale sessions
      await handleStaleSessions();
    } catch (err) {
      console.error("[daemon] Event poll error:", err);
    }
    await sleep(2000);
  }
}

async function updateRespondedMessages(): Promise<void> {
  const responded = getRespondedEvents(db);
  for (const event of responded) {
    if (!event.telegram_msg_id) continue;
    try {
      await editMessageText(
        config.telegram.bot_token,
        config.telegram.chat_id,
        event.telegram_msg_id,
        "Answered from terminal",
        null // remove keyboard
      );
      // Clear the escalation timer if still pending
      const timer = escalationTimers.get(event.id);
      if (timer) {
        clearTimeout(timer);
        escalationTimers.delete(event.id);
      }
    } catch {
      // Message may already be updated
    }
    // Mark as fully handled to avoid re-processing
    // We update to a terminal state by re-setting responded (already set)
    // In practice, getRespondedEvents filters by telegram_msg_id IS NOT NULL
    // so we need to clear the telegram_msg_id or add another status.
    // For simplicity, set telegram_msg_id to null after updating.
    try {
      db.prepare("UPDATE events SET telegram_msg_id = NULL WHERE id = ?1").run(event.id);
    } catch { /* best effort */ }
  }
}

async function handleStaleSessions(): Promise<void> {
  const stale = getStaleSessions(db, 60);
  if (stale.length === 0) return;

  const staleIds = stale.map((s) => s.id);
  const events = getEventsForStaleSessions(db, staleIds);

  for (const event of events) {
    updateEventStatus(db, event.id, "stale");

    // Cancel any pending escalation
    const timer = escalationTimers.get(event.id);
    if (timer) {
      clearTimeout(timer);
      escalationTimers.delete(event.id);
    }

    // Update Telegram if we already sent
    if (event.telegram_msg_id) {
      try {
        await editMessageText(
          config.telegram.bot_token,
          config.telegram.chat_id,
          event.telegram_msg_id,
          "Agent is no longer running",
          null
        );
      } catch {
        // best effort
      }
    }
  }

  // Clean up stale session rows
  deleteSessions(db, staleIds);
}

// ── Telegram polling ────────────────────────────────────────────────────────

async function pollTelegram(): Promise<void> {
  let offset: number | undefined;

  while (true) {
    try {
      const updates = await getUpdates(config.telegram.bot_token, offset, 30);
      for (const update of updates) {
        offset = update.update_id + 1;
        await handleUpdate(update);
      }
    } catch (err) {
      console.error("[daemon] Telegram poll error:", err);
      await sleep(5000);
    }
  }
}

async function handleUpdate(update: TgUpdate): Promise<void> {
  if (update.callback_query) {
    await handleCallbackQuery(update.callback_query);
  } else if (update.message?.reply_to_message) {
    await handleTextReply(update.message);
  }
}

async function handleCallbackQuery(cq: {
  id: string;
  data?: string;
  message?: { message_id: number; chat: { id: number } };
}): Promise<void> {
  if (!cq.data) return;

  const decoded = decodeCallback(cq.data);
  if (!decoded) {
    await answerCallbackQuery(config.telegram.bot_token, cq.id, "Unknown action");
    return;
  }

  const session = getSessionByPrefix(db, decoded.sessionPrefix);
  if (!session) {
    await answerCallbackQuery(config.telegram.bot_token, cq.id, "Session not found");
    return;
  }

  switch (decoded.kind) {
    case "response": {
      await routeResponse(session, decoded, cq);
      break;
    }
    case "permission": {
      await routePermission(session, decoded, cq);
      break;
    }
    case "custom": {
      await handleCustomFlow(session, decoded, cq);
      break;
    }
    case "continue": {
      await handleContinueFlow(session, decoded, cq);
      break;
    }
  }
}

async function routeResponse(
  session: SessionRow,
  decoded: Extract<DecodedCallback, { kind: "response" }>,
  cq: { id: string; message?: { message_id: number } }
): Promise<void> {
  // Find the event associated with this Telegram message
  const event = cq.message?.message_id
    ? getEventByTelegramMsgId(db, cq.message.message_id)
    : null;

  const payload = event ? JSON.parse(event.payload) : null;

  let responseText: string;
  if (event?.type === "question" && payload?.options) {
    responseText = payload.options[decoded.optionIndex] ?? `Option ${decoded.optionIndex}`;
  } else if (event?.type === "error") {
    responseText = decoded.optionIndex === 0 ? "retry" : "abort";
  } else {
    responseText = `Option ${decoded.optionIndex}`;
  }

  try {
    await fetch(
      `http://localhost:${session.port}/session/${session.id}/message`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          parts: [{ type: "text", text: responseText }],
        }),
      }
    );

    await answerCallbackQuery(config.telegram.bot_token, cq.id, "Sent!");

    // Update the Telegram message
    if (cq.message?.message_id) {
      await editMessageText(
        config.telegram.bot_token,
        config.telegram.chat_id,
        cq.message.message_id,
        `Sent: ${responseText}. Agent continuing.`,
        null
      );
    }

    if (event) updateEventStatus(db, event.id, "responded");
  } catch (err) {
    console.error("[daemon] Failed to route response:", err);
    await answerCallbackQuery(
      config.telegram.bot_token,
      cq.id,
      "Could not reach agent — it may have exited"
    );

    if (cq.message?.message_id) {
      await sendMessage(
        config.telegram.bot_token,
        config.telegram.chat_id,
        "Could not reach agent — it may have exited"
      );
    }
  }
}

async function routePermission(
  session: SessionRow,
  decoded: Extract<DecodedCallback, { kind: "permission" }>,
  cq: { id: string; message?: { message_id: number } }
): Promise<void> {
  const event = cq.message?.message_id
    ? getEventByTelegramMsgId(db, cq.message.message_id)
    : null;

  const payload: PermissionPayload | null = event
    ? JSON.parse(event.payload)
    : null;

  const permissionId = payload?.permissionId ?? "";
  const response = decoded.allow ? "allow" : "deny";

  try {
    await fetch(
      `http://localhost:${session.port}/session/${session.id}/permissions/${permissionId}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ response }),
      }
    );

    const label = decoded.allow ? "Allowed" : "Denied";
    await answerCallbackQuery(config.telegram.bot_token, cq.id, label);

    if (cq.message?.message_id) {
      await editMessageText(
        config.telegram.bot_token,
        config.telegram.chat_id,
        cq.message.message_id,
        `Permission ${label.toLowerCase()}. Agent continuing.`,
        null
      );
    }

    if (event) updateEventStatus(db, event.id, "responded");
  } catch (err) {
    console.error("[daemon] Failed to route permission:", err);
    await answerCallbackQuery(
      config.telegram.bot_token,
      cq.id,
      "Could not reach agent — it may have exited"
    );

    await sendMessage(
      config.telegram.bot_token,
      config.telegram.chat_id,
      "Could not reach agent — it may have exited"
    );
  }
}

async function handleCustomFlow(
  session: SessionRow,
  decoded: Extract<DecodedCallback, { kind: "custom" }>,
  cq: { id: string; message?: { message_id: number } }
): Promise<void> {
  await answerCallbackQuery(config.telegram.bot_token, cq.id);

  const promptMsg = await sendMessage(
    config.telegram.bot_token,
    config.telegram.chat_id,
    "Reply to this message with your answer"
  );

  // Find the event so we can route the reply later
  const event = cq.message?.message_id
    ? getEventByTelegramMsgId(db, cq.message.message_id)
    : null;

  if (event) {
    customReplyPrompts.set(promptMsg.message_id, event.id);
  }
}

async function handleContinueFlow(
  session: SessionRow,
  decoded: Extract<DecodedCallback, { kind: "continue" }>,
  cq: { id: string; message?: { message_id: number } }
): Promise<void> {
  await answerCallbackQuery(config.telegram.bot_token, cq.id);

  const promptMsg = await sendMessage(
    config.telegram.bot_token,
    config.telegram.chat_id,
    "Reply to this message with your follow-up prompt"
  );

  const event = cq.message?.message_id
    ? getEventByTelegramMsgId(db, cq.message.message_id)
    : null;

  if (event) {
    customReplyPrompts.set(promptMsg.message_id, event.id);
  }
}

// ── Free-text reply handling ────────────────────────────────────────────────

async function handleTextReply(message: {
  text?: string;
  reply_to_message?: { message_id: number };
}): Promise<void> {
  if (!message.text || !message.reply_to_message) return;

  const replyToId = message.reply_to_message.message_id;

  // Check if this is a reply to a custom prompt
  let eventId = customReplyPrompts.get(replyToId);
  if (!eventId) {
    // Try to match against a notification message
    const event = getEventByTelegramMsgId(db, replyToId);
    if (event) eventId = event.id;
  }

  if (!eventId) return;

  const event = getEvent(db, eventId);
  if (!event) return;

  const session = getSession(db, event.session_id);
  if (!session) return;

  try {
    await fetch(
      `http://localhost:${session.port}/session/${session.id}/message`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          parts: [{ type: "text", text: message.text }],
        }),
      }
    );

    await sendMessage(
      config.telegram.bot_token,
      config.telegram.chat_id,
      `Sent: ${message.text}. Agent continuing.`
    );

    updateEventStatus(db, eventId, "responded");
    customReplyPrompts.delete(replyToId);
  } catch (err) {
    console.error("[daemon] Failed to route text reply:", err);
    await sendMessage(
      config.telegram.bot_token,
      config.telegram.chat_id,
      "Could not reach agent — it may have exited"
    );
  }
}

// ── Utilities ───────────────────────────────────────────────────────────────

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ── Start ───────────────────────────────────────────────────────────────────

startAckListener();
pollEvents();
if (hasTelegram) {
  pollTelegram();
} else {
  console.log("[daemon] No Telegram configured — skipping Telegram polling");
}

/**
 * Telegram Bot API client — thin wrapper around fetch.
 */

import type {
  EventType,
  QuestionPayload,
  PermissionPayload,
  ErrorPayload,
  DonePayload,
} from "./types";

const BASE = "https://api.telegram.org";

// ── Low-level helpers ───────────────────────────────────────────────────────

async function tgFetch<T>(
  token: string,
  method: string,
  body?: Record<string, unknown>
): Promise<T> {
  const url = `${BASE}/bot${token}/${method}`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = (await res.json()) as { ok: boolean; result: T; description?: string };
  if (!json.ok) {
    throw new Error(`Telegram API error (${method}): ${json.description ?? "unknown"}`);
  }
  return json.result;
}

// ── Types ───────────────────────────────────────────────────────────────────

export interface TgMessage {
  message_id: number;
  chat: { id: number };
  text?: string;
  reply_to_message?: TgMessage;
}

export interface TgCallbackQuery {
  id: string;
  data?: string;
  message?: TgMessage;
  from: { id: number };
}

export interface TgUpdate {
  update_id: number;
  callback_query?: TgCallbackQuery;
  message?: TgMessage;
}

export interface InlineKeyboardButton {
  text: string;
  callback_data: string;
}

export type InlineKeyboard = InlineKeyboardButton[][];

// ── Public API ──────────────────────────────────────────────────────────────

export async function getMe(token: string): Promise<{ id: number; username: string }> {
  return tgFetch(token, "getMe");
}

export async function sendMessage(
  token: string,
  chatId: string,
  text: string,
  keyboard?: InlineKeyboard,
  replyToMessageId?: number
): Promise<TgMessage> {
  const body: Record<string, unknown> = {
    chat_id: chatId,
    text,
    parse_mode: "HTML",
  };
  if (keyboard) {
    body.reply_markup = { inline_keyboard: keyboard };
  }
  if (replyToMessageId) {
    body.reply_to_message_id = replyToMessageId;
  }
  return tgFetch<TgMessage>(token, "sendMessage", body);
}

export async function editMessageText(
  token: string,
  chatId: string,
  messageId: number,
  text: string,
  keyboard?: InlineKeyboard | null
): Promise<TgMessage | boolean> {
  const body: Record<string, unknown> = {
    chat_id: chatId,
    message_id: messageId,
    text,
    parse_mode: "HTML",
  };
  if (keyboard === null) {
    // Explicitly remove keyboard
    body.reply_markup = { inline_keyboard: [] };
  } else if (keyboard) {
    body.reply_markup = { inline_keyboard: keyboard };
  }
  return tgFetch<TgMessage | boolean>(token, "editMessageText", body);
}

export async function answerCallbackQuery(
  token: string,
  callbackQueryId: string,
  text?: string
): Promise<boolean> {
  return tgFetch<boolean>(token, "answerCallbackQuery", {
    callback_query_id: callbackQueryId,
    text,
  });
}

export async function getUpdates(
  token: string,
  offset?: number,
  timeout: number = 30
): Promise<TgUpdate[]> {
  const body: Record<string, unknown> = { timeout };
  if (offset !== undefined) body.offset = offset;
  return tgFetch<TgUpdate[]>(token, "getUpdates", body);
}

// ── Callback data encoding/decoding ─────────────────────────────────────────

/**
 * Encode a response callback: `r|<8-char-prefix>|<option-index>`
 * Max 64 bytes — 2 + 1 + 8 + 1 + up to ~50 = well within limit.
 */
export function encodeResponseCallback(
  sessionIdPrefix: string,
  optionIndex: number
): string {
  const data = `r|${sessionIdPrefix.slice(0, 8)}|${optionIndex}`;
  if (new TextEncoder().encode(data).length > 64) {
    throw new Error(`callback_data exceeds 64 bytes: ${data}`);
  }
  return data;
}

/**
 * Encode a permission callback: `p|<8-char-prefix>|a` or `p|<8-char-prefix>|d`
 */
export function encodePermissionCallback(
  sessionIdPrefix: string,
  allow: boolean
): string {
  const data = `p|${sessionIdPrefix.slice(0, 8)}|${allow ? "a" : "d"}`;
  if (new TextEncoder().encode(data).length > 64) {
    throw new Error(`callback_data exceeds 64 bytes: ${data}`);
  }
  return data;
}

/**
 * Encode a "type custom" callback: `c|<8-char-prefix>`
 */
export function encodeCustomCallback(sessionIdPrefix: string): string {
  return `c|${sessionIdPrefix.slice(0, 8)}`;
}

/**
 * Encode a "continue" callback: `k|<8-char-prefix>`
 */
export function encodeContinueCallback(sessionIdPrefix: string): string {
  return `k|${sessionIdPrefix.slice(0, 8)}`;
}

export type DecodedCallback =
  | { kind: "response"; sessionPrefix: string; optionIndex: number }
  | { kind: "permission"; sessionPrefix: string; allow: boolean }
  | { kind: "custom"; sessionPrefix: string }
  | { kind: "continue"; sessionPrefix: string };

export function decodeCallback(data: string): DecodedCallback | null {
  const parts = data.split("|");
  if (parts.length < 2) return null;

  const [kind, sessionPrefix, ...rest] = parts;

  switch (kind) {
    case "r":
      return {
        kind: "response",
        sessionPrefix,
        optionIndex: Number(rest[0] ?? 0),
      };
    case "p":
      return {
        kind: "permission",
        sessionPrefix,
        allow: rest[0] === "a",
      };
    case "c":
      return { kind: "custom", sessionPrefix };
    case "k":
      return { kind: "continue", sessionPrefix };
    default:
      return null;
  }
}

// ── Message formatting ──────────────────────────────────────────────────────

export function formatNotification(
  serverLabel: string,
  worktree: string,
  eventType: EventType,
  payload: object
): { text: string; keyboard: InlineKeyboard } {
  const header = `<b>${worktree}</b> (${serverLabel})`;

  switch (eventType) {
    case "done": {
      const p = payload as DonePayload;
      const text = `${header}\n\nAgent finished: ${p.summary}`;
      // "Continue" button needs the session prefix which we don't have here.
      // The caller will build the keyboard.
      return { text, keyboard: [] };
    }
    case "error": {
      const p = payload as ErrorPayload;
      const text = `${header}\n\nAgent error: ${p.message}`;
      return { text, keyboard: [] };
    }
    case "question": {
      const p = payload as QuestionPayload;
      const text = `${header}\n\nAgent asking:\n${p.text}`;
      return { text, keyboard: [] };
    }
    case "permission": {
      const p = payload as PermissionPayload;
      const text = `${header}\n\nPermission requested: <b>${p.tool}</b>\n${p.action}`;
      return { text, keyboard: [] };
    }
  }
}

/**
 * Build the inline keyboard for a given event type.
 * Requires the 8-char session ID prefix.
 */
export function buildKeyboard(
  eventType: EventType,
  sessionPrefix: string,
  payload: object
): InlineKeyboard {
  switch (eventType) {
    case "question": {
      const p = payload as QuestionPayload;
      const rows: InlineKeyboard = p.options.map((opt, i) => [
        { text: opt, callback_data: encodeResponseCallback(sessionPrefix, i) },
      ]);
      rows.push([
        { text: "Type custom", callback_data: encodeCustomCallback(sessionPrefix) },
      ]);
      return rows;
    }
    case "permission": {
      return [
        [
          {
            text: "Allow",
            callback_data: encodePermissionCallback(sessionPrefix, true),
          },
          {
            text: "Deny",
            callback_data: encodePermissionCallback(sessionPrefix, false),
          },
        ],
      ];
    }
    case "error": {
      return [
        [
          {
            text: "Retry",
            callback_data: encodeResponseCallback(sessionPrefix, 0),
          },
          {
            text: "Abort",
            callback_data: encodeResponseCallback(sessionPrefix, 1),
          },
        ],
      ];
    }
    case "done": {
      return [
        [
          {
            text: "Continue",
            callback_data: encodeContinueCallback(sessionPrefix),
          },
        ],
      ];
    }
  }
}

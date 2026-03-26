// ── Event Types ─────────────────────────────────────────────────────────────

export type EventType = "done" | "error" | "question" | "permission";

export type EventStatus =
  | "pending"
  | "mac_acked"
  | "tg_sent"
  | "responded"
  | "stale";

// ── Event Payloads ──────────────────────────────────────────────────────────

export interface DonePayload {
  summary: string;
}

export interface ErrorPayload {
  message: string;
}

export interface QuestionPayload {
  text: string;
  options: string[];
}

export interface PermissionPayload {
  permissionId: string;
  tool: string;
  action: string;
}

export type EventPayload =
  | DonePayload
  | ErrorPayload
  | QuestionPayload
  | PermissionPayload;

// ── Registry Row Types ──────────────────────────────────────────────────────

export interface SessionRow {
  id: string;
  port: number;
  project: string;
  worktree: string;
  created_at: number;
  last_seen: number;
}

export interface EventRow {
  id: string;
  session_id: string;
  type: EventType;
  payload: string; // JSON-serialized EventPayload
  telegram_msg_id: number | null;
  status: EventStatus;
  created_at: number;
  responded_at: number | null;
}

// ── Config Schema ───────────────────────────────────────────────────────────

export type MachineRole = "main" | "server";

export interface TelegramConfig {
  bot_token: string;
  chat_id: string;
}

export interface NtfyConfig {
  events_topic: string;
  ack_topic: string;
  server?: string; // default: https://ntfy.sh
}

export interface DelayConfig {
  question: number; // seconds
  permission: number;
  error: number;
  done: number;
}

export interface AppConfig {
  role: MachineRole;
  server_label: string;
  telegram: TelegramConfig;
  ntfy: NtfyConfig;
  delays: DelayConfig;
}

// ── ntfy Payloads ───────────────────────────────────────────────────────────

export interface NtfyEventPayload {
  event_id: string;
  type: EventType;
  project: string;
  worktree: string;
  server_label: string;
  summary: string;
}

export interface NtfyAckPayload {
  event_id: string;
}

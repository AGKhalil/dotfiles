import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import type { EventRow, EventStatus, EventType, SessionRow } from "./types";

const DB_PATH =
  process.env.AGENT_NOTIFY_DB ??
  `${process.env.HOME}/.local/share/agent-notify/registry.db`;

// ── Initialisation ──────────────────────────────────────────────────────────

export function openDB(path: string = DB_PATH): Database {
  mkdirSync(dirname(path), { recursive: true });
  const db = new Database(path);
  db.exec("PRAGMA journal_mode = WAL");
  db.exec("PRAGMA busy_timeout = 5000");
  migrate(db);
  return db;
}

function migrate(db: Database): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS sessions (
      id          TEXT PRIMARY KEY,
      port        INTEGER NOT NULL,
      project     TEXT NOT NULL,
      worktree    TEXT NOT NULL,
      created_at  INTEGER NOT NULL DEFAULT (unixepoch()),
      last_seen   INTEGER NOT NULL DEFAULT (unixepoch())
    );

    CREATE TABLE IF NOT EXISTS events (
      id              TEXT PRIMARY KEY,
      session_id      TEXT NOT NULL REFERENCES sessions(id),
      type            TEXT NOT NULL,
      payload         TEXT NOT NULL,
      telegram_msg_id INTEGER,
      status          TEXT NOT NULL DEFAULT 'pending',
      created_at      INTEGER NOT NULL DEFAULT (unixepoch()),
      responded_at    INTEGER
    );

    CREATE INDEX IF NOT EXISTS idx_events_status ON events(status);
    CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id);
  `);

  // Migration: add name column to sessions if missing
  const cols = db.prepare("PRAGMA table_info(sessions)").all() as { name: string }[];
  if (!cols.some((c) => c.name === "name")) {
    db.exec("ALTER TABLE sessions ADD COLUMN name TEXT NOT NULL DEFAULT ''");
  }
}

// ── Session helpers ─────────────────────────────────────────────────────────

export function upsertSession(
  db: Database,
  session: Pick<SessionRow, "id" | "port" | "project" | "worktree"> & { name?: string }
): void {
  db.prepare(
    `INSERT INTO sessions (id, port, project, worktree, name)
     VALUES (?1, ?2, ?3, ?4, ?5)
     ON CONFLICT(id) DO UPDATE SET
       port = CASE WHEN excluded.port != 0 THEN excluded.port ELSE sessions.port END,
       project = CASE WHEN excluded.project != 'unknown' AND excluded.project != '' THEN excluded.project ELSE sessions.project END,
       worktree = CASE WHEN excluded.worktree != 'unknown' AND excluded.worktree != '' THEN excluded.worktree ELSE sessions.worktree END,
       name = CASE WHEN excluded.name != '' THEN excluded.name ELSE sessions.name END,
       last_seen = unixepoch()`
  ).run(session.id, session.port, session.project, session.worktree, session.name ?? "");
}

export function updateSessionName(db: Database, sessionId: string, name: string): void {
  db.prepare("UPDATE sessions SET name = ?2 WHERE id = ?1").run(sessionId, name);
}

export function updateHeartbeat(db: Database, sessionIds: string[]): void {
  if (sessionIds.length === 0) return;
  const placeholders = sessionIds.map(() => "?").join(",");
  db.prepare(
    `UPDATE sessions SET last_seen = unixepoch() WHERE id IN (${placeholders})`
  ).run(...sessionIds);
}

export function deleteSessions(db: Database, sessionIds: string[]): void {
  if (sessionIds.length === 0) return;
  const placeholders = sessionIds.map(() => "?").join(",");
  // Only delete sessions that have no active events (keep session data
  // intact for events still visible in the notification panel).
  db.prepare(
    `DELETE FROM sessions WHERE id IN (${placeholders})
     AND id NOT IN (
       SELECT DISTINCT session_id FROM events
       WHERE status NOT IN ('dismissed', 'stale')
     )`
  ).run(...sessionIds);
}

export function getStaleSessions(
  db: Database,
  thresholdSecs: number = 60
): SessionRow[] {
  return db
    .prepare(
      `SELECT * FROM sessions WHERE last_seen < unixepoch() - ?1 AND port != 0`
    )
    .all(thresholdSecs) as SessionRow[];
}

export function getSession(db: Database, id: string): SessionRow | null {
  return (
    (db.prepare(`SELECT * FROM sessions WHERE id = ?1`).get(id) as SessionRow) ??
    null
  );
}

export function getSessionByPrefix(
  db: Database,
  prefix: string
): SessionRow | null {
  return (
    (db
      .prepare(`SELECT * FROM sessions WHERE id LIKE ?1 LIMIT 1`)
      .get(`${prefix}%`) as SessionRow) ?? null
  );
}

// ── Event helpers ───────────────────────────────────────────────────────────

export function insertEvent(
  db: Database,
  event: Pick<EventRow, "id" | "session_id" | "type" | "payload">
): void {
  db.prepare(
    `INSERT INTO events (id, session_id, type, payload)
     VALUES (?1, ?2, ?3, ?4)`
  ).run(event.id, event.session_id, event.type, event.payload);
}

export function getPendingEvents(db: Database): EventRow[] {
  return db
    .prepare(`SELECT * FROM events WHERE status = 'pending' ORDER BY created_at`)
    .all() as EventRow[];
}

export function getEventsByStatus(
  db: Database,
  status: EventStatus
): EventRow[] {
  return db
    .prepare(`SELECT * FROM events WHERE status = ?1 ORDER BY created_at`)
    .all(status) as EventRow[];
}

export function getEvent(db: Database, id: string): EventRow | null {
  return (
    (db.prepare(`SELECT * FROM events WHERE id = ?1`).get(id) as EventRow) ??
    null
  );
}

export function getEventByTelegramMsgId(
  db: Database,
  msgId: number
): EventRow | null {
  return (
    (db
      .prepare(`SELECT * FROM events WHERE telegram_msg_id = ?1`)
      .get(msgId) as EventRow) ?? null
  );
}

export function updateEventStatus(
  db: Database,
  eventId: string,
  status: EventStatus
): void {
  const extra = status === "responded" ? ", responded_at = unixepoch()" : "";
  db.prepare(
    `UPDATE events SET status = ?2${extra} WHERE id = ?1`
  ).run(eventId, status);
}

export function setTelegramMsgId(
  db: Database,
  eventId: string,
  msgId: number
): void {
  db.prepare(
    `UPDATE events SET telegram_msg_id = ?2 WHERE id = ?1`
  ).run(eventId, msgId);
}

export function getPendingEventsForSession(
  db: Database,
  sessionId: string
): EventRow[] {
  return db
    .prepare(
      `SELECT * FROM events WHERE session_id = ?1 AND status IN ('pending', 'mac_acked', 'tg_sent') ORDER BY created_at`
    )
    .all(sessionId) as EventRow[];
}

export function getEventsForStaleSessions(
  db: Database,
  sessionIds: string[]
): EventRow[] {
  if (sessionIds.length === 0) return [];
  const placeholders = sessionIds.map(() => "?").join(",");
  return db
    .prepare(
      `SELECT * FROM events
       WHERE session_id IN (${placeholders})
         AND status IN ('pending', 'tg_sent')
       ORDER BY created_at`
    )
    .all(...sessionIds) as EventRow[];
}

// ── Responded-event detection ───────────────────────────────────────────────

export function getRespondedEvents(db: Database): EventRow[] {
  return db
    .prepare(
      `SELECT * FROM events WHERE status = 'responded' AND telegram_msg_id IS NOT NULL ORDER BY responded_at`
    )
    .all() as EventRow[];
}

/** All responded events (with or without Telegram), for dismiss notifications. */
export function getAllRespondedEvents(db: Database): EventRow[] {
  return db
    .prepare(
      `SELECT * FROM events WHERE status = 'responded' ORDER BY responded_at`
    )
    .all() as EventRow[];
}

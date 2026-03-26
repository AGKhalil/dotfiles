import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  openDB,
  upsertSession,
  updateHeartbeat,
  deleteSessions,
  getStaleSessions,
  getSession,
  getSessionByPrefix,
  insertEvent,
  getPendingEvents,
  getEvent,
  getEventByTelegramMsgId,
  updateEventStatus,
  setTelegramMsgId,
  getPendingEventsForSession,
  getRespondedEvents,
  getEventsForStaleSessions,
} from "../src/db";
import type { Database } from "bun:sqlite";

let tmpDir: string;
let db: Database;

beforeEach(() => {
  tmpDir = mkdtempSync(join(tmpdir(), "an-test-"));
  db = openDB(join(tmpDir, "test.db"));
});

afterEach(() => {
  db.close();
  rmSync(tmpDir, { recursive: true, force: true });
});

describe("SQLite module", () => {
  test("creates tables on init", () => {
    const tables = db
      .prepare(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
      )
      .all() as { name: string }[];
    const names = tables.map((t) => t.name);
    expect(names).toContain("sessions");
    expect(names).toContain("events");
  });

  test("WAL mode is enabled", () => {
    const result = db.prepare("PRAGMA journal_mode").get() as {
      journal_mode: string;
    };
    expect(result.journal_mode).toBe("wal");
  });

  test("insert and query session", () => {
    upsertSession(db, {
      id: "sess-001",
      port: 4096,
      project: "myproject",
      worktree: "feature-x",
    });
    const row = getSession(db, "sess-001");
    expect(row).not.toBeNull();
    expect(row!.port).toBe(4096);
    expect(row!.project).toBe("myproject");
    expect(row!.worktree).toBe("feature-x");
  });

  test("upsert updates port and last_seen", () => {
    upsertSession(db, {
      id: "sess-002",
      port: 4096,
      project: "p",
      worktree: "w",
    });
    upsertSession(db, {
      id: "sess-002",
      port: 5000,
      project: "p",
      worktree: "w",
    });
    const row = getSession(db, "sess-002");
    expect(row!.port).toBe(5000);
  });

  test("session prefix lookup", () => {
    upsertSession(db, {
      id: "abcdef12-3456-7890-abcd-ef1234567890",
      port: 4096,
      project: "p",
      worktree: "w",
    });
    const row = getSessionByPrefix(db, "abcdef12");
    expect(row).not.toBeNull();
    expect(row!.id).toBe("abcdef12-3456-7890-abcd-ef1234567890");
  });

  test("heartbeat updates last_seen", () => {
    upsertSession(db, {
      id: "sess-hb",
      port: 4096,
      project: "p",
      worktree: "w",
    });
    const before = getSession(db, "sess-hb")!.last_seen;
    // Simulate passage of time (SQLite uses integer seconds)
    db.prepare(
      "UPDATE sessions SET last_seen = last_seen - 10 WHERE id = 'sess-hb'"
    ).run();
    updateHeartbeat(db, ["sess-hb"]);
    const after = getSession(db, "sess-hb")!.last_seen;
    expect(after).toBeGreaterThanOrEqual(before);
  });

  test("stale session detection", () => {
    upsertSession(db, {
      id: "sess-stale",
      port: 4096,
      project: "p",
      worktree: "w",
    });
    // Make it stale
    db.prepare(
      "UPDATE sessions SET last_seen = last_seen - 120 WHERE id = 'sess-stale'"
    ).run();
    const stale = getStaleSessions(db, 60);
    expect(stale.length).toBe(1);
    expect(stale[0].id).toBe("sess-stale");
  });

  test("delete sessions", () => {
    upsertSession(db, {
      id: "sess-del",
      port: 4096,
      project: "p",
      worktree: "w",
    });
    deleteSessions(db, ["sess-del"]);
    expect(getSession(db, "sess-del")).toBeNull();
  });

  test("insert and query events", () => {
    upsertSession(db, {
      id: "sess-evt",
      port: 4096,
      project: "p",
      worktree: "w",
    });
    insertEvent(db, {
      id: "evt-001",
      session_id: "sess-evt",
      type: "done",
      payload: JSON.stringify({ summary: "finished" }),
    });
    const pending = getPendingEvents(db);
    expect(pending.length).toBe(1);
    expect(pending[0].id).toBe("evt-001");
    expect(pending[0].status).toBe("pending");
  });

  test("update event status", () => {
    upsertSession(db, {
      id: "sess-es",
      port: 4096,
      project: "p",
      worktree: "w",
    });
    insertEvent(db, {
      id: "evt-es",
      session_id: "sess-es",
      type: "question",
      payload: "{}",
    });
    updateEventStatus(db, "evt-es", "responded");
    const evt = getEvent(db, "evt-es");
    expect(evt!.status).toBe("responded");
    expect(evt!.responded_at).not.toBeNull();
  });

  test("set and query telegram_msg_id", () => {
    upsertSession(db, {
      id: "sess-tg",
      port: 4096,
      project: "p",
      worktree: "w",
    });
    insertEvent(db, {
      id: "evt-tg",
      session_id: "sess-tg",
      type: "error",
      payload: "{}",
    });
    setTelegramMsgId(db, "evt-tg", 12345);
    const evt = getEventByTelegramMsgId(db, 12345);
    expect(evt).not.toBeNull();
    expect(evt!.id).toBe("evt-tg");
  });

  test("concurrent writes from multiple connections", () => {
    const db2 = openDB(join(tmpDir, "test.db"));
    try {
      upsertSession(db, {
        id: "sess-c1",
        port: 4096,
        project: "p",
        worktree: "w",
      });
      upsertSession(db2, {
        id: "sess-c2",
        port: 4097,
        project: "p",
        worktree: "w",
      });
      expect(getSession(db, "sess-c1")).not.toBeNull();
      expect(getSession(db, "sess-c2")).not.toBeNull();
      expect(getSession(db2, "sess-c1")).not.toBeNull();
      expect(getSession(db2, "sess-c2")).not.toBeNull();
    } finally {
      db2.close();
    }
  });

  test("getPendingEventsForSession filters correctly", () => {
    upsertSession(db, {
      id: "sess-pf",
      port: 4096,
      project: "p",
      worktree: "w",
    });
    insertEvent(db, {
      id: "evt-pf1",
      session_id: "sess-pf",
      type: "done",
      payload: "{}",
    });
    insertEvent(db, {
      id: "evt-pf2",
      session_id: "sess-pf",
      type: "error",
      payload: "{}",
    });
    updateEventStatus(db, "evt-pf1", "responded");

    const pending = getPendingEventsForSession(db, "sess-pf");
    expect(pending.length).toBe(1);
    expect(pending[0].id).toBe("evt-pf2");
  });

  test("getEventsForStaleSessions returns events for given session IDs", () => {
    upsertSession(db, {
      id: "sess-s1",
      port: 4096,
      project: "p",
      worktree: "w",
    });
    upsertSession(db, {
      id: "sess-s2",
      port: 4097,
      project: "p",
      worktree: "w",
    });
    insertEvent(db, {
      id: "evt-s1",
      session_id: "sess-s1",
      type: "done",
      payload: "{}",
    });
    insertEvent(db, {
      id: "evt-s2",
      session_id: "sess-s2",
      type: "error",
      payload: "{}",
    });

    const events = getEventsForStaleSessions(db, ["sess-s1"]);
    expect(events.length).toBe(1);
    expect(events[0].session_id).toBe("sess-s1");
  });
});

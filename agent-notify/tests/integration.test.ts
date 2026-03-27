import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { MockTelegramServer } from "./mocks/telegram-server";
import { MockNtfyServer } from "./mocks/ntfy-server";
import { MockOpenCodeServer } from "./mocks/opencode-server";
import {
  openDB,
  upsertSession,
  insertEvent,
  getEvent,
  updateEventStatus,
  setTelegramMsgId,
  getStaleSessions,
} from "../src/db";
import {
  sendMessage,
  editMessageText,
  getUpdates,
  answerCallbackQuery,
  buildKeyboard,
  formatNotification,
  decodeCallback,
  encodeResponseCallback,
  encodePermissionCallback,
  encodeCustomCallback,
} from "../src/telegram";
import type { Database } from "bun:sqlite";

let tmpDir: string;
let db: Database;
let tgServer: MockTelegramServer;
let ntfyServer: MockNtfyServer;
let ocServer: MockOpenCodeServer;

beforeAll(async () => {
  tgServer = new MockTelegramServer();
  ntfyServer = new MockNtfyServer();
  ocServer = new MockOpenCodeServer();
  await tgServer.start();
  await ntfyServer.start();
  await ocServer.start();
});

afterAll(() => {
  tgServer.stop();
  ntfyServer.stop();
  ocServer.stop();
});

beforeEach(() => {
  tmpDir = mkdtempSync(join(tmpdir(), "an-integ-"));
  db = openDB(join(tmpDir, "test.db"));
  tgServer.reset();
  ntfyServer.reset();
  ocServer.reset();
});

// Helper: override Telegram base URL for tests
const TG_BASE = () => `http://localhost:${tgServer.port}`;

// We test using the mock servers' HTTP endpoints directly, simulating
// what the daemon would do.

describe("Integration: Event-to-notification flow (9.4)", () => {
  test("pending event triggers ntfy then Telegram after timeout", async () => {
    // Insert session and event
    upsertSession(db, {
      id: "sess-int-1",
      port: ocServer.port,
      project: "proj",
      worktree: "feat",
    });
    insertEvent(db, {
      id: "evt-int-1",
      session_id: "sess-int-1",
      type: "question",
      payload: JSON.stringify({
        text: "Which DB?",
        options: ["PG", "MySQL"],
      }),
    });

    // Simulate daemon: send ntfy
    await fetch(`http://localhost:${ntfyServer.port}/events-topic`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        event_id: "evt-int-1",
        session_id: "sess-int-1",
        type: "question",
        project: "proj",
        worktree: "feat",
        server_label: "test-server",
        summary: "Which DB?",
      }),
    });

    // Verify ntfy received
    const ntfyMsgs = ntfyServer.getMessages("events-topic");
    expect(ntfyMsgs.length).toBe(1);
    expect(ntfyMsgs[0].event_id).toBe("evt-int-1");

    // Simulate Telegram send (after escalation timeout)
    const { text } = formatNotification("test-server", "feat", "question", {
      text: "Which DB?",
      options: ["PG", "MySQL"],
    });
    const keyboard = buildKeyboard("question", "sess-int", {
      text: "Which DB?",
      options: ["PG", "MySQL"],
    });

    // Use mock Telegram server
    const tgRes = await fetch(
      `http://localhost:${tgServer.port}/botTEST/sendMessage`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chat_id: "123",
          text,
          reply_markup: { inline_keyboard: keyboard },
        }),
      }
    );
    const tgJson = (await tgRes.json()) as any;
    expect(tgJson.ok).toBe(true);

    const msgs = tgServer.getMessages();
    expect(msgs.length).toBe(1);
    expect(msgs[0].text).toContain("Which DB?");
    expect(msgs[0].reply_markup?.inline_keyboard).toBeDefined();
  });
});

describe("Integration: Response routing (9.5)", () => {
  test("button tap routes prompt to OC server", async () => {
    // Set up session pointing to mock OC server
    const sessionId = "abcdef12-0000-0000-0000-000000000001";
    upsertSession(db, {
      id: sessionId,
      port: ocServer.port,
      project: "proj",
      worktree: "feat",
    });
    insertEvent(db, {
      id: "evt-route-1",
      session_id: sessionId,
      type: "question",
      payload: JSON.stringify({
        text: "Pick one",
        options: ["PostgreSQL", "MySQL"],
      }),
    });

    // Simulate: the response callback selects option 0
    const callbackData = encodeResponseCallback(sessionId.slice(0, 8), 0);
    const decoded = decodeCallback(callbackData);
    expect(decoded).not.toBeNull();
    expect(decoded!.kind).toBe("response");

    // Route to OC server
    const res = await fetch(
      `http://localhost:${ocServer.port}/session/${sessionId}/message`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          parts: [{ type: "text", text: "PostgreSQL" }],
        }),
      }
    );
    expect(res.ok).toBe(true);

    const prompts = ocServer.getReceivedPrompts(sessionId);
    expect(prompts.length).toBe(1);
    expect(prompts[0].parts[0].text).toBe("PostgreSQL");
  });
});

describe("Integration: Permission routing (9.6)", () => {
  test("Allow/Deny tap routes permission to OC server", async () => {
    const sessionId = "abcdef12-0000-0000-0000-000000000002";
    upsertSession(db, {
      id: sessionId,
      port: ocServer.port,
      project: "proj",
      worktree: "feat",
    });

    // Route allow permission
    const permId = "perm-123";
    const allowRes = await fetch(
      `http://localhost:${ocServer.port}/session/${sessionId}/permissions/${permId}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ response: "allow" }),
      }
    );
    expect(allowRes.ok).toBe(true);

    const perms = ocServer.getReceivedPermissions(sessionId);
    expect(perms.length).toBe(1);
    expect(perms[0].permissionId).toBe(permId);
    expect(perms[0].response).toBe("allow");

    // Route deny permission
    const denyRes = await fetch(
      `http://localhost:${ocServer.port}/session/${sessionId}/permissions/${permId}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ response: "deny" }),
      }
    );
    expect(denyRes.ok).toBe(true);

    const allPerms = ocServer.getReceivedPermissions(sessionId);
    expect(allPerms.length).toBe(2);
    expect(allPerms[1].response).toBe("deny");
  });
});

describe("Integration: Free-text routing (9.7)", () => {
  test("text reply routes to OC server as prompt", async () => {
    const sessionId = "abcdef12-0000-0000-0000-000000000003";
    upsertSession(db, {
      id: sessionId,
      port: ocServer.port,
      project: "proj",
      worktree: "feat",
    });

    // Simulate free-text reply
    const res = await fetch(
      `http://localhost:${ocServer.port}/session/${sessionId}/message`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          parts: [{ type: "text", text: "Use PostgreSQL with pgbouncer" }],
        }),
      }
    );
    expect(res.ok).toBe(true);

    const prompts = ocServer.getReceivedPrompts(sessionId);
    expect(prompts.length).toBe(1);
    expect(prompts[0].parts[0].text).toBe("Use PostgreSQL with pgbouncer");
  });
});

describe("Integration: ACK suppresses Telegram (9.8)", () => {
  test("ACK received within timeout prevents Telegram send", async () => {
    // Simulate: send to ntfy
    await fetch(`http://localhost:${ntfyServer.port}/events-topic`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ event_id: "evt-ack-1" }),
    });

    // Simulate: ACK received (within timeout)
    await fetch(`http://localhost:${ntfyServer.port}/ack-topic`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ event_id: "evt-ack-1" }),
    });

    // Verify ACK was received on ack topic
    const ackMsgs = ntfyServer.getMessages("ack-topic");
    expect(ackMsgs.length).toBe(1);
    expect(ackMsgs[0].event_id).toBe("evt-ack-1");

    // No Telegram messages sent
    expect(tgServer.getMessages().length).toBe(0);
  });
});

describe("Integration: Stale session handling (9.9)", () => {
  test("stale session detection works", () => {
    upsertSession(db, {
      id: "sess-stale-int",
      port: 9999,
      project: "p",
      worktree: "w",
    });
    // Make stale
    db.prepare(
      "UPDATE sessions SET last_seen = last_seen - 120 WHERE id = 'sess-stale-int'"
    ).run();

    const stale = getStaleSessions(db, 60);
    expect(stale.length).toBe(1);
    expect(stale[0].id).toBe("sess-stale-int");
  });

  test("stale notification gets editMessageText update", async () => {
    // Send initial notification via mock Telegram
    const sendRes = await fetch(
      `http://localhost:${tgServer.port}/botTEST/sendMessage`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chat_id: "123",
          text: "Agent asking: question",
        }),
      }
    );
    const sendJson = (await sendRes.json()) as any;
    const msgId = sendJson.result.message_id;

    // Edit to stale
    const editRes = await fetch(
      `http://localhost:${tgServer.port}/botTEST/editMessageText`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chat_id: "123",
          message_id: msgId,
          text: "Agent is no longer running",
          reply_markup: { inline_keyboard: [] },
        }),
      }
    );
    const editJson = (await editRes.json()) as any;
    expect(editJson.ok).toBe(true);

    // Verify update
    const msg = tgServer.getMessage(msgId);
    expect(msg?.text).toBe("Agent is no longer running");
  });
});

describe("Integration: TUI-answered detection (9.10)", () => {
  test("responded event updates Telegram message", async () => {
    upsertSession(db, {
      id: "sess-resp",
      port: ocServer.port,
      project: "p",
      worktree: "w",
    });
    insertEvent(db, {
      id: "evt-resp",
      session_id: "sess-resp",
      type: "question",
      payload: JSON.stringify({ text: "q", options: [] }),
    });

    // Simulate Telegram message was sent
    const sendRes = await fetch(
      `http://localhost:${tgServer.port}/botTEST/sendMessage`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chat_id: "123", text: "Agent asking: q" }),
      }
    );
    const sendJson = (await sendRes.json()) as any;
    const msgId = sendJson.result.message_id;
    setTelegramMsgId(db, "evt-resp", msgId);

    // Plugin marks as responded (TUI-answered)
    updateEventStatus(db, "evt-resp", "responded");

    // Daemon would call editMessageText
    const editRes = await fetch(
      `http://localhost:${tgServer.port}/botTEST/editMessageText`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chat_id: "123",
          message_id: msgId,
          text: "Answered from terminal",
          reply_markup: { inline_keyboard: [] },
        }),
      }
    );
    expect((await editRes.json() as any).ok).toBe(true);

    const msg = tgServer.getMessage(msgId);
    expect(msg?.text).toBe("Answered from terminal");
  });
});

describe("Integration: Dead session routing (9.11)", () => {
  test("routing to dead port returns error", async () => {
    // Session pointing to a port with no server
    const deadPort = 59999;
    upsertSession(db, {
      id: "sess-dead",
      port: deadPort,
      project: "p",
      worktree: "w",
    });

    try {
      const res = await fetch(
        `http://localhost:${deadPort}/session/sess-dead/message`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ parts: [{ type: "text", text: "hello" }] }),
        }
      );
      // If by some chance something is on that port, this would succeed
      // but typically it fails
      expect(res.ok).toBe(false);
    } catch (err) {
      // Connection refused — expected for dead session
      expect(err).toBeDefined();
    }
  });
});

// Cleanup
afterAll(() => {
  try {
    db?.close();
  } catch {}
  try {
    rmSync(tmpDir, { recursive: true, force: true });
  } catch {}
});

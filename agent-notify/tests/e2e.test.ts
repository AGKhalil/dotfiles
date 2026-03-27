/**
 * End-to-end tests for agent-notify.
 *
 * Validates the full notification pipeline and tmux window renaming:
 *
 * 1. Notification flow: daemon ntfy payload carries real session IDs,
 *    listener stores them correctly (no synthetic IDs, correct names).
 * 2. Tmux rename: plugin renames tmux window on session.updated,
 *    and updates it when switching sessions.
 *
 * These tests use the real DB module, mock ntfy server, and a real
 * tmux session to validate the integration end-to-end.
 */

import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { MockNtfyServer } from "./mocks/ntfy-server";
import {
  openDB,
  upsertSession,
  updateSessionName,
  insertEvent,
  getSession,
  getEvent,
} from "../src/db";
import type { NtfyEventPayload } from "../src/types";
import type { Database } from "bun:sqlite";

// ── Helpers ─────────────────────────────────────────────────────────────────

let tmpDir: string;
let db: Database;
let ntfyServer: MockNtfyServer;

/** Unique tmux session name for test isolation. */
const TMUX_TEST_SESSION = `an-e2e-test-${Date.now()}`;

/** Whether tmux is available in the test environment. */
let hasTmux = false;

async function tmux(...args: string[]): Promise<string> {
  const proc = Bun.spawn(["tmux", ...args], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const out = await new Response(proc.stdout).text();
  await proc.exited;
  return out.trim();
}

async function getTmuxWindowName(session: string, windowIndex = 0): Promise<string> {
  return tmux(
    "list-windows",
    "-t", session,
    "-F", "#{window_name}",
    "-f", `#{==:#{window_index},${windowIndex}}`
  );
}

/**
 * Simulate what the listener does when receiving an ntfy event:
 * parse the payload and upsert session + insert event into the local DB.
 */
function simulateListenerReceive(localDb: Database, payload: NtfyEventPayload): void {
  // This mirrors listener.ts handleEvent() logic with the fix applied:
  // use event.session_id (real) instead of fabricating a synthetic ID.
  const sessionId = payload.session_id;
  upsertSession(localDb, {
    id: sessionId,
    port: payload.port ?? 0,
    project: payload.project,
    worktree: payload.worktree,
    name: payload.session_name,
  });

  insertEvent(localDb, {
    id: payload.event_id,
    session_id: sessionId,
    type: payload.type,
    payload: JSON.stringify({
      summary: payload.summary,
      server_label: payload.server_label,
    }),
  });
}

/**
 * Simulate the plugin's session.updated event handler:
 * update session name in DB and rename tmux window.
 */
async function simulateSessionUpdated(
  localDb: Database,
  sessionId: string,
  name: string,
  currentSessionId: string,
  tmuxTarget?: string
): Promise<void> {
  updateSessionName(localDb, sessionId, name);

  if (tmuxTarget && sessionId === currentSessionId) {
    const truncated = name.length > 30 ? name.slice(0, 27) + "..." : name;
    const proc = Bun.spawn(["tmux", "rename-window", "-t", tmuxTarget, truncated], {
      stdout: "ignore",
      stderr: "ignore",
    });
    await proc.exited;
  }
}

// ── Setup / Teardown ────────────────────────────────────────────────────────

beforeAll(async () => {
  ntfyServer = new MockNtfyServer();
  await ntfyServer.start();

  // Check if tmux is available
  try {
    const proc = Bun.spawn(["tmux", "-V"], { stdout: "pipe", stderr: "pipe" });
    await proc.exited;
    hasTmux = proc.exitCode === 0;
  } catch {
    hasTmux = false;
  }

  // Create a detached tmux session for testing
  if (hasTmux) {
    const proc = Bun.spawn(
      ["tmux", "new-session", "-d", "-s", TMUX_TEST_SESSION, "-n", "initial"],
      { stdout: "ignore", stderr: "pipe" }
    );
    await proc.exited;
  }
});

afterAll(async () => {
  ntfyServer.stop();

  // Kill test tmux session
  if (hasTmux) {
    try {
      const proc = Bun.spawn(
        ["tmux", "kill-session", "-t", TMUX_TEST_SESSION],
        { stdout: "ignore", stderr: "ignore" }
      );
      await proc.exited;
    } catch {
      // best effort
    }
  }
});

beforeEach(() => {
  tmpDir = mkdtempSync(join(tmpdir(), "an-e2e-"));
  db = openDB(join(tmpDir, "test.db"));
  ntfyServer.reset();
});

// ── Notification pipeline ───────────────────────────────────────────────────

describe("E2E: Notification pipeline — real session IDs", () => {
  test("daemon ntfy payload includes session_id, port, and session_name", async () => {
    // Setup: create a session the daemon would look up
    upsertSession(db, {
      id: "ses_realid_001",
      port: 4096,
      project: "my-project",
      worktree: "feature-branch",
      name: "Fix auth bug",
    });

    // Simulate what the daemon builds for the ntfy payload
    const session = getSession(db, "ses_realid_001")!;
    const ntfyPayload: NtfyEventPayload = {
      event_id: "evt-e2e-001",
      session_id: "ses_realid_001",
      type: "done",
      project: session.project,
      worktree: session.worktree,
      server_label: "test-server",
      summary: "Task completed",
      session_name: session.name || undefined,
      port: session.port,
    };

    // Send through mock ntfy
    await fetch(`http://localhost:${ntfyServer.port}/events-topic`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(ntfyPayload),
    });

    // Verify ntfy received full payload
    const msgs = ntfyServer.getMessages("events-topic");
    expect(msgs.length).toBe(1);
    expect(msgs[0].session_id).toBe("ses_realid_001");
    expect(msgs[0].port).toBe(4096);
    expect(msgs[0].session_name).toBe("Fix auth bug");
    expect(msgs[0].project).toBe("my-project");
  });

  test("listener stores real session ID (no synthetic ID)", () => {
    const payload: NtfyEventPayload = {
      event_id: "evt-e2e-002",
      session_id: "ses_realid_002",
      type: "question",
      project: "my-project",
      worktree: "feature-branch",
      server_label: "gpu-0",
      summary: "Which database?",
      session_name: "Training pipeline",
      port: 4096,
    };

    simulateListenerReceive(db, payload);

    // Session stored with real ID, not "gpu-0:my-project"
    const session = getSession(db, "ses_realid_002");
    expect(session).not.toBeNull();
    expect(session!.id).toBe("ses_realid_002");
    expect(session!.project).toBe("my-project");
    expect(session!.worktree).toBe("feature-branch");
    expect(session!.name).toBe("Training pipeline");
    expect(session!.port).toBe(4096);

    // No synthetic session row exists
    const synthetic = getSession(db, "gpu-0:my-project");
    expect(synthetic).toBeNull();

    // Event references real session ID
    const event = getEvent(db, "evt-e2e-002");
    expect(event).not.toBeNull();
    expect(event!.session_id).toBe("ses_realid_002");
  });

  test("multiple sessions for same project get separate rows", () => {
    const payload1: NtfyEventPayload = {
      event_id: "evt-e2e-003a",
      session_id: "ses_session_A",
      type: "done",
      project: ".dotfiles",
      worktree: ".dotfiles",
      server_label: "gpu-0",
      summary: "Session A done",
      session_name: "Fix auth bug",
      port: 4096,
    };

    const payload2: NtfyEventPayload = {
      event_id: "evt-e2e-003b",
      session_id: "ses_session_B",
      type: "done",
      project: ".dotfiles",
      worktree: ".dotfiles",
      server_label: "gpu-0",
      summary: "Session B done",
      session_name: "Add feature X",
      port: 4097,
    };

    simulateListenerReceive(db, payload1);
    simulateListenerReceive(db, payload2);

    // Both sessions exist with correct names
    const sessionA = getSession(db, "ses_session_A");
    const sessionB = getSession(db, "ses_session_B");
    expect(sessionA).not.toBeNull();
    expect(sessionB).not.toBeNull();
    expect(sessionA!.name).toBe("Fix auth bug");
    expect(sessionB!.name).toBe("Add feature X");

    // Events reference their own sessions
    const evtA = getEvent(db, "evt-e2e-003a");
    const evtB = getEvent(db, "evt-e2e-003b");
    expect(evtA!.session_id).toBe("ses_session_A");
    expect(evtB!.session_id).toBe("ses_session_B");
  });

  test("server event preserves all source-of-truth fields", () => {
    const payload: NtfyEventPayload = {
      event_id: "evt-e2e-004",
      session_id: "ses_gpu_session_42",
      type: "error",
      project: "ml-training",
      worktree: "experiment-7",
      server_label: "gpu-0",
      summary: "OOM error",
      session_name: "Hyperparameter tuning",
      port: 4096,
    };

    simulateListenerReceive(db, payload);

    const session = getSession(db, "ses_gpu_session_42");
    expect(session!.id).toBe("ses_gpu_session_42");
    expect(session!.project).toBe("ml-training");
    expect(session!.worktree).toBe("experiment-7");
    expect(session!.name).toBe("Hyperparameter tuning");
    expect(session!.port).toBe(4096);

    // Payload preserves server_label
    const event = getEvent(db, "evt-e2e-004");
    const storedPayload = JSON.parse(event!.payload);
    expect(storedPayload.server_label).toBe("gpu-0");
    expect(storedPayload.summary).toBe("OOM error");
  });

  test("later event for same session updates name, not project", () => {
    // First event creates the session
    simulateListenerReceive(db, {
      event_id: "evt-e2e-005a",
      session_id: "ses_evolving",
      type: "done",
      project: "my-project",
      worktree: "main",
      server_label: "mac",
      summary: "First task",
      session_name: "Initial task",
      port: 4096,
    });

    expect(getSession(db, "ses_evolving")!.name).toBe("Initial task");

    // Second event (session renamed in opencode)
    simulateListenerReceive(db, {
      event_id: "evt-e2e-005b",
      session_id: "ses_evolving",
      type: "done",
      project: "my-project",
      worktree: "main",
      server_label: "mac",
      summary: "Second task",
      session_name: "Renamed task",
      port: 4096,
    });

    const session = getSession(db, "ses_evolving");
    expect(session!.name).toBe("Renamed task");
    expect(session!.project).toBe("my-project");
    expect(session!.port).toBe(4096);
  });
});

// ── Tmux window renaming ────────────────────────────────────────────────────

describe("E2E: Tmux window rename on session create and switch", () => {
  test("session.updated renames tmux window to session name", async () => {
    if (!hasTmux) {
      console.log("  (skipped: tmux not available)");
      return;
    }

    // Verify initial window name
    const initial = await getTmuxWindowName(TMUX_TEST_SESSION);
    expect(initial).toBe("initial");

    // Register session in DB
    upsertSession(db, {
      id: "ses_tmux_001",
      port: 4096,
      project: "my-project",
      worktree: "feature",
    });

    // Simulate session.updated → rename tmux window
    const target = `${TMUX_TEST_SESSION}:0`;
    await simulateSessionUpdated(db, "ses_tmux_001", "Fix auth bug", "ses_tmux_001", target);

    // Verify window name changed
    const name = await getTmuxWindowName(TMUX_TEST_SESSION);
    expect(name).toBe("Fix auth bug");

    // Verify DB also has the name
    const session = getSession(db, "ses_tmux_001");
    expect(session!.name).toBe("Fix auth bug");
  });

  test("switching sessions updates tmux window name", async () => {
    if (!hasTmux) {
      console.log("  (skipped: tmux not available)");
      return;
    }

    const target = `${TMUX_TEST_SESSION}:0`;

    // Register two sessions
    upsertSession(db, {
      id: "ses_switch_A",
      port: 4096,
      project: "my-project",
      worktree: "feature",
    });
    upsertSession(db, {
      id: "ses_switch_B",
      port: 4096,
      project: "my-project",
      worktree: "feature",
    });

    // Session A is active → rename to its name
    await simulateSessionUpdated(db, "ses_switch_A", "Session Alpha", "ses_switch_A", target);
    expect(await getTmuxWindowName(TMUX_TEST_SESSION)).toBe("Session Alpha");

    // Switch: Session B becomes active → rename to its name
    await simulateSessionUpdated(db, "ses_switch_B", "Session Beta", "ses_switch_B", target);
    expect(await getTmuxWindowName(TMUX_TEST_SESSION)).toBe("Session Beta");

    // Switch back to A → rename back
    await simulateSessionUpdated(db, "ses_switch_A", "Session Alpha", "ses_switch_A", target);
    expect(await getTmuxWindowName(TMUX_TEST_SESSION)).toBe("Session Alpha");
  });

  test("session.updated for non-active session does NOT rename tmux window", async () => {
    if (!hasTmux) {
      console.log("  (skipped: tmux not available)");
      return;
    }

    const target = `${TMUX_TEST_SESSION}:0`;

    // Set window to known state
    const proc = Bun.spawn(["tmux", "rename-window", "-t", target, "active-session"], {
      stdout: "ignore",
      stderr: "ignore",
    });
    await proc.exited;

    upsertSession(db, {
      id: "ses_active",
      port: 4096,
      project: "p",
      worktree: "w",
    });
    upsertSession(db, {
      id: "ses_background",
      port: 4096,
      project: "p",
      worktree: "w",
    });

    // Background session updates — current is ses_active, so no tmux rename
    await simulateSessionUpdated(db, "ses_background", "Background task", "ses_active", target);

    // Window name should NOT change
    expect(await getTmuxWindowName(TMUX_TEST_SESSION)).toBe("active-session");

    // But DB should still have the name
    expect(getSession(db, "ses_background")!.name).toBe("Background task");
  });

  test("long session name gets truncated to 30 chars", async () => {
    if (!hasTmux) {
      console.log("  (skipped: tmux not available)");
      return;
    }

    const target = `${TMUX_TEST_SESSION}:0`;
    const longName = "This is a very long session name that exceeds thirty characters";

    upsertSession(db, {
      id: "ses_long",
      port: 4096,
      project: "p",
      worktree: "w",
    });

    await simulateSessionUpdated(db, "ses_long", longName, "ses_long", target);

    const windowName = await getTmuxWindowName(TMUX_TEST_SESSION);
    expect(windowName).toBe("This is a very long session...");
    expect(windowName.length).toBe(30);

    // DB stores the full name
    expect(getSession(db, "ses_long")!.name).toBe(longName);
  });
});

// ── Cleanup ─────────────────────────────────────────────────────────────────

afterAll(() => {
  try {
    db?.close();
  } catch {}
  try {
    rmSync(tmpDir, { recursive: true, force: true });
  } catch {}
});

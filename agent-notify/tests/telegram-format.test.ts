import { describe, test, expect } from "bun:test";
import { formatNotification, buildKeyboard } from "../src/telegram";

describe("Telegram message formatter", () => {
  const serverLabel = "dev-server";
  const worktree = "feature-auth";
  const prefix = "abcdef12";

  test("done notification includes server label and worktree", () => {
    const { text } = formatNotification(serverLabel, worktree, "done", {
      summary: "Tests passed",
    });
    expect(text).toContain(worktree);
    expect(text).toContain(serverLabel);
    expect(text).toContain("Agent finished");
    expect(text).toContain("Tests passed");
  });

  test("done keyboard has Continue button", () => {
    const keyboard = buildKeyboard("done", prefix, { summary: "ok" });
    expect(keyboard.length).toBe(1);
    expect(keyboard[0][0].text).toBe("Continue");
    expect(keyboard[0][0].callback_data).toContain("k|");
  });

  test("error notification includes error message", () => {
    const { text } = formatNotification(serverLabel, worktree, "error", {
      message: "API key expired",
    });
    expect(text).toContain(serverLabel);
    expect(text).toContain(worktree);
    expect(text).toContain("Agent error");
    expect(text).toContain("API key expired");
  });

  test("error keyboard has Retry and Abort", () => {
    const keyboard = buildKeyboard("error", prefix, {
      message: "fail",
    });
    expect(keyboard.length).toBe(1);
    expect(keyboard[0].length).toBe(2);
    expect(keyboard[0][0].text).toBe("Retry");
    expect(keyboard[0][1].text).toBe("Abort");
  });

  test("question notification includes question text", () => {
    const { text } = formatNotification(serverLabel, worktree, "question", {
      text: "Which database should I use?",
      options: ["PostgreSQL", "MySQL"],
    });
    expect(text).toContain(serverLabel);
    expect(text).toContain(worktree);
    expect(text).toContain("Agent asking");
    expect(text).toContain("Which database should I use?");
  });

  test("question keyboard has option buttons plus Type custom", () => {
    const keyboard = buildKeyboard("question", prefix, {
      text: "Pick one",
      options: ["PostgreSQL", "MySQL", "SQLite"],
    });
    // 3 options + 1 "Type custom" = 4 rows
    expect(keyboard.length).toBe(4);
    expect(keyboard[0][0].text).toBe("PostgreSQL");
    expect(keyboard[1][0].text).toBe("MySQL");
    expect(keyboard[2][0].text).toBe("SQLite");
    expect(keyboard[3][0].text).toBe("Type custom");
  });

  test("permission notification includes tool and action", () => {
    const { text } = formatNotification(serverLabel, worktree, "permission", {
      permissionId: "perm-1",
      tool: "bash",
      action: "rm -rf /tmp/test",
    });
    expect(text).toContain(serverLabel);
    expect(text).toContain(worktree);
    expect(text).toContain("Permission requested");
    expect(text).toContain("bash");
    expect(text).toContain("rm -rf /tmp/test");
  });

  test("permission keyboard has Allow and Deny", () => {
    const keyboard = buildKeyboard("permission", prefix, {
      permissionId: "perm-1",
      tool: "bash",
      action: "rm -rf",
    });
    expect(keyboard.length).toBe(1);
    expect(keyboard[0].length).toBe(2);
    expect(keyboard[0][0].text).toBe("Allow");
    expect(keyboard[0][1].text).toBe("Deny");
  });
});

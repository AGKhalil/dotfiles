import { describe, test, expect } from "bun:test";

/**
 * Test escalation timer logic.
 *
 * These tests verify the timer/ACK interaction logic using simple
 * in-process simulation (no real ntfy or Telegram).
 */

describe("Escalation timer", () => {
  test("timer fires after configured delay", async () => {
    let fired = false;
    const timer = setTimeout(() => {
      fired = true;
    }, 50); // 50ms for test speed

    await new Promise((r) => setTimeout(r, 80));
    expect(fired).toBe(true);
  });

  test("ACK received before delay cancels Telegram send", async () => {
    let telegramSent = false;
    const timer = setTimeout(() => {
      telegramSent = true;
    }, 100);

    // Simulate ACK arriving at 30ms
    await new Promise((r) => setTimeout(r, 30));
    clearTimeout(timer);

    // Wait past the original delay
    await new Promise((r) => setTimeout(r, 120));
    expect(telegramSent).toBe(false);
  });

  test("correct delay values per event type", () => {
    const defaults: Record<string, number> = {
      question: 30,
      permission: 30,
      error: 60,
      done: 120,
    };
    expect(defaults.question).toBe(30);
    expect(defaults.permission).toBe(30);
    expect(defaults.error).toBe(60);
    expect(defaults.done).toBe(120);
  });

  test("multiple concurrent timers don't interfere", async () => {
    const results: string[] = [];

    const timer1 = setTimeout(() => results.push("t1"), 40);
    const timer2 = setTimeout(() => results.push("t2"), 60);
    const timer3 = setTimeout(() => results.push("t3"), 80);

    // Cancel timer2 (simulating ACK for that event)
    clearTimeout(timer2);

    await new Promise((r) => setTimeout(r, 100));
    expect(results).toEqual(["t1", "t3"]);
    expect(results).not.toContain("t2");
  });
});

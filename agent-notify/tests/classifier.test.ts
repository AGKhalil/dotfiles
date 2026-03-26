import { describe, test, expect } from "bun:test";

/**
 * Test event classification logic.
 *
 * The classifier inspects message parts to determine if an idle event
 * is "done" vs "question".  We test the classification logic in isolation
 * by simulating the message part shapes.
 */

// Inline the classification logic (extracted from the plugin for testability)
type ClassifyResult =
  | { type: "done"; summary: string }
  | { type: "question"; text: string; options: string[] };

function classifyParts(parts: any[], title?: string): ClassifyResult {
  for (const part of parts) {
    if (
      part?.type === "tool" &&
      part?.tool === "askquestion" &&
      part?.state === "waiting" &&
      part?.metadata
    ) {
      return {
        type: "question",
        text: part.metadata.question ?? part.metadata.text ?? "",
        options: part.metadata.options ?? [],
      };
    }
  }
  return { type: "done", summary: title ?? "Session completed" };
}

describe("Event classifier", () => {
  test("classifies idle as done when no askquestion part", () => {
    const parts = [
      { type: "text", text: "Here is the answer" },
      { type: "tool", tool: "bash", state: "completed" },
    ];
    const result = classifyParts(parts, "My session");
    expect(result.type).toBe("done");
    expect((result as any).summary).toBe("My session");
  });

  test("classifies idle as done with empty parts", () => {
    const result = classifyParts([]);
    expect(result.type).toBe("done");
  });

  test("classifies idle as question when askquestion in waiting state", () => {
    const parts = [
      { type: "text", text: "I have a question" },
      {
        type: "tool",
        tool: "askquestion",
        state: "waiting",
        metadata: {
          question: "Which database?",
          options: ["PostgreSQL", "MySQL", "SQLite"],
        },
      },
    ];
    const result = classifyParts(parts);
    expect(result.type).toBe("question");
    if (result.type === "question") {
      expect(result.text).toBe("Which database?");
      expect(result.options).toEqual(["PostgreSQL", "MySQL", "SQLite"]);
    }
  });

  test("ignores askquestion in completed state", () => {
    const parts = [
      {
        type: "tool",
        tool: "askquestion",
        state: "completed",
        metadata: {
          question: "Old question",
          options: ["A", "B"],
        },
      },
    ];
    const result = classifyParts(parts);
    expect(result.type).toBe("done");
  });

  test("extracts question with fallback text field", () => {
    const parts = [
      {
        type: "tool",
        tool: "askquestion",
        state: "waiting",
        metadata: {
          text: "Fallback question text",
          options: ["Yes", "No"],
        },
      },
    ];
    const result = classifyParts(parts);
    expect(result.type).toBe("question");
    if (result.type === "question") {
      expect(result.text).toBe("Fallback question text");
    }
  });

  test("handles askquestion with no options", () => {
    const parts = [
      {
        type: "tool",
        tool: "askquestion",
        state: "waiting",
        metadata: {
          question: "Free text question",
        },
      },
    ];
    const result = classifyParts(parts);
    expect(result.type).toBe("question");
    if (result.type === "question") {
      expect(result.options).toEqual([]);
    }
  });
});

import { describe, test, expect } from "bun:test";
import {
  encodeResponseCallback,
  encodePermissionCallback,
  encodeCustomCallback,
  encodeContinueCallback,
  decodeCallback,
} from "../src/telegram";

describe("Callback data encoding/decoding", () => {
  test("encode response callback", () => {
    const data = encodeResponseCallback("abcdef12", 2);
    expect(data).toBe("r|abcdef12|2");
  });

  test("decode response callback", () => {
    const decoded = decodeCallback("r|abcdef12|2");
    expect(decoded).toEqual({
      kind: "response",
      sessionPrefix: "abcdef12",
      optionIndex: 2,
    });
  });

  test("encode permission allow callback", () => {
    const data = encodePermissionCallback("abcdef12", true);
    expect(data).toBe("p|abcdef12|a");
  });

  test("encode permission deny callback", () => {
    const data = encodePermissionCallback("abcdef12", false);
    expect(data).toBe("p|abcdef12|d");
  });

  test("decode permission allow", () => {
    const decoded = decodeCallback("p|abcdef12|a");
    expect(decoded).toEqual({
      kind: "permission",
      sessionPrefix: "abcdef12",
      allow: true,
    });
  });

  test("decode permission deny", () => {
    const decoded = decodeCallback("p|abcdef12|d");
    expect(decoded).toEqual({
      kind: "permission",
      sessionPrefix: "abcdef12",
      allow: false,
    });
  });

  test("encode/decode custom callback", () => {
    const data = encodeCustomCallback("abcdef12");
    expect(data).toBe("c|abcdef12");
    const decoded = decodeCallback(data);
    expect(decoded).toEqual({
      kind: "custom",
      sessionPrefix: "abcdef12",
    });
  });

  test("encode/decode continue callback", () => {
    const data = encodeContinueCallback("abcdef12");
    expect(data).toBe("k|abcdef12");
    const decoded = decodeCallback(data);
    expect(decoded).toEqual({
      kind: "continue",
      sessionPrefix: "abcdef12",
    });
  });

  test("all formats fit within 64 bytes", () => {
    const prefix = "abcdef12";
    const enc = new TextEncoder();

    // Response with large index
    const r = encodeResponseCallback(prefix, 99999);
    expect(enc.encode(r).length).toBeLessThanOrEqual(64);

    // Permission
    const pAllow = encodePermissionCallback(prefix, true);
    expect(enc.encode(pAllow).length).toBeLessThanOrEqual(64);

    const pDeny = encodePermissionCallback(prefix, false);
    expect(enc.encode(pDeny).length).toBeLessThanOrEqual(64);

    // Custom
    const c = encodeCustomCallback(prefix);
    expect(enc.encode(c).length).toBeLessThanOrEqual(64);

    // Continue
    const k = encodeContinueCallback(prefix);
    expect(enc.encode(k).length).toBeLessThanOrEqual(64);
  });

  test("truncates session prefix to 8 chars", () => {
    const data = encodeResponseCallback(
      "abcdef1234567890-extra-long-prefix",
      0
    );
    expect(data).toBe("r|abcdef12|0");
  });

  test("decode returns null for invalid data", () => {
    expect(decodeCallback("")).toBeNull();
    expect(decodeCallback("x")).toBeNull();
    expect(decodeCallback("z|abc|1")).toBeNull();
  });

  test("boundary session IDs", () => {
    // All zeros
    const d1 = encodeResponseCallback("00000000", 0);
    expect(decodeCallback(d1)).toEqual({
      kind: "response",
      sessionPrefix: "00000000",
      optionIndex: 0,
    });

    // All f's
    const d2 = encodeResponseCallback("ffffffff", 255);
    expect(decodeCallback(d2)).toEqual({
      kind: "response",
      sessionPrefix: "ffffffff",
      optionIndex: 255,
    });
  });
});

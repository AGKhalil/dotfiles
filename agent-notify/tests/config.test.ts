import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { loadConfig } from "../src/config";

let tmpDir: string;

beforeEach(() => {
  tmpDir = mkdtempSync(join(tmpdir(), "an-config-test-"));
});

afterEach(() => {
  rmSync(tmpDir, { recursive: true, force: true });
});

function writeConfig(content: string): string {
  const path = join(tmpDir, "config.toml");
  writeFileSync(path, content);
  return path;
}

function writeSecrets(content: string): string {
  const path = join(tmpDir, "secrets");
  writeFileSync(path, content);
  return path;
}

describe("Config loader", () => {
  test("parse valid config.toml with inline values", () => {
    const configPath = writeConfig(`
role = "main"
server_label = "my-mac"

[telegram]
bot_token = "123:ABC"
chat_id = "456789"

[ntfy]
events_topic = "my-events"
ack_topic = "my-ack"

[delays]
question = 15
done = 60
`);
    const secretsPath = join(tmpDir, "secrets");
    writeFileSync(secretsPath, "");

    const config = loadConfig(configPath, secretsPath);
    expect(config.role).toBe("main");
    expect(config.server_label).toBe("my-mac");
    expect(config.telegram.bot_token).toBe("123:ABC");
    expect(config.telegram.chat_id).toBe("456789");
    expect(config.ntfy.events_topic).toBe("my-events");
    expect(config.ntfy.ack_topic).toBe("my-ack");
    expect(config.delays.question).toBe(15);
    expect(config.delays.done).toBe(60);
    expect(config.delays.error).toBe(60); // default
    expect(config.delays.permission).toBe(30); // default
  });

  test("resolve env: references from secrets file", () => {
    const configPath = writeConfig(`
role = "server"

[telegram]
bot_token = "env:MY_BOT_TOKEN"
chat_id = "env:MY_CHAT_ID"

[ntfy]
events_topic = "env:MY_EVENTS"
ack_topic = "env:MY_ACK"
`);
    const secretsPath = writeSecrets(`
MY_BOT_TOKEN=token123
MY_CHAT_ID=chat456
MY_EVENTS=events-topic
MY_ACK=ack-topic
`);

    const config = loadConfig(configPath, secretsPath);
    expect(config.telegram.bot_token).toBe("token123");
    expect(config.telegram.chat_id).toBe("chat456");
    expect(config.ntfy.events_topic).toBe("events-topic");
    expect(config.ntfy.ack_topic).toBe("ack-topic");
  });

  test("reject missing required fields", () => {
    const configPath = writeConfig(`
role = "server"

[telegram]
bot_token = ""
chat_id = ""

[ntfy]
events_topic = "topic"
ack_topic = "ack"
`);
    const secretsPath = writeSecrets("");

    expect(() => loadConfig(configPath, secretsPath)).toThrow(
      "telegram.bot_token is required"
    );
  });

  test("throw on missing config file", () => {
    expect(() => loadConfig("/nonexistent/config.toml", "/nonexistent/secrets")).toThrow(
      "Config file not found"
    );
  });

  test("handle missing secrets file gracefully", () => {
    // Config with inline values (no env: refs) should work without secrets
    const configPath = writeConfig(`
role = "server"

[telegram]
bot_token = "inline-token"
chat_id = "inline-id"

[ntfy]
events_topic = "my-events"
ack_topic = "my-ack"
`);

    const config = loadConfig(configPath, "/nonexistent/secrets");
    expect(config.telegram.bot_token).toBe("inline-token");
  });

  test("default delay values when not specified", () => {
    const configPath = writeConfig(`
role = "server"

[telegram]
bot_token = "token"
chat_id = "id"

[ntfy]
events_topic = "events"
ack_topic = "ack"
`);
    const secretsPath = writeSecrets("");

    const config = loadConfig(configPath, secretsPath);
    expect(config.delays.question).toBe(30);
    expect(config.delays.permission).toBe(30);
    expect(config.delays.error).toBe(60);
    expect(config.delays.done).toBe(120);
  });

  test("default server_label to hostname", () => {
    const configPath = writeConfig(`
role = "server"

[telegram]
bot_token = "token"
chat_id = "id"

[ntfy]
events_topic = "events"
ack_topic = "ack"
`);
    const secretsPath = writeSecrets("");

    const config = loadConfig(configPath, secretsPath);
    expect(config.server_label).toBeTruthy();
    expect(typeof config.server_label).toBe("string");
  });
});

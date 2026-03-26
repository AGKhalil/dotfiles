import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import type { AppConfig, DelayConfig } from "./types";

const CONFIG_DIR =
  process.env.AGENT_NOTIFY_CONFIG_DIR ??
  resolve(import.meta.dir, "..");

const CONFIG_PATH = resolve(CONFIG_DIR, "config.toml");

const SECRETS_PATH =
  process.env.AGENT_NOTIFY_SECRETS ??
  `${process.env.HOME}/.config/agent-notify/secrets`;

const DEFAULT_DELAYS: DelayConfig = {
  question: 30,
  permission: 30,
  error: 60,
  done: 120,
};

// ── TOML parser (minimal, sufficient for our flat config) ───────────────────

function parseTOML(text: string): Record<string, Record<string, string>> {
  const result: Record<string, Record<string, string>> = { "": {} };
  let section = "";

  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;

    const sectionMatch = line.match(/^\[(.+)\]$/);
    if (sectionMatch) {
      section = sectionMatch[1];
      result[section] ??= {};
      continue;
    }

    const kvMatch = line.match(/^(\w+)\s*=\s*"?([^"]*)"?$/);
    if (kvMatch) {
      result[section] ??= {};
      result[section][kvMatch[1]] = kvMatch[2];
    }
  }
  return result;
}

// ── Secrets resolver ────────────────────────────────────────────────────────

function loadSecrets(path: string): Record<string, string> {
  if (!existsSync(path)) return {};
  const text = readFileSync(path, "utf-8");
  const secrets: Record<string, string> = {};
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eqIdx = line.indexOf("=");
    if (eqIdx === -1) continue;
    secrets[line.slice(0, eqIdx).trim()] = line.slice(eqIdx + 1).trim();
  }
  return secrets;
}

function resolveValue(
  val: string | undefined,
  secrets: Record<string, string>
): string {
  if (!val) return "";
  if (val.startsWith("env:")) {
    const key = val.slice(4);
    const resolved = secrets[key] ?? process.env[key];
    if (!resolved) {
      throw new Error(`Could not resolve env reference: ${val}`);
    }
    return resolved;
  }
  return val;
}

// ── Public API ──────────────────────────────────────────────────────────────

export function loadConfig(
  configPath: string = CONFIG_PATH,
  secretsPath: string = SECRETS_PATH
): AppConfig {
  if (!existsSync(configPath)) {
    throw new Error(`Config file not found: ${configPath}`);
  }

  const text = readFileSync(configPath, "utf-8");
  const toml = parseTOML(text);
  const secrets = loadSecrets(secretsPath);

  const role = (toml[""]?.role ?? "server") as "main" | "server";
  const serverLabel = toml[""]?.server_label ?? require("os").hostname();

  const tg = toml["telegram"] ?? {};
  const botToken = resolveValue(tg.bot_token, secrets);
  const chatId = resolveValue(tg.chat_id, secrets);

  if (!botToken) throw new Error("telegram.bot_token is required");
  if (!chatId) throw new Error("telegram.chat_id is required");

  const ntfySec = toml["ntfy"] ?? {};
  const eventsTopic = resolveValue(ntfySec.events_topic, secrets);
  const ackTopic = resolveValue(ntfySec.ack_topic, secrets);
  const ntfyServer = ntfySec.server ?? "https://ntfy.sh";

  if (!eventsTopic) throw new Error("ntfy.events_topic is required");
  if (!ackTopic) throw new Error("ntfy.ack_topic is required");

  const delaySec = toml["delays"] ?? {};
  const delays: DelayConfig = {
    question: Number(delaySec.question) || DEFAULT_DELAYS.question,
    permission: Number(delaySec.permission) || DEFAULT_DELAYS.permission,
    error: Number(delaySec.error) || DEFAULT_DELAYS.error,
    done: Number(delaySec.done) || DEFAULT_DELAYS.done,
  };

  return {
    role,
    server_label: serverLabel,
    telegram: { bot_token: botToken, chat_id: chatId },
    ntfy: {
      events_topic: eventsTopic,
      ack_topic: ackTopic,
      server: ntfyServer,
    },
    delays,
  };
}

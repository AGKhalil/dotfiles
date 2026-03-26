/**
 * Mock Telegram server for integration tests.
 *
 * Implements: sendMessage, editMessageText, getUpdates, answerCallbackQuery.
 * Exposes helpers for inspecting state and simulating button taps.
 */

interface StoredMessage {
  message_id: number;
  chat_id: string;
  text: string;
  reply_markup?: any;
}

interface QueuedUpdate {
  update_id: number;
  callback_query?: {
    id: string;
    data: string;
    message: { message_id: number; chat: { id: number } };
    from: { id: number };
  };
  message?: {
    message_id: number;
    text: string;
    chat: { id: number };
    reply_to_message?: { message_id: number };
  };
}

export class MockTelegramServer {
  private messages: StoredMessage[] = [];
  private updates: QueuedUpdate[] = [];
  private nextMsgId = 1;
  private nextUpdateId = 100;
  private nextCallbackId = 1;
  private answeredCallbacks: string[] = [];
  private server: ReturnType<typeof Bun.serve> | null = null;
  public port = 0;

  async start(): Promise<void> {
    this.server = Bun.serve({
      port: 0,
      fetch: async (req) => {
        const url = new URL(req.url);
        const path = url.pathname;

        // Extract method from /bot<token>/<method>
        const match = path.match(/\/bot[^/]+\/(\w+)$/);
        if (!match) {
          return Response.json({ ok: false, description: "Unknown path" });
        }

        const method = match[1];
        const body = req.method === "POST" ? await req.json() : {};

        switch (method) {
          case "sendMessage":
            return this.handleSendMessage(body);
          case "editMessageText":
            return this.handleEditMessageText(body);
          case "getUpdates":
            return this.handleGetUpdates(body);
          case "answerCallbackQuery":
            return this.handleAnswerCallbackQuery(body);
          case "getMe":
            return Response.json({
              ok: true,
              result: { id: 12345, username: "test_bot" },
            });
          default:
            return Response.json({
              ok: false,
              description: `Unknown method: ${method}`,
            });
        }
      },
    });
    this.port = this.server.port;
  }

  stop(): void {
    this.server?.stop();
  }

  // ── Handlers ────────────────────────────────────────────────────────────

  private handleSendMessage(body: any): Response {
    const msg: StoredMessage = {
      message_id: this.nextMsgId++,
      chat_id: String(body.chat_id),
      text: body.text,
      reply_markup: body.reply_markup,
    };
    this.messages.push(msg);
    return Response.json({
      ok: true,
      result: {
        message_id: msg.message_id,
        chat: { id: Number(body.chat_id) },
        text: body.text,
      },
    });
  }

  private handleEditMessageText(body: any): Response {
    const existing = this.messages.find(
      (m) => m.message_id === body.message_id
    );
    if (existing) {
      existing.text = body.text;
      existing.reply_markup = body.reply_markup;
    }
    return Response.json({
      ok: true,
      result: {
        message_id: body.message_id,
        chat: { id: Number(body.chat_id) },
        text: body.text,
      },
    });
  }

  private handleGetUpdates(body: any): Response {
    const offset = body.offset;
    const filtered = offset
      ? this.updates.filter((u) => u.update_id >= offset)
      : this.updates;

    // Don't long-poll in tests — return immediately
    return Response.json({ ok: true, result: filtered });
  }

  private handleAnswerCallbackQuery(body: any): Response {
    this.answeredCallbacks.push(body.callback_query_id);
    return Response.json({ ok: true, result: true });
  }

  // ── Test helpers ────────────────────────────────────────────────────────

  getMessages(): StoredMessage[] {
    return [...this.messages];
  }

  getMessage(id: number): StoredMessage | undefined {
    return this.messages.find((m) => m.message_id === id);
  }

  getAnsweredCallbacks(): string[] {
    return [...this.answeredCallbacks];
  }

  simulateButtonTap(msgId: number, callbackData: string): void {
    const cbId = `cb_${this.nextCallbackId++}`;
    this.updates.push({
      update_id: this.nextUpdateId++,
      callback_query: {
        id: cbId,
        data: callbackData,
        message: { message_id: msgId, chat: { id: 123 } },
        from: { id: 999 },
      },
    });
  }

  simulateTextReply(text: string, replyToMsgId: number): void {
    this.updates.push({
      update_id: this.nextUpdateId++,
      message: {
        message_id: this.nextMsgId++,
        text,
        chat: { id: 123 },
        reply_to_message: { message_id: replyToMsgId },
      },
    });
  }

  clearUpdates(): void {
    this.updates = [];
  }

  reset(): void {
    this.messages = [];
    this.updates = [];
    this.answeredCallbacks = [];
    this.nextMsgId = 1;
    this.nextUpdateId = 100;
    this.nextCallbackId = 1;
  }
}

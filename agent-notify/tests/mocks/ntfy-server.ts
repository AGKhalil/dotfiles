/**
 * Mock ntfy server for integration tests.
 *
 * Implements POST /topic (stores messages) and GET /topic/sse (SSE stream).
 * Exposes helpers for inspecting received events.
 */

export class MockNtfyServer {
  private topicMessages: Map<string, any[]> = new Map();
  private sseControllers: Map<string, ReadableStreamDefaultController[]> = new Map();
  private server: ReturnType<typeof Bun.serve> | null = null;
  public port = 0;

  async start(): Promise<void> {
    this.server = Bun.serve({
      port: 0,
      fetch: async (req) => {
        const url = new URL(req.url);
        const parts = url.pathname.split("/").filter(Boolean);

        if (parts.length === 0) {
          return new Response("Mock ntfy server", { status: 200 });
        }

        const topic = parts[0];

        // POST /<topic> — store message
        if (req.method === "POST") {
          const body = await req.text();
          let parsed: any;
          try {
            parsed = JSON.parse(body);
          } catch {
            parsed = { message: body };
          }

          const msgs = this.topicMessages.get(topic) ?? [];
          msgs.push(parsed);
          this.topicMessages.set(topic, msgs);

          // Broadcast to SSE subscribers
          const controllers = this.sseControllers.get(topic) ?? [];
          const sseData = `data: ${JSON.stringify({ event: "message", message: body })}\n\n`;
          for (const ctrl of controllers) {
            try {
              ctrl.enqueue(new TextEncoder().encode(sseData));
            } catch {
              // controller may be closed
            }
          }

          return Response.json({ ok: true });
        }

        // GET /<topic>/sse — SSE stream
        if (req.method === "GET" && parts[1] === "sse") {
          const stream = new ReadableStream({
            start: (controller) => {
              const controllers = this.sseControllers.get(topic) ?? [];
              controllers.push(controller);
              this.sseControllers.set(topic, controllers);

              // Send keepalive
              controller.enqueue(
                new TextEncoder().encode(": keepalive\n\n")
              );
            },
            cancel: () => {
              // Clean up controller
            },
          });

          return new Response(stream, {
            headers: {
              "Content-Type": "text/event-stream",
              "Cache-Control": "no-cache",
              Connection: "keep-alive",
            },
          });
        }

        return new Response("Not found", { status: 404 });
      },
    });
    this.port = this.server.port;
  }

  stop(): void {
    // Close all SSE connections
    for (const controllers of this.sseControllers.values()) {
      for (const ctrl of controllers) {
        try {
          ctrl.close();
        } catch {
          // already closed
        }
      }
    }
    this.server?.stop();
  }

  // ── Test helpers ────────────────────────────────────────────────────────

  getMessages(topic: string): any[] {
    return [...(this.topicMessages.get(topic) ?? [])];
  }

  reset(): void {
    this.topicMessages.clear();
  }
}

/**
 * Mock OpenCode server for integration tests.
 *
 * Implements POST /session/:id/message (records prompts) and
 * POST /session/:id/permissions/:permId (records permission responses).
 */

interface RecordedPrompt {
  sessionId: string;
  parts: any[];
}

interface RecordedPermission {
  sessionId: string;
  permissionId: string;
  response: string;
}

export class MockOpenCodeServer {
  private prompts: RecordedPrompt[] = [];
  private permissions: RecordedPermission[] = [];
  private server: ReturnType<typeof Bun.serve> | null = null;
  public port = 0;

  async start(): Promise<void> {
    this.server = Bun.serve({
      port: 0,
      fetch: async (req) => {
        const url = new URL(req.url);
        const path = url.pathname;

        // POST /session/:id/message
        const promptMatch = path.match(
          /^\/session\/([^/]+)\/message$/
        );
        if (promptMatch && req.method === "POST") {
          const body = await req.json();
          this.prompts.push({
            sessionId: promptMatch[1],
            parts: body.parts ?? [],
          });
          return Response.json({
            info: { id: "msg-1" },
            parts: [{ type: "text", text: "ok" }],
          });
        }

        // POST /session/:id/permissions/:permId
        const permMatch = path.match(
          /^\/session\/([^/]+)\/permissions\/([^/]+)$/
        );
        if (permMatch && req.method === "POST") {
          const body = await req.json();
          this.permissions.push({
            sessionId: permMatch[1],
            permissionId: permMatch[2],
            response: body.response,
          });
          return Response.json(true);
        }

        // Health check
        if (path === "/global/health") {
          return Response.json({ healthy: true, version: "test" });
        }

        return new Response("Not found", { status: 404 });
      },
    });
    this.port = this.server.port;
  }

  stop(): void {
    this.server?.stop();
  }

  // ── Test helpers ────────────────────────────────────────────────────────

  getReceivedPrompts(sessionId?: string): RecordedPrompt[] {
    if (sessionId) {
      return this.prompts.filter((p) => p.sessionId === sessionId);
    }
    return [...this.prompts];
  }

  getReceivedPermissions(sessionId?: string): RecordedPermission[] {
    if (sessionId) {
      return this.permissions.filter((p) => p.sessionId === sessionId);
    }
    return [...this.permissions];
  }

  reset(): void {
    this.prompts = [];
    this.permissions = [];
  }
}

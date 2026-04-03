import { describe, expect, it, vi } from "vitest";

import { createApp } from "../src/app";
import { createExecutionService, createNotifyRequest, createQuoteService, createSolverQuoteRequest } from "./support";

describe("RFQ filler app", () => {
  const backendSecret = "test-backend-secret";

  it("serves OpenAPI and docs routes", async () => {
    const app = createApp({
      quoteService: createQuoteService(),
      executionService: createExecutionService(),
      backendSharedSecret: backendSecret,
    });

    const [specResponse, docsResponse] = await Promise.all([app.request("/openapi.json"), app.request("/docs")]);
    const spec = (await specResponse.json()) as {
      readonly openapi: string;
      readonly info: { readonly title: string };
      readonly paths: Record<string, unknown>;
    };
    const docsHtml = await docsResponse.text();

    expect(specResponse.status).toBe(200);
    expect(spec.openapi).toBe("3.1.0");
    expect(spec.info.title).toBe("Symbiotic RFQ Filler API");
    expect(spec.paths).toMatchObject({
      "/health": expect.any(Object),
      "/quote": expect.any(Object),
      "/notify": expect.any(Object),
    });

    expect(docsResponse.status).toBe(200);
    expect(docsHtml).toContain("/openapi.json");
  });

  it("validates quote and notify payloads", async () => {
    const app = createApp({
      quoteService: createQuoteService(),
      executionService: createExecutionService(),
      backendSharedSecret: backendSecret,
    });

    const [quoteResponse, notifyResponse] = await Promise.all([
      app.request("/quote", {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-rfq-shared-secret": backendSecret },
        body: JSON.stringify({ requestId: "bad" }),
      }),
      app.request("/notify", {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-rfq-shared-secret": backendSecret },
        body: JSON.stringify({ orderHash: "bad" }),
      }),
    ]);

    expect(quoteResponse.status).toBe(400);
    expect(notifyResponse.status).toBe(400);
  });

  it("returns 204 when no quote is available and 202 for notify", async () => {
    const quoteService = {
      quote: vi.fn(async () => null),
    } as unknown as ReturnType<typeof createQuoteService>;
    const executionService = {
      enqueueFromNotify: vi.fn(async () => undefined),
    } as unknown as ReturnType<typeof createExecutionService>;
    const app = createApp({
      quoteService,
      executionService,
      backendSharedSecret: backendSecret,
    });

    const quoteResponse = await app.request("/quote", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-rfq-shared-secret": backendSecret },
      body: JSON.stringify(createSolverQuoteRequest()),
    });
    const notifyResponse = await app.request("/notify", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-rfq-shared-secret": backendSecret },
      body: JSON.stringify(createNotifyRequest()),
    });

    expect(quoteResponse.status).toBe(204);
    expect(notifyResponse.status).toBe(202);
    expect(await notifyResponse.json()).toEqual({ status: "queued" });
  });

  it("rejects /quote requests without amount", async () => {
    const quoteService = {
      quote: vi.fn(async () => null),
    } as unknown as ReturnType<typeof createQuoteService>;
    const app = createApp({
      quoteService,
      executionService: createExecutionService(),
      backendSharedSecret: backendSecret,
    });

    const response = await app.request("/quote", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-rfq-shared-secret": backendSecret },
      body: JSON.stringify({
        ...createSolverQuoteRequest(),
        amount: undefined,
      }),
    });

    expect(response.status).toBe(400);
    expect(quoteService.quote).not.toHaveBeenCalled();
  });

  it("rejects quote and notify requests from non-backend callers", async () => {
    const app = createApp({
      quoteService: createQuoteService(),
      executionService: createExecutionService(),
      backendSharedSecret: backendSecret,
    });

    const [quoteResponse, notifyResponse] = await Promise.all([
      app.request("/quote", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(createSolverQuoteRequest()),
      }),
      app.request("/notify", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(createNotifyRequest()),
      }),
    ]);

    expect(quoteResponse.status).toBe(403);
    expect(notifyResponse.status).toBe(403);
  });
});

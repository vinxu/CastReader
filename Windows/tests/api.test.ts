import { describe, expect, it, vi } from "vitest";
import { AccountService, synthesize } from "../src/core/api";
import type { Session, Vault, Fetcher } from "../src/core/api";
const ok = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
const session: Session = {
  account: {
    id: "account-a",
    email: "a@example.com",
    displayName: "A",
    region: "global",
  },
  token: "cms_a",
  identityToken: "identity-a",
};
function vault(initial: Session | null = null) {
  let saved = initial;
  return {
    read: () => saved,
    write: vi.fn((value: Session | null) => {
      saved = value;
    }),
  } satisfies Vault;
}
describe("account boundaries", () => {
  it("does not persist an identity with a different canonical mobile session subject", async () => {
    const store = vault(),
      fetcher = vi
        .fn<Fetcher>()
        .mockResolvedValueOnce(
          ok({ user: { id: "account-a" }, token: "identity-a" }),
        )
        .mockResolvedValueOnce(
          ok({ data: { token: "cms_b", userId: "account-b" } }),
        );
    const service = new AccountService(fetcher, store, "device", "0.1.0");
    await expect(
      service.signIn("a@example.com", "123456", "global"),
    ).rejects.toThrow("INVALID_SESSION");
    expect(store.read()).toBeNull();
    expect(service.account).toBeNull();
  });
  it("drops a late sign-in after sign-out", async () => {
    let resolve!: (value: Response) => void;
    const fetcher = vi.fn<Fetcher>().mockImplementationOnce(
      () =>
        new Promise((r) => {
          resolve = r;
        }),
    );
    const store = vault(),
      service = new AccountService(fetcher, store, "device", "0.1.0");
    const request = service.signIn("a@example.com", "123456", "global");
    await service.signOut();
    resolve(ok({ user: { id: "account-a" }, token: "identity-a" }));
    await expect(request).rejects.toThrow("ACCOUNT_CHANGED");
    expect(store.read()).toBeNull();
  });
  it("does not restore a revoked account through a late refresh", async () => {
    let resolve!: (value: Response) => void;
    const fetcher = vi
      .fn<Fetcher>()
      .mockResolvedValueOnce(ok({}, 401))
      .mockImplementationOnce(
        () =>
          new Promise((r) => {
            resolve = r;
          }),
      )
      .mockResolvedValueOnce(ok({}));
    const store = vault(session),
      service = new AccountService(fetcher, store, "device", "0.1.0");
    const request = service.status();
    await vi.waitFor(() => expect(fetcher).toHaveBeenCalledTimes(2));
    await service.signOut();
    resolve(ok({ data: { token: "cms_refreshed", userId: "account-a" } }));
    await expect(request).rejects.toThrow("ACCOUNT_CHANGED");
    expect(store.read()).toBeNull();
  });
  it("uses only the authenticated v2 entitlement contract, accepting the latest false", async () => {
    const fetcher = vi
      .fn<Fetcher>()
      .mockResolvedValueOnce(ok({ pro: true, resolvedUserId: "account-a" }))
      .mockResolvedValueOnce(
        ok({
          data: {
            pro: false,
            resolvedUserId: "account-a",
            listenRemaining: 30,
          },
        }),
      );
    const service = new AccountService(
      fetcher,
      vault(session),
      "device",
      "0.1.0",
    );
    expect((await service.status()).pro).toBe(true);
    expect((await service.status()).pro).toBe(false);
    for (const [url, init] of fetcher.mock.calls) {
      expect(url).toContain("/api/mobile/pro/status/v2?");
      expect(url).not.toContain("user_id");
      expect(url).not.toContain("email=");
      expect(init.credentials).toBe("omit");
      expect(init.headers).toMatchObject({
        Authorization: "Bearer cms_a",
        "X-Auth-Provider": "session",
      });
    }
  });
});
describe("preset synthesis retry contract", () => {
  const input = {
    text: "Hello.",
    voice: "af_heart",
    language: "en",
    region: "global" as const,
    requestId: "request",
  };
  it("does not retry a timeout or an arbitrary 503 that may have synthesized audio", async () => {
    for (const failure of [
      new Error("timeout"),
      new Response("{}", { status: 503 }),
    ]) {
      const fetcher = vi.fn<Fetcher>();
      if (failure instanceof Error) fetcher.mockRejectedValue(failure);
      else fetcher.mockResolvedValue(failure);
      await expect(
        synthesize(fetcher, input, new AbortController().signal),
      ).rejects.toThrow();
      expect(fetcher).toHaveBeenCalledTimes(1);
    }
  });
  it("only falls back on an explicit zero-attempt busy response and retains the request ID", async () => {
    const fetcher = vi
      .fn<Fetcher>()
      .mockResolvedValueOnce(
        new Response("{}", {
          status: 503,
          headers: {
            "x-castreader-tts-contract": "preset-gateway-v1",
            "x-castreader-tts-attempts": "0",
            "x-tts-error-code": "TTS_GATEWAY_BUSY",
            "x-voice-retryable": "true",
          },
        }),
      )
      .mockResolvedValueOnce(
        ok({ audio: "YQ==", processed_text: "Hello.", unprocessed_text: "" }),
      );
    await synthesize(fetcher, input, new AbortController().signal);
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(fetcher.mock.calls[1]![0]).toContain("https://api.castreader.ai/");
    expect(fetcher.mock.calls[0]![1]).toBe(fetcher.mock.calls[1]![1]);
  });
});

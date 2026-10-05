import { expect, test } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    // Explicit in-memory bridge fixture; never bundled into the product.
    let documents: any[] = [];
    let prefs = {
      theme: "light",
      fontSize: 21,
      speed: 1,
      voice: "af_heart",
      language: "en",
      locale: "en",
    };
    let checkpoints: Record<string, unknown> = {};
    let account: any = {
      id: "fixture-account",
      email: "fixture@example.test",
      displayName: "Reader",
      region: "global",
    };
    (window as any).castreader = {
      bootstrap: async () => ({
        account,
        preferences: prefs,
        documents,
        checkpoints,
        platform: "browser-fixture",
        version: "0.1.0-test",
      }),
      entitlement: async () => ({ pro: false, listenRemaining: 1200 }),
      sendCode: async () => {},
      signIn: async () => account,
      signOut: async () => {
        account = null;
        documents = [];
        checkpoints = {};
      },
      importFile: async () => ({
        name: "Imported note.txt",
        extension: "txt",
        bytes: new TextEncoder().encode("A document from the file picker."),
      }),
      saveDocument: async (d: any) => {
        documents = [d, ...documents.filter((x) => x.id !== d.id)];
      },
      deleteDocument: async (id: string) => {
        documents = documents.filter((d) => d.id !== id);
      },
      savePreferences: async (p: any) => {
        prefs = p;
      },
      saveCheckpoint: async (c: any) => {
        checkpoints[c.documentId] = c;
      },
      cancelSpeech: async () => {},
      track: async () => {},
      speak: async (input: any) => {
        const rate = 8000,
          samples = rate * 5,
          buffer = new ArrayBuffer(44 + samples * 2),
          v = new DataView(buffer);
        const str = (offset: number, s: string) =>
          [...s].forEach((c, i) => v.setUint8(offset + i, c.charCodeAt(0)));
        str(0, "RIFF");
        v.setUint32(4, 36 + samples * 2, true);
        str(8, "WAVE");
        str(12, "fmt ");
        v.setUint32(16, 16, true);
        v.setUint16(20, 1, true);
        v.setUint16(22, 1, true);
        v.setUint32(24, rate, true);
        v.setUint32(28, rate * 2, true);
        v.setUint16(32, 2, true);
        v.setUint16(34, 16, true);
        str(36, "data");
        v.setUint32(40, samples * 2, true);
        let binary = "";
        for (const b of new Uint8Array(buffer))
          binary += String.fromCharCode(b);
        return {
          audio: btoa(binary),
          audioFormat: "wav",
          timestamps: [],
          duration: 5,
          processed: input.text,
          remaining: "",
        };
      },
    };
  });
});
test("paste, play, pause and restore preserve full source paragraphs", async ({
  page,
}) => {
  await page.goto("/");
  await page.getByRole("button", { name: "Paste text", exact: false }).click();
  await page.getByLabel("Title", { exact: true }).fill("Focus and attention");
  const text =
    "One repeated word, one repeated word. The entire paragraph stays visible.\n\nA second paragraph remains visible before its audio is ready.";
  await page.getByLabel("Text", { exact: true }).fill(text);
  await page.getByRole("button", { name: "Add to library" }).click();
  await expect(
    page.getByRole("heading", { name: "Focus and attention" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Read aloud", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Pause", exact: true }),
  ).toBeVisible();
  await expect(page.locator(".reading-paragraph").first()).toContainText(
    text.split("\n\n")[0]!,
  );
  await expect(page.locator(".reading-paragraph").nth(1)).toContainText(
    "A second paragraph remains visible",
  );
  await page.getByRole("button", { name: "Pause", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Resume", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Back to library" }).click();
  await page.getByRole("button", { name: /^Focus and attention/ }).click();
  await expect(
    page.getByRole("button", { name: "Read aloud", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("Listening will resume from your saved position."),
  ).toBeVisible();
});
test("file import, settings and account boundary work at the minimum window size", async ({
  page,
}) => {
  await page.setViewportSize({ width: 800, height: 600 });
  await page.goto("/");
  await page.getByRole("button", { name: "Open a file", exact: false }).click();
  await expect(
    page.getByRole("heading", { name: "Imported note.txt" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await page
    .getByRole("combobox", { name: "Theme", exact: true })
    .selectOption("dark");
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await page
    .getByRole("combobox", { name: "Display language", exact: true })
    .selectOption("zh-Hans");
  await expect(
    page.getByRole("heading", { name: "设置", exact: true }),
  ).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page
    .getByRole("button", { name: "退出登录", exact: true })
    .last()
    .click();
  await expect(
    page.getByRole("heading", { name: "登录", exact: true }),
  ).toBeVisible();
  await expect(page.getByText("Imported note.txt")).toHaveCount(0);
});
test("pasted markup remains inert text", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("button", { name: "Paste text", exact: false }).click();
  await page.getByLabel("Title", { exact: true }).fill("Untrusted content");
  await page
    .getByLabel("Text", { exact: true })
    .fill(
      '<img src=x onerror="window.compromised=true"><script>window.compromised=true</script>',
    );
  await page.getByRole("button", { name: "Add to library" }).click();
  await expect(page.locator(".reading-paragraph")).toContainText("<script>");
  expect(
    await page.evaluate(() => (window as any).compromised),
  ).toBeUndefined();
});

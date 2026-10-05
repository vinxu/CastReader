import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir: "./e2e",
  timeout: 30000,
  reporter: [
    ["list"],
    ["json", { outputFile: "test-results/browser-report.json" }],
  ],
  use: {
    channel: "chrome",
    headless: true,
    viewport: { width: 1240, height: 860 },
    baseURL: "http://127.0.0.1:5188",
    screenshot: "only-on-failure",
  },
  webServer: {
    command: "pnpm dev",
    url: "http://127.0.0.1:5188",
    reuseExistingServer: false,
    timeout: 20000,
  },
});

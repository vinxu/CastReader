import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { _electron as electron } from "@playwright/test";

// Exercise the real main/preload/renderer and OS encryption in an isolated profile.
// No login, backend mock, saved user credential or real synthesis is involved.
assert.equal(
  process.platform,
  "win32",
  "Run this environment check on Windows.",
);
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const packaged = process.argv.includes("--packaged");
const output = join(
  root,
  "test-results",
  packaged ? "native-package" : "native-environment",
);
await mkdir(output, { recursive: true });
const scratch = await mkdtemp(join(tmpdir(), "castreader-environment-"));
const profile = join(scratch, "profile");
await mkdir(profile);
const launcher = join(scratch, "launcher.cjs");
await writeFile(
  launcher,
  `const { app } = require('electron');\napp.setPath('userData', ${JSON.stringify(profile)});\nrequire(${JSON.stringify(join(root, "build", "main.cjs"))});\n`,
);
const environment = { ...process.env };
delete environment.ELECTRON_RUN_AS_NODE;
delete environment.CASTREADER_DEV;
const launchOptions = packaged
  ? {
      executablePath: join(root, "release", "win-unpacked", "CastReader.exe"),
      args: [`--user-data-dir=${profile}`],
      env: environment,
      timeout: 45000,
    }
  : { args: [launcher], env: environment, timeout: 45000 };
let instance;
const failures = [];
const report = {
  platform: process.platform,
  packaged,
  complete: false,
  checks: [],
};
try {
  instance = await electron.launch(launchOptions);
  const window = await instance.firstWindow();
  window.on("pageerror", (error) => failures.push(error.message));
  await window.waitForURL("castreader://app/");
  await window
    .getByRole("button", { name: "Send code", exact: true })
    .waitFor();
  const native = await instance.evaluate(
    ({ app, BrowserWindow, safeStorage }) => {
      const prefs =
        BrowserWindow.getAllWindows()[0].webContents.getLastWebPreferences();
      const available = safeStorage.isEncryptionAvailable();
      const fixture = "CastReader environment fixture — not a credential";
      const roundTrip =
        available &&
        safeStorage.decryptString(safeStorage.encryptString(fixture)) ===
          fixture;
      return {
        profile: app.getPath("userData"),
        packaged: app.isPackaged,
        encryptionAvailable: available,
        encryptionRoundTrip: roundTrip,
        sandbox: prefs.sandbox,
        contextIsolation: prefs.contextIsolation,
        nodeIntegration: prefs.nodeIntegration,
        webSecurity: prefs.webSecurity,
      };
    },
  );
  assert.equal(native.profile, profile);
  assert.equal(native.packaged, packaged);
  assert.equal(native.encryptionAvailable, true);
  assert.equal(native.encryptionRoundTrip, true);
  assert.equal(native.sandbox, true);
  assert.equal(native.contextIsolation, true);
  assert.equal(native.nodeIntegration, false);
  assert.equal(native.webSecurity, true);
  report.checks.push(
    "native window and production local protocol",
    "Windows encryption round trip",
    "renderer sandbox and context isolation",
  );
  const state = await window.evaluate(async () => {
    const state = await window.castreader.bootstrap();
    await window.castreader.savePreferences({
      ...state.preferences,
      theme: "dark",
    });
    let rejected = false;
    try {
      await window.castreader.deleteDocument("fixture");
    } catch (error) {
      rejected = String(error).includes("SIGN_IN_REQUIRED");
    }
    return {
      ...state,
      rejected,
      nodeExposed: typeof window.require !== "undefined",
    };
  });
  assert.equal(state.platform, "win32");
  assert.equal(state.account, null);
  assert.deepEqual(state.documents, []);
  assert.equal(state.rejected, true);
  assert.equal(state.nodeExposed, false);
  report.checks.push("real preload IPC", "signed-out library access rejected");
  await instance.close();
  instance = await electron.launch(launchOptions);
  const reopened = await instance.firstWindow();
  reopened.on("pageerror", (error) => failures.push(error.message));
  await reopened
    .getByRole("button", { name: "Send code", exact: true })
    .waitFor();
  const theme = await reopened.evaluate(
    async () => (await window.castreader.bootstrap()).preferences.theme,
  );
  assert.equal(theme, "dark");
  assert.deepEqual(failures, []);
  await reopened.screenshot({ path: join(output, "native-login.png") });
  report.checks.push(
    "preferences persisted across native restart",
    "renderer has no page errors",
  );
  report.complete = true;
  console.log(JSON.stringify(report, null, 2));
} catch (error) {
  report.error = String(error);
  throw error;
} finally {
  if (instance) await instance.close().catch(() => {});
  await writeFile(join(output, "report.json"), JSON.stringify(report, null, 2));
  await rm(scratch, { recursive: true, force: true });
}

import {
  app,
  BrowserWindow,
  dialog,
  ipcMain,
  net,
  protocol,
  session,
  Menu,
} from "electron";
import { readFile, stat } from "node:fs/promises";
import { basename, extname, join, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { Storage } from "./storage";
import { AccountService, ApiError, synthesize } from "../core/api";
import type { Entitlement } from "../core/api";
import { record, region, string } from "../core/validation";
import type { ReadingCheckpoint } from "../core/types";

protocol.registerSchemesAsPrivileged([
  {
    scheme: "castreader",
    privileges: {
      standard: true,
      secure: true,
      supportFetchAPI: true,
      stream: true,
    },
  },
]);
if (!app.requestSingleInstanceLock()) app.quit();
let window: BrowserWindow | null = null;
app.on("second-instance", () => {
  window?.restore();
  window?.show();
  window?.focus();
});
app
  .whenReady()
  .then(async () => {
    const store = new Storage(join(app.getPath("userData"), "reader-v1"));
    const fetcher = (url: string, init: RequestInit) => net.fetch(url, init);
    const account = new AccountService(
      fetcher,
      store,
      store.deviceId(),
      app.getVersion(),
    );
    let entitlement: Entitlement | null = null;
    let aborters = new Set<AbortController>();
    const cancel = () => {
      for (const a of aborters) a.abort();
      aborters = new Set();
    };
    const scope = () => {
      if (!account.scope) throw new ApiError("SIGN_IN_REQUIRED");
      return account.scope;
    };
    const dev = !app.isPackaged && process.env.CASTREADER_DEV === "1";
    const origin = dev ? "http://127.0.0.1:5188" : "castreader://app";
    const dist = resolve(__dirname, "../dist");
    protocol.handle("castreader", (request) => {
      const url = new URL(request.url);
      if (url.hostname !== "app" || request.method !== "GET")
        return new Response("", { status: 403 });
      const target = resolve(
        dist,
        "." +
          decodeURIComponent(
            url.pathname === "/" ? "/index.html" : url.pathname,
          ),
      );
      if (!target.startsWith(dist + sep))
        return new Response("", { status: 403 });
      return net.fetch(pathToFileURL(target).toString());
    });
    session.defaultSession.setPermissionRequestHandler(
      (_contents, _permission, callback) => callback(false),
    );
    session.defaultSession.setPermissionCheckHandler(() => false);
    session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
      if (!details.url.startsWith(origin + "/"))
        return callback({ responseHeaders: details.responseHeaders });
      callback({
        responseHeaders: {
          ...details.responseHeaders,
          "Content-Security-Policy": [
            `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; worker-src 'self' blob:; connect-src 'self' ${dev ? "ws://127.0.0.1:5188" : ""}; object-src 'none'; base-uri 'none'; frame-src 'none'`,
          ],
        },
      });
    });
    const bind = (name: string, handler: (data: unknown) => unknown) =>
      ipcMain.handle(`cr:${name}`, async (event, data) => {
        if (
          !window ||
          event.sender !== window.webContents ||
          event.senderFrame !== window.webContents.mainFrame ||
          !event.senderFrame.url.startsWith(origin + "/")
        )
          throw new Error("UNTRUSTED_SENDER");
        try {
          return await handler(data);
        } catch (error) {
          if (!account.account) {
            cancel();
            entitlement = null;
          }
          const message = error instanceof Error ? error.message : "";
          // Never send raw network bodies, filesystem paths or credentials to the UI.
          throw new Error(
            /^[A-Z][A-Z0-9_]{1,80}$/.test(message)
              ? message
              : "OPERATION_FAILED",
          );
        }
      });
    bind("bootstrap", () => ({
      account: account.account,
      preferences: store.getPreferences(),
      ...(account.scope
        ? store.library(account.scope)
        : { documents: [], checkpoints: {} }),
      platform: process.platform,
      version: app.getVersion(),
    }));
    bind("sendCode", (raw) => {
      const d = record(raw);
      return account.sendCode(string(d.email, 254), region(d.region));
    });
    bind("signIn", async (raw) => {
      const d = record(raw);
      cancel();
      entitlement = null;
      return account.signIn(
        string(d.email, 254),
        string(d.otp, 32),
        region(d.region),
      );
    });
    bind("signOut", () => {
      cancel();
      entitlement = null;
      return account.signOut();
    });
    bind("entitlement", async () => {
      entitlement = await account.status();
      return entitlement;
    });
    bind("importFile", async () => {
      const owner = scope();
      const selection = await dialog.showOpenDialog(window!, {
        title: "Open a document",
        properties: ["openFile"],
        filters: [
          {
            name: "Documents",
            extensions: ["txt", "md", "markdown", "docx", "epub", "pdf"],
          },
        ],
      });
      if (selection.canceled || !selection.filePaths[0]) return null;
      const path = selection.filePaths[0],
        info = await stat(path);
      if (!info.isFile() || info.size > 50000000)
        throw new Error("FILE_TOO_LARGE");
      const bytes = await readFile(path);
      if (owner !== scope()) throw new Error("ACCOUNT_CHANGED");
      return {
        name: basename(path),
        extension: extname(path).slice(1).toLowerCase(),
        bytes: new Uint8Array(bytes),
      };
    });
    bind("saveDocument", (doc) => store.saveDocument(scope(), doc));
    bind("deleteDocument", (id) =>
      store.deleteDocument(scope(), string(id, 80)),
    );
    bind("savePreferences", (prefs) => store.savePreferences(prefs));
    bind("saveCheckpoint", (value) =>
      store.saveCheckpoint(scope(), value as ReadingCheckpoint),
    );
    bind("cancelSpeech", cancel);
    bind("speak", async (raw) => {
      scope();
      const owner = account.generation,
        d = record(raw),
        currentAccount = account.account!;
      if (
        entitlement?.listenRemaining !== undefined &&
        entitlement.listenRemaining <= 0
      )
        throw new ApiError("LISTEN_QUOTA_EXHAUSTED");
      if (aborters.size >= 2) throw new ApiError("SPEECH_BUSY");
      const controller = new AbortController();
      aborters.add(controller);
      try {
        const result = await synthesize(
          fetcher,
          {
            text: string(d.text, 5000),
            voice: string(d.voice, 100),
            language: string(d.language, 16),
            region: currentAccount.region,
            requestId: string(d.requestId, 80),
          },
          AbortSignal.any([controller.signal, AbortSignal.timeout(140000)]),
        );
        if (owner !== account.generation) throw new ApiError("ACCOUNT_CHANGED");
        return result;
      } finally {
        aborters.delete(controller);
      }
    });
    bind("track", async (raw) => {
      const d = record(raw),
        id = string(d.eventId, 80);
      if (
        !/^[a-f0-9-]{36}$/.test(id) ||
        typeof d.seconds !== "number" ||
        !Number.isInteger(d.seconds) ||
        d.seconds < 1 ||
        d.seconds > 120
      )
        throw new ApiError("INVALID_USAGE");
      await account.track(id, d.seconds);
    });
    window = new BrowserWindow({
      width: 1240,
      height: 860,
      minWidth: 800,
      minHeight: 600,
      backgroundColor: "#FAF9F6",
      title: "CastReader",
      webPreferences: {
        preload: join(__dirname, "preload.cjs"),
        sandbox: true,
        contextIsolation: true,
        nodeIntegration: false,
        webSecurity: true,
        spellcheck: true,
      },
    });
    window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
    window.webContents.on("will-navigate", (event, url) => {
      if (!url.startsWith(origin + "/")) event.preventDefault();
    });
    window.webContents.on("will-attach-webview", (event) =>
      event.preventDefault(),
    );
    window.on("closed", () => {
      cancel();
      window = null;
    });
    Menu.setApplicationMenu(
      Menu.buildFromTemplate([
        { label: "CastReader", submenu: [{ role: "quit" }] },
        { role: "editMenu" },
        {
          label: "View",
          submenu: [
            { role: "zoomIn" },
            { role: "zoomOut" },
            { role: "resetZoom" },
            { role: "togglefullscreen" },
            ...(dev ? [{ role: "toggleDevTools" as const }] : []),
          ],
        },
      ]),
    );
    await window.loadURL(origin + "/");
  })
  .catch(() => {
    dialog.showErrorBox(
      "CastReader",
      "Unable to open secure local storage. Please retry after signing in to Windows.",
    );
    app.quit();
  });
app.on("window-all-closed", () => app.quit());

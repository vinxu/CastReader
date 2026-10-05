import {
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import {
  AudioLines,
  BookOpen,
  ChevronLeft,
  FileText,
  FolderOpen,
  Home,
  Library,
  LogOut,
  Pause,
  Play,
  Plus,
  Search,
  Settings,
  Trash2,
  X,
} from "lucide-react";
import type { Bootstrap, DesktopBridge } from "../core/bridge";
import type { Entitlement } from "../core/api";
import type { ReaderPreferences, ReadingDocument, Region } from "../core/types";
import { makeDocument } from "../core/documents";
import { ReaderPlayer, readableError } from "./player";
import { errorMessage, translator } from "./i18n";
import type { Translate } from "./i18n";

export function App() {
  const bridge = window.castreader;
  if (!bridge)
    return (
      <main className="native-message">
        <AudioLines size={48} />
        <h1>CastReader</h1>
        <p>Open the CastReader desktop app to read your documents.</p>
        <p>请在 CastReader 桌面应用中打开。</p>
      </main>
    );
  return <DesktopApp bridge={bridge} />;
}
function DesktopApp({ bridge }: { bridge: DesktopBridge }) {
  const [data, setData] = useState<Bootstrap | null>(null),
    [tab, setTab] = useState<"home" | "library" | "settings">("home");
  const [doc, setDoc] = useState<ReadingDocument | null>(null),
    [entitlement, setEntitlement] = useState<Entitlement | null>(null);
  const [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [pasting, setPasting] = useState(false);
  const [player] = useState(() => new ReaderPlayer(bridge));
  const state = useSyncExternalStore(player.subscribe, player.snapshot);
  const t = useMemo(
    () =>
      translator(
        data?.preferences.locale ??
          (navigator.language.startsWith("zh") ? "zh-Hans" : "en"),
      ),
    [data?.preferences.locale],
  );
  const bootstrap = async () => {
    const next = await bridge.bootstrap();
    setData(next);
    return next;
  };
  useEffect(() => {
    let alive = true;
    void bridge
      .bootstrap()
      .then((d) => {
        if (alive) setData(d);
      })
      .catch((e) => {
        if (alive) setError(readableError(e));
      });
    return () => {
      alive = false;
      player.stop();
    };
  }, [bridge, player]);
  useEffect(() => {
    if (!data?.account) {
      setEntitlement(null);
      return;
    }
    let alive = true;
    void bridge
      .entitlement()
      .then((v) => {
        if (alive) setEntitlement(v);
      })
      .catch((e) => {
        if (alive) setError(readableError(e));
      });
    return () => {
      alive = false;
    };
  }, [bridge, data?.account?.id, data?.account?.region]);
  useEffect(() => {
    if (data) {
      document.documentElement.dataset.theme = data.preferences.theme;
      document.documentElement.lang = data.preferences.locale;
    }
  }, [data?.preferences.theme, data?.preferences.locale]);
  useEffect(() => {
    const handler = () => player.pause();
    window.addEventListener("beforeunload", handler);
    return () => window.removeEventListener("beforeunload", handler);
  }, [player]);
  async function perform(work: () => Promise<unknown>) {
    setBusy(true);
    setError("");
    try {
      await work();
    } catch (e) {
      setError(readableError(e));
    } finally {
      setBusy(false);
    }
  }
  async function updatePreferences(prefs: ReaderPreferences) {
    await bridge.savePreferences(prefs);
    if (
      prefs.voice !== data?.preferences.voice ||
      prefs.language !== data?.preferences.language
    )
      player.stop();
    player.setSpeed(prefs.speed);
    setData((d) => (d ? { ...d, preferences: prefs } : d));
  }
  async function openDocument(document: ReadingDocument) {
    player.stop();
    await bootstrap();
    setDoc(document);
  }
  async function importFile() {
    const file = await bridge.importFile();
    if (!file) return;
    const { importDocument } = await import("./importer");
    const document = await importDocument(file);
    await bridge.saveDocument(document);
    await openDocument(document);
  }
  async function signOut() {
    player.stop();
    setDoc(null);
    setEntitlement(null);
    setData((d) =>
      d ? { ...d, account: null, documents: [], checkpoints: {} } : d,
    );
    await bridge.signOut();
    await bootstrap();
  }
  function play(paragraphId?: string) {
    if (!doc || !data?.account) return;
    const scope = `${data.account.region}:${data.account.id}`;
    if (!paragraphId && state.status === "paused") player.resume();
    else
      void player.start(
        doc,
        data.preferences,
        scope,
        data.checkpoints[doc.id],
        paragraphId,
      );
  }
  if (!data)
    return (
      <main className="native-message">
        <AudioLines size={48} />
        <h1>CastReader</h1>
        <p role="status">{error || t("working")}</p>
        {error && (
          <button onClick={() => void perform(bootstrap)}>{t("retry")}</button>
        )}
      </main>
    );
  if (!data.account)
    return (
      <SignIn
        t={t}
        bridge={bridge}
        busy={busy}
        error={error ? errorMessage(error, data.preferences.locale) : ""}
        perform={perform}
        onSuccess={bootstrap}
      />
    );
  return (
    <div className="app-shell">
      <aside className="sidebar">
        <a
          className="brand"
          href="#home"
          onClick={(e) => {
            e.preventDefault();
            player.stop();
            setDoc(null);
            setTab("home");
          }}
        >
          <span className="brand-mark">
            <AudioLines />
          </span>
          <span>CastReader</span>
        </a>
        <nav aria-label="Navigation">
          {(
            [
              { id: "home", Icon: Home },
              { id: "library", Icon: Library },
              { id: "settings", Icon: Settings },
            ] as const
          ).map(({ id, Icon }) => (
            <button
              key={id}
              className={
                !doc && tab === id ? "nav-button active" : "nav-button"
              }
              aria-current={!doc && tab === id ? "page" : undefined}
              onClick={() =>
                void perform(async () => {
                  player.stop();
                  setDoc(null);
                  setTab(id);
                  await bootstrap();
                })
              }
            >
              <Icon size={20} />
              {t(id)}
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <div className="account-avatar">
            {data.account.displayName.slice(0, 1).toUpperCase()}
          </div>
          <div className="account-copy">
            <strong>{data.account.displayName}</strong>
            <small>
              {entitlement
                ? t(entitlement.pro ? "pro" : "free")
                : data.account.email}
            </small>
          </div>
          <button
            className="icon-button"
            aria-label={t("signOut")}
            onClick={() => void perform(signOut)}
            disabled={busy}
          >
            <LogOut size={18} />
          </button>
        </div>
      </aside>
      <main className="main-pane">
        {(error || state.error) && (
          <div role="alert" className="error-banner">
            <span>
              {errorMessage(error || state.error!, data.preferences.locale)}
            </span>
            <button
              className="icon-button"
              aria-label={t("cancel")}
              onClick={() => setError("")}
            >
              <X size={18} />
            </button>
          </div>
        )}
        {busy && (
          <div className="busy-line" role="status">
            {t("working")}
          </div>
        )}
        {doc ? (
          <Reader
            document={doc}
            t={t}
            preferences={data.preferences}
            paragraphId={state.paragraphId}
            range={state.range}
            onBack={() =>
              void perform(async () => {
                player.stop();
                setDoc(null);
                setTab("library");
                await bootstrap();
              })
            }
            onReadParagraph={play}
            onFont={(fontSize) =>
              void perform(() =>
                updatePreferences({ ...data.preferences, fontSize }),
              )
            }
          />
        ) : tab === "settings" ? (
          <Preferences
            t={t}
            data={data}
            entitlement={entitlement}
            onChange={(prefs) => void perform(() => updatePreferences(prefs))}
            onSignOut={() => void perform(signOut)}
          />
        ) : (
          <LibraryPane
            t={t}
            isHome={tab === "home"}
            documents={data.documents}
            onOpen={(d) => void perform(() => openDocument(d))}
            onImport={() => void perform(importFile)}
            onPaste={() => setPasting(true)}
            onDelete={(d) => {
              if (confirm(t("confirmDelete")))
                void perform(async () => {
                  await bridge.deleteDocument(d.id);
                  await bootstrap();
                });
            }}
          />
        )}
        {doc && (
          <footer className="player-bar">
            <div className="player-title">
              <span className="document-icon">
                <FileText size={20} />
              </span>
              <div>
                <strong>{doc.title}</strong>
                <small role="status">
                  {state.status === "buffering"
                    ? t("waiting")
                    : state.status === "complete"
                      ? t("complete")
                      : data.checkpoints[doc.id] && state.status === "idle"
                        ? t("restoreHint")
                        : t("read")}
                </small>
              </div>
            </div>
            <button
              className="play-button"
              aria-label={t(
                state.status === "playing" || state.status === "buffering"
                  ? "pause"
                  : state.status === "paused"
                    ? "resume"
                    : "read",
              )}
              onClick={() =>
                state.status === "playing" || state.status === "buffering"
                  ? player.pause()
                  : play()
              }
            >
              {state.status === "playing" || state.status === "buffering" ? (
                <Pause size={22} fill="currentColor" />
              ) : (
                <Play size={22} fill="currentColor" />
              )}
            </button>
            <label className="speed-control">
              <span>{t("speed")}</span>
              <select
                aria-label={t("speed")}
                value={data.preferences.speed}
                onChange={(e) =>
                  void perform(() =>
                    updatePreferences({
                      ...data.preferences,
                      speed: Number(e.target.value),
                    }),
                  )
                }
              >
                {[
                  0.5,
                  0.75,
                  1,
                  1.25,
                  1.5,
                  1.75,
                  2,
                  ...(entitlement?.pro ? [2.5, 3, 3.5, 4] : []),
                ].map((n) => (
                  <option key={n} value={n}>
                    {n}×
                  </option>
                ))}
              </select>
            </label>
          </footer>
        )}
      </main>
      {pasting && (
        <PasteDialog
          t={t}
          busy={busy}
          onClose={() => setPasting(false)}
          onSave={(title, text) =>
            void perform(async () => {
              const next = await makeDocument(title, text);
              await bridge.saveDocument(next);
              setPasting(false);
              await openDocument(next);
            })
          }
        />
      )}
    </div>
  );
}
function SignIn({
  t,
  bridge,
  busy,
  error,
  perform,
  onSuccess,
}: {
  t: Translate;
  bridge: DesktopBridge;
  busy: boolean;
  error: string;
  perform: (fn: () => Promise<unknown>) => Promise<void>;
  onSuccess: () => Promise<unknown>;
}) {
  const [email, setEmail] = useState(""),
    [code, setCode] = useState(""),
    [region, setRegion] = useState<Region>("global"),
    [sent, setSent] = useState(false);
  return (
    <main className="auth-layout">
      <section className="auth-art">
        <span className="brand-mark large">
          <AudioLines size={54} />
        </span>
        <h1>CastReader</h1>
        <p>{t("tagline")}</p>
        <div className="reading-art" aria-hidden="true">
          <span />
          <span />
          <span />
          <span />
          <span />
          <span />
        </div>
      </section>
      <section className="auth-form">
        <div>
          <h2>{t("signIn")}</h2>
          <p className="muted">{t("signInHint")}</p>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void perform(async () => {
                await bridge.signIn(email, code, region);
                await onSuccess();
              });
            }}
          >
            <label>
              {t("region")}
              <select
                value={region}
                disabled={busy || sent}
                onChange={(e) => setRegion(e.target.value as Region)}
              >
                <option value="global">{t("global")}</option>
                <option value="cn">{t("china")}</option>
              </select>
            </label>
            <label>
              {t("email")}
              <input
                type="email"
                autoComplete="email"
                required
                value={email}
                disabled={busy}
                onChange={(e) => {
                  setEmail(e.target.value);
                  setSent(false);
                  setCode("");
                }}
              />
            </label>
            <div className="code-row">
              <label>
                {t("code")}
                <input
                  autoComplete="one-time-code"
                  inputMode="numeric"
                  required
                  value={code}
                  disabled={busy}
                  onChange={(e) => setCode(e.target.value)}
                />
              </label>
              <button
                type="button"
                className="secondary"
                disabled={busy || !email}
                onClick={() =>
                  void perform(async () => {
                    await bridge.sendCode(email, region);
                    setSent(true);
                  })
                }
              >
                {t("sendCode")}
              </button>
            </div>
            {sent && (
              <p role="status" className="muted">
                {t("codeSent")}
              </p>
            )}
            {error && (
              <p role="alert" className="error-text">
                {error}
              </p>
            )}
            <button className="primary" disabled={busy || !code}>
              {busy ? t("working") : t("signIn")}
            </button>
          </form>
        </div>
      </section>
    </main>
  );
}
function LibraryPane({
  t,
  isHome,
  documents,
  onOpen,
  onImport,
  onPaste,
  onDelete,
}: {
  t: Translate;
  isHome: boolean;
  documents: ReadingDocument[];
  onOpen: (d: ReadingDocument) => void;
  onImport: () => void;
  onPaste: () => void;
  onDelete: (d: ReadingDocument) => void;
}) {
  const [query, setQuery] = useState("");
  const filtered = documents.filter((d) =>
    d.title.toLocaleLowerCase().includes(query.toLocaleLowerCase()),
  );
  return (
    <div className="page-content">
      <header className="page-heading">
        <div>
          <p className="eyebrow">{isHome ? "CASTREADER" : t("library")}</p>
          <h1>{isHome ? t("welcome") : t("library")}</h1>
          {isHome && <p className="muted">{t("tagline")}</p>}
        </div>
        {!isHome && (
          <button className="primary" onClick={onImport}>
            <Plus size={18} />
            {t("import")}
          </button>
        )}
      </header>
      {isHome && (
        <div className="source-grid">
          <button className="source-card" onClick={onImport}>
            <span className="source-icon">
              <FolderOpen size={26} />
            </span>
            <strong>{t("import")}</strong>
            <span>{t("supported")}</span>
          </button>
          <button className="source-card" onClick={onPaste}>
            <span className="source-icon pale">
              <FileText size={26} />
            </span>
            <strong>{t("paste")}</strong>
            <span>{t("clipboardHint")}</span>
          </button>
        </div>
      )}
      <div className="section-heading">
        <h2>{isHome ? t("recent") : t("library")}</h2>
        <label className="search-box">
          <Search size={17} />
          <input
            aria-label={t("search")}
            placeholder={t("search")}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </label>
      </div>
      {filtered.length ? (
        <div className="document-list">
          {filtered.map((d) => (
            <article className="document-row" key={d.id}>
              <button className="document-open" onClick={() => onOpen(d)}>
                <span className="document-cover">
                  <FileText size={28} />
                </span>
                <span>
                  <strong>{d.title}</strong>
                  <small>
                    {d.sourceKind.toUpperCase()} ·{" "}
                    {new Date(d.importedAt).toLocaleDateString()}
                  </small>
                </span>
                <Play className="row-play" size={18} />
              </button>
              <button
                className="icon-button"
                aria-label={`${t("delete")} ${d.title}`}
                onClick={() => onDelete(d)}
              >
                <Trash2 size={17} />
              </button>
            </article>
          ))}
        </div>
      ) : (
        <div className="empty-library">
          <BookOpen size={40} strokeWidth={1.3} />
          <h3>{t("empty")}</h3>
          <p>{t("emptyHint")}</p>
        </div>
      )}
    </div>
  );
}
function Reader({
  document: doc,
  t,
  preferences,
  paragraphId,
  range,
  onBack,
  onReadParagraph,
  onFont,
}: {
  document: ReadingDocument;
  t: Translate;
  preferences: ReaderPreferences;
  paragraphId: string | null;
  range: { start: number; end: number } | null;
  onBack: () => void;
  onReadParagraph: (id: string) => void;
  onFont: (n: number) => void;
}) {
  const container = useRef<HTMLDivElement>(null),
    manualUntil = useRef(0);
  useEffect(() => {
    if (!paragraphId || performance.now() < manualUntil.current) return;
    const node = container.current?.querySelector(
      `[data-paragraph="${CSS.escape(paragraphId)}"]`,
    );
    node?.scrollIntoView({
      block: "center",
      behavior: matchMedia("(prefers-reduced-motion: reduce)").matches
        ? "instant"
        : "smooth",
    });
  }, [paragraphId]);
  return (
    <div className="reader">
      <header className="reader-header">
        <button className="text-button" onClick={onBack}>
          <ChevronLeft size={18} />
          {t("back")}
        </button>
        <div className="font-control">
          <label htmlFor="font-size">Aa</label>
          <input
            id="font-size"
            aria-label={t("font")}
            type="range"
            min={14}
            max={40}
            step={1}
            value={preferences.fontSize}
            onChange={(e) => onFont(Number(e.target.value))}
          />
        </div>
      </header>
      <div
        ref={container}
        className="reader-scroll"
        onWheel={() => {
          manualUntil.current = performance.now() + 8000;
        }}
        onTouchMove={() => {
          manualUntil.current = performance.now() + 8000;
        }}
      >
        <article
          className="reading-page"
          style={{ fontSize: preferences.fontSize }}
        >
          <p className="eyebrow">{doc.sourceKind.toUpperCase()}</p>
          <h1>{doc.title}</h1>
          {doc.paragraphs.map((p) => {
            const active = p.id === paragraphId;
            return p.kind === "image" ? (
              <figure key={p.id}>
                {p.image && <img src={p.image} alt="" loading="lazy" />}
              </figure>
            ) : (
              <div
                data-paragraph={p.id}
                key={p.id}
                className={`reading-paragraph ${p.kind} ${active ? "is-reading" : ""}`}
              >
                <button
                  className="paragraph-play icon-button"
                  aria-label={`${t("readParagraph")}: ${p.text.slice(0, 35)}`}
                  onClick={() => onReadParagraph(p.id)}
                >
                  <Play size={15} />
                </button>
                <p
                  role={p.kind === "heading" ? "heading" : undefined}
                  aria-level={
                    p.kind === "heading"
                      ? Math.min((p.level ?? 1) + 1, 6)
                      : undefined
                  }
                >
                  {active && range ? (
                    <>
                      {p.text.slice(0, range.start)}
                      <mark>{p.text.slice(range.start, range.end)}</mark>
                      {p.text.slice(range.end)}
                    </>
                  ) : (
                    p.text
                  )}
                </p>
              </div>
            );
          })}
        </article>
      </div>
    </div>
  );
}
function Preferences({
  t,
  data,
  entitlement,
  onChange,
  onSignOut,
}: {
  t: Translate;
  data: Bootstrap;
  entitlement: Entitlement | null;
  onChange: (p: ReaderPreferences) => void;
  onSignOut: () => void;
}) {
  const p = data.preferences;
  return (
    <div className="page-content settings-page">
      <header className="page-heading">
        <h1>{t("settings")}</h1>
      </header>
      <section className="settings-section">
        <h2>{t("account")}</h2>
        <div className="settings-row">
          <div>
            <strong>{data.account?.displayName}</strong>
            <small>{data.account?.email}</small>
          </div>
          <span className="pill">
            {entitlement ? t(entitlement.pro ? "pro" : "free") : "—"}
          </span>
        </div>
        {entitlement?.listenRemaining !== undefined && (
          <div className="settings-row">
            <span>{t("quota")}</span>
            <span>
              {Math.floor(entitlement.listenRemaining / 60)} {t("minutes")}
            </span>
          </div>
        )}
      </section>
      <section className="settings-section">
        <h2>{t("appearance")}</h2>
        <label className="settings-row">
          {t("theme")}
          <select
            value={p.theme}
            onChange={(e) =>
              onChange({
                ...p,
                theme: e.target.value as ReaderPreferences["theme"],
              })
            }
          >
            <option value="system">{t("system")}</option>
            <option value="light">{t("light")}</option>
            <option value="dark">{t("dark")}</option>
          </select>
        </label>
        <label className="settings-row">
          {t("uiLanguage")}
          <select
            value={p.locale}
            onChange={(e) => onChange({ ...p, locale: e.target.value })}
          >
            <option value="en">English</option>
            <option value="zh-Hans">简体中文</option>
          </select>
        </label>
      </section>
      <section className="settings-section">
        <h2>{t("playback")}</h2>
        <label className="settings-row">
          {t("voice")}
          <select
            value={p.voice}
            onChange={(e) =>
              onChange({ ...p, voice: e.target.value, language: "en" })
            }
          >
            <option value="af_heart">Heart · English (US)</option>
            <option value="af_bella">Bella · English (US)</option>
            <option value="bf_emma">Emma · English (UK)</option>
          </select>
        </label>
        <label className="settings-row">
          {t("font")}
          <input
            aria-label={t("font")}
            type="number"
            min={14}
            max={40}
            value={p.fontSize}
            onChange={(e) => {
              const n = Number(e.target.value);
              if (n >= 14 && n <= 40) onChange({ ...p, fontSize: n });
            }}
          />
        </label>
      </section>
      <p className="muted">{t("privacy")}</p>
      <div className="settings-row">
        <small>
          {t("version")} {data.version}
        </small>
        <button className="text-button" onClick={onSignOut}>
          {t("signOut")}
        </button>
      </div>
    </div>
  );
}
function PasteDialog({
  t,
  busy,
  onClose,
  onSave,
}: {
  t: Translate;
  busy: boolean;
  onClose: () => void;
  onSave: (title: string, text: string) => void;
}) {
  const dialog = useRef<HTMLDialogElement>(null),
    [title, setTitle] = useState(""),
    [text, setText] = useState("");
  useEffect(() => {
    dialog.current?.showModal();
    return () => dialog.current?.close();
  }, []);
  return (
    <dialog
      ref={dialog}
      className="paste-dialog"
      onCancel={(e) => {
        e.preventDefault();
        if (!busy) onClose();
      }}
    >
      <form
        onSubmit={(e) => {
          e.preventDefault();
          onSave(title || t("untitled"), text);
        }}
      >
        <header>
          <h2>{t("paste")}</h2>
          <button
            type="button"
            className="icon-button"
            disabled={busy}
            aria-label={t("cancel")}
            onClick={onClose}
          >
            <X />
          </button>
        </header>
        <label>
          {t("title")}
          <input
            autoFocus
            maxLength={512}
            value={title}
            onChange={(e) => setTitle(e.target.value)}
          />
        </label>
        <label>
          {t("text")}
          <textarea
            required
            value={text}
            onChange={(e) => setText(e.target.value)}
          />
        </label>
        <footer>
          <button
            type="button"
            className="secondary"
            disabled={busy}
            onClick={onClose}
          >
            {t("cancel")}
          </button>
          <button className="primary" disabled={busy || !text.trim()}>
            {t("save")}
          </button>
        </footer>
      </form>
    </dialog>
  );
}

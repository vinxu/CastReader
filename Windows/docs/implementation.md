# CastReader Windows implementation and acceptance

Started 2026-10-05. Owner: this chat. Branch: codex/windows-parity.

## Scope and baseline

The requested deliverable is a Windows product matching the current Mac/iOS product, including requirements, settings, interaction, visuals, and real-device acceptance. The baseline is iOS 09456f1979cc14ca19977ede4b1edde043c5f840 plus explicitly inventoried Mac Catalyst fixes, not the older independent Swift Mac desktop utility. baseline.json records source hashes from the still-active Mac working tree. Source changes after capture require review before porting.

parity.json captures all 40 existing feature groups. acceptance.json preserves 145 reference cases and their source expectations. All Windows outcomes start NOT_RUN. Existing Mac/iOS test results provide reference evidence only. Windows-specific case steps must be completed before a case can pass.

Do not omit Kindle offline, O'Reilly, YouTube, Google Drive, private/community voices, voice gifts, clone credits, account isolation, resume, accessibility, or OS integration. YouTube has subtitle reading in the reference; do not invent Explain parity where the baseline has no Explain mode. Dropbox/OneDrive are source files but not shipped baseline integrations.

Windows regional scope must preserve the iOS Global/CN service and account separation. The Mac-only Global decision does not automatically remove the Windows CN requirements. Initial engineering validation uses Global, with CN parity independently tracked. No production price, allowance, OAuth registration, or backend deployment changes are implied by client work.

## Architecture decision: Electron with a typed portable reader core

Electron provides a Windows runtime and isolated browser contexts for the existing browser extraction scripts, permits reuse of TypeScript document tools, and supports a single deterministic test harness before real PC checks. React renders the local application; third-party pages use separate sandboxed WebContentsView instances without application IPC or Node access. Main owns file dialogs, selected-file capabilities, session credentials, network requests, and persistence. Only named, validated IPC operations are exposed to the local renderer.

The alternative WinUI/WebView2 route offers native Windows controls but adds a second bridge/rendering stack and separate C# infrastructure. Tauri/WebView2 is a viable footprint alternative but introduces Rust and another IPC integration. Revisit the Electron choice if measured Windows memory, accessibility, IME, or provider compatibility fails an agreed acceptance gate. Source parity does not imply Swift binaries or Apple APIs can run on Windows.

Never disable webSecurity, TLS validation, or renderer sandboxing. Never copy third-party cookies between machines. Tokens use OS-backed encryption, not renderer localStorage. External navigation is restricted to validated HTTPS URLs. Imported content is data, not application code. File parsers enforce size, archive path, expansion, and cancellation limits.

## Delivery gates

1. W00: host access, baseline inventory, requirements traceability, architecture, reproducible dependency lock.
2. W01: Windows x64 Debug/Release startup, secure shell, install/uninstall, native file selection, keyboard/IME/window baseline.
3. W02: account login/logout/restart, canonical server identity, encrypted session, old-response isolation, Pro authority.
4. W03: TXT/Markdown/DOCX/EPUB/PDF/photo import, layout/TOC/images/OCR, local history and precise reopen.
5. W04: real cloud Read/Explain, timestamps/source projection, handwritten marks, streaming, retry/cancel, speed/voice switches, sleep timer, mini-player, audio ownership.
6. W05: voice discovery, authorized recordings/uploads, clone jobs, personal/community/friend voices, gifts and credit ledger.
7. W06: Kindle online/offline; WeRead; Kobo; Google Play Books, each with real authorized accounts and independent long runs.
8. W07: O'Reilly, YouTube, ordinary/special web content and Google Drive.
9. W08: complete settings/localization, Narrator, keyboard, Explorer/deep links/share/media integration, Chrome/Edge coexistence, sync/upgrade/fault handling.
10. W09: combined regression, measured performance, final signed-candidate identity, install/update/rollback, user acceptance.

Cross-cutting code may be implemented earlier, but its product gate cannot pass until evidence exists. Final acceptance is blocked by any missing required function, unresolved critical defect, absent Windows execution, or missing authorized test account. Commercial code signing and public release are distinct from local acceptance; do not publish merely because an unsigned engineering build works.

## Windows translation of platform-specific behavior

Use Windows file picker/Explorer and drag-drop instead of Finder. Use Narrator/UI Automation instead of VoiceOver. Use Windows media keys, notifications, share/deep-link contracts and taskbar entry points for corresponding Apple system entry points. Use Windows OCR and system speech only for the existing offline scenarios; online reading cannot silently downgrade to untimed system speech. Server Pro remains authoritative; StoreKit UI translates to the established account-backed Windows purchase/manage route after its contract is verified.

## Design and interaction

Preserve the existing warm neutral canvas, orange brand (#FD5F01), accessible orange text (#C44700), dark equivalents, source cards, Read/Explain distinction, word focus and handwritten annotations. Adapt composition to desktop: persistent sidebar, resizable content area, visible document title and source, single playback owner, keyboard focus, context menus, and no touch-only action. Test 800x600 through full-screen, 100/125/150/200% scale, light/dark, long nine-language strings, Narrator, reduced motion, and keyboard-only paths.

Rendering full source paragraphs must remain stable when successive audio parts arrive. Word timing stays in the synthesized text coordinates and projects to verified source spans; duplicate words and Unicode cannot be resolved by arbitrary first-match search. User browsing and actual listening position are separate. Resume restores paused state and valid content identity; a different document/version/account cannot inherit an old cursor.

## Evidence rules

Each run records host/OS/architecture, source/lock/candidate SHA, scenario, fixture or live account category, timings, screenshot/audio/event evidence, result and limitations. Test credentials, tokens, cookies, private text and source documents are excluded from committed reports. Real synthesis is never replaced by canned audio and labeled LIVE. Unit fixture passes, local browser UI passes, Windows UI passes and live-provider passes remain distinct.

For each book source: two authorized books, 30-minute reading, 15-minute Explain where supported, crossing chapters, at least 20 automatic page turns where applicable, short tail/end, pause/manual browsing, font/theme/window reflow, cold resume and account boundary. Long PDF/EPUB runs, loss of network, 401/429/5xx, disk limits, cancellation and crash recovery are required.

## Current environment limitation

The user reports Mac-to-PC control is configured. This chat's project/task tools currently expose only host local (Mac); Windows SSH at the previously reported LAN address 192.168.71.70:22 did not connect. Computer Use rejects interacting with the ChatGPT application itself. Connection method and visible PC host name were requested while independent work continues. This is not evidence that the user's connection is absent, and does not authorize claiming Windows tests have run.

## Primary technical references

- https://www.electronjs.org/docs/latest/tutorial/security
- https://www.electronjs.org/docs/latest/api/web-contents-view
- https://www.electronjs.org/docs/latest/api/safe-storage
- https://learn.chatgpt.com/docs/remote-connections
- https://learn.chatgpt.com/docs/computer-use

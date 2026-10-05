# CastReader Windows engineering preview

This directory is the beginning of the Windows port, not a release or a completed Mac/iOS parity claim. See `docs/implementation.md`, `docs/parity.json`, and `docs/acceptance.json` for the full scope and remaining gates.

## Toolchain

- Windows x64, Node.js 24+ LTS, pnpm 10.25.0, Git.
- `scripts/provision-windows.ps1` installs/verifies development tools using Microsoft's WinGet source. Its optional `-IncludeNativeTools` stage installs Python, MSVC and Windows SDK components. Run in an administrator PowerShell. Supply `-Proxy ''` if no local proxy is required; the development PC currently uses v2rayN on `127.0.0.1:10808`.
- The provisioner writes a machine report under `%ProgramData%\CastReader\DevelopmentSetup`. A successful download is not a successful installation; command versions and the subsequent application build must be checked.
- The PC environment is now installed and verified. See `docs/environment-2026-10-05.json` for versions, hashes and results. The Windows checkout is `C:\Users\Admin\source\CastReader`; the application lives in its `Windows` directory.

For repeatable dependency setup, including Electron's lazy Windows runtime download:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/setup-project.ps1
# From the local Windows desktop, add -Verify to run build and environment checks.
# From administrator SSH, use -Verify -DesktopSession instead.
# Add -BuildInstaller to also generate unsigned NSIS and ZIP candidates.
```

```powershell
pnpm install --frozen-lockfile
pnpm test
pnpm build
pnpm start
```

For a renderer development server, run `pnpm dev`, and in another terminal set `$env:CASTREADER_DEV='1'` and run `pnpm build:host; pnpm start`. Production builds always load local packaged content with a strict CSP. Browser preview without the desktop bridge intentionally cannot access files or credentials.

`pnpm test:ui` runs an explicitly simulated browser bridge and generated silent WAV fixture. These tests cover renderer interactions, content stability, account UI isolation and unsafe markup. They do not exercise real authentication, real synthesis, Windows safeStorage, native dialogs or Windows playback.

`pnpm test:native` runs real main/preload/renderer code in an isolated Windows profile, checks Windows encryption and settings across restart, and captures the login window. It requires an interactive desktop for screenshots. From administrator SSH use `scripts/verify-desktop.ps1`; after packaging add `-Packaged` to check `release/win-unpacked/CastReader.exe`. This does not test live account login or speech.

`pnpm package:windows` builds x64 NSIS and ZIP candidates. This does not publish or commercially sign them. Final acceptance requires the real Windows matrix, provider accounts, live audio and long-run evidence.

## Implemented first slice

Secure Electron main/preload separation; email OTP/mobile session exchange; generation-isolated refresh/logout; OS encrypted credentials; server v2 entitlement transport; selected-file access; text/Markdown, DOCX text, EPUB chapters/images and PDF text extraction; local account-scoped library; full-source rendering; generation-gated streaming queue; Unicode source projection; paragraph start, pause, speed, light/dark, local progress; English/Chinese shell.

## Known incomplete product areas

Windows build, native startup and environment checks have passed; full product acceptance has not. Only three English preset choices are exposed. Other UI languages and the full voice catalog are pending. DOCX rich formatting and images, PDF original-page rendering and OCR, encrypted books, online provider views, offline Kindle, Google/Apple sign-in, phone sign-in where applicable, consent screens, Explain/marks, voice cloning/gifts/credits, purchases, complete quota recovery, cloud sync, Drive, OS integrations, upgrades and final accessibility/performance remain incomplete. No preview build should be treated as production ready.

Credentials stay in main-process encrypted storage. Do not add backend API keys, reuse a browser's private cookies, disable TLS verification, or replace a server-authenticated session with a user ID.

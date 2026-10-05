# Windows progress — 2026-10-05

## Environment first (latest user priority)

The requested PC development environment is installed and verified on DESKTOP-6ILA6MB (Windows 11 Pro build 26200, x64, i7-12700, 15.7 GB RAM). Source is checked out at `C:\Users\Admin\source\CastReader`, branch `codex/windows-parity`. About 211 GB remained free after installation.

Mac-to-PC Codex Remote now shows Connected. Mac diagnosis found its remote WebSocket bypassing the HTTP system proxy and a bad system DNS result for ChatGPT. A temporary sing-box TUN plus a scoped ChatGPT DNS resolver restored connectivity. The user's terminal keeps it active; Control+C restores the previous resolver/routing. No public app-server port was opened.

The current chat's shell targets Mac; commands on the PC run through verified Windows OpenSSH with a dedicated key. SSH starts automatically and its firewall rule is limited to the Mac's LAN address. The temporary bootstrap download server has been stopped. Codex CLI on the PC is installed and already authenticated through ChatGPT.

Reused Git 2.53.0, Node 24.13.1, npm 11.8.0, global pnpm 10.30.2 and Python 3.12.10. Installed VS Code, Chrome, Visual Studio 2022 Build Tools with MSVC and Windows SDK 10.0.26100.0, and Codex CLI 0.160.0. The project automatically selects pinned pnpm 10.25.0. A C++ program including Windows headers compiled, linked and ran as a 64-bit executable.

Source was cloned from the existing GitHub repository with sparse checkout; unpublished Windows commits were fetched through verified Git bundles over SSH. No Mac dependency directory or build products were copied. No branch was published. Locked Windows dependencies and the Electron 44.5.1 Windows runtime are downloaded. `scripts/setup-project.ps1` makes dependency installation repeatable, including the explicit proxy required for lazy Electron binary downloads. `scripts/verify-desktop.ps1` runs native checks in the logged-in Windows desktop and removes its temporary scheduled task afterward.

## Engineering verification

- Isolated branch `codex/windows-parity`, baseline `09456f1979cc14ca19977ede4b1edde043c5f840`.
- All 40 Mac reference feature groups and 145 reference scenarios inventoried. Mac reference passes are not Windows results.
- TypeScript and production renderer/main/preload builds passed on Mac and Windows.
- 18 core/contract tests passed on Mac and Windows: Unicode/source projection, ambiguous continuation rejection, late audio, paused buffering, queue limits, resume ownership, canonical account exchange, late sign-in/refresh, v2 entitlement authority, zero-attempt TTS retry rule, archive paths.
- 3 Chrome browser fixture tests passed on Mac and Windows: paste/play/pause/reopen and stable full text; file import/settings/theme/language/logout at 800×600; inert imported markup. The fixture audio is generated silence, not a real TTS pass.
- Real Windows Electron development and packaged executable checks passed: local protocol/renderer startup, native preload IPC, sandbox/context isolation, Windows encryption round trip, signed-out library denial, preferences persisted across process restart, screenshot and no renderer page errors. The tests use an isolated profile; no real account or synthesis is involved.
- NSIS EXE and ZIP candidates were built on the PC. Both are unsigned engineering artifacts. The packaged executable was launched and checked; installing/upgrading/uninstalling the NSIS package is still pending.
- `docs/environment-2026-10-05.json` records versions, source/lock/artifact hashes and results. Raw logs are at `C:\ProgramData\CastReader\DevelopmentSetup`; UI reports/screenshots are under `Windows\test-results` on the PC.
- All 145 product acceptance cases remain NOT_RUN. Real application login, real TTS, book providers and long-run acceptance have not passed. Environment readiness does not complete product parity.

See README for the limited first slice and known missing features. Full parity and final acceptance are not achieved.

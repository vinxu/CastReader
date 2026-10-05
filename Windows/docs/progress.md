# Windows progress — 2026-10-05

## Environment first (latest user priority)

The user explicitly requested that all necessary PC development tools be installed before proceeding with application development, and that source be obtained through Git. PC currently has no CastReader project or checkout.

Mac-to-PC Codex Remote now shows Connected. Mac diagnosis found its remote WebSocket bypassing the HTTP system proxy and a bad system DNS result for ChatGPT. A temporary sing-box TUN plus a scoped ChatGPT DNS resolver restored connectivity. The user's terminal keeps it active; Control+C restores the previous resolver/routing. No public app-server port was opened.

The current chat's shell still targets Mac, and project tools still contain no Windows project. A one-time administrator PowerShell bootstrap is served only to the known PC's LAN address. It installs Microsoft's Windows OpenSSH capability, configures a dedicated Mac public key, limits SSH firewall access to the Mac, and enables startup. PC fetched the script successfully. SSH readiness and PC installation results are still pending.

`scripts/provision-windows.ps1` is prepared but NOT executed on Windows. Next: verify SSH host/user/fingerprint, inventory disk/OS/tools, install Git/Node/pnpm/editor/MSVC/SDK as required, validate versions, clone the Git repository, install locked project dependencies, build, then execute native Windows tests.

## Local engineering verification

- Isolated branch `codex/windows-parity`, baseline `09456f1979cc14ca19977ede4b1edde043c5f840`.
- All 40 Mac reference feature groups and 145 reference scenarios inventoried. Mac reference passes are not Windows results.
- TypeScript and production renderer/main/preload builds passed on Mac.
- 18 core/contract tests passed on Mac: Unicode/source projection, ambiguous continuation rejection, late audio, paused buffering, queue limits, resume ownership, canonical account exchange, late sign-in/refresh, v2 entitlement authority, zero-attempt TTS retry rule, archive paths.
- 3 Chrome browser fixture tests passed on Mac: paste/play/pause/reopen and stable full text; file import/settings/theme/language/logout at 800×600; inert imported markup. The fixture audio is generated silence, not a real TTS pass.
- No Windows build, installer, native UI, real login, real TTS or provider acceptance has passed yet.

See README for the limited first slice and known missing features. Full parity and final acceptance are not achieved.

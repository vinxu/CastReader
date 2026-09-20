# iPad adaptation execution

User authorized the complete plan on 2026-09-21, with a simulator UI gate after each module and mandatory rotation support. No App Store submission is requested.

- Branch: `codex/ipad-adaptation`, independent managed worktree.
- Base: `8298f84` / application source `1ce1e56` (1.2.42 build 64).
- Required ancestor gate passed before edits.
- Primary simulator: iPad Air 11-inch (M3), iOS 26.5, `BFCF61DE-9C45-4467-8996-6F4E03AE7725`.
- DerivedData: `/tmp/CastReader-iPad-Adaptation`.

| Module | Status | Gate |
| --- | --- | --- |
| 1. Universal configuration, navigation and window geometry | Passed | `module1-live-ipad11-retry-20260921T053304`: navigation + 4 orientations + 14 screen captures; manually reviewed Home, Library, Voice, Settings, import |
| 2. Native readers, rotation, semantic position and marks | In progress | EPUB / text / PDF / photo / DOCX / web rotation UI tests |
| 3. Commercial readers, offline and YouTube | Pending | Platform fixtures + rotation and restore tests |
| 4. All surfaces, import, voice, account and presentations | Pending | UI workflows and keyboard/sheet validation |
| 5. Playback ownership and multiple windows | Pending | Ownership and lifecycle tests + multiple scene UI |
| 6. Input, accessibility, performance, upgrade and regression | Pending | iPad sizes + iPhone regression + release resource audit |

Passing simulator fixtures is evidence of UI and deterministic behavior only. Live commercial accounts, actual purchase authorization, hardware camera/Pencil/audio routes and production audio require separate evidence; never report these as passed from fixture screenshots.

## Execution notes

- User completed CastReader sign-in and Kindle binding on the 11-inch simulator. Preserve its app and keychain data.
- User requested a single simulator. The temporary 13-inch simulator was shut down; all subsequent verification uses the existing 11-inch simulator. The cancelled 13-inch run is not a pass.
- Screen captures use `XCUIScreen.main.screenshot()`; `app.screenshot()` cropped landscape captures on this runtime.
- The first real-account navigation run was interrupted by the system review dialog. The test now dismisses “Not Now” without submitting a rating. The rerun passed.
- The reviewed Home includes the actual Kindle shelf and saved listening entry. Production Read/Explain verification remains in module 3.
- Test reports and account screenshots stay local and are excluded from source control.

# Duo surface adaptation — 2026-10-11

Scope: SwiftUI surfaces outside `MainTabView`, `AdaptiveLayout`, and reader/Kindle core. Apple’s exported `app-resizability` idiom and safe-area checklists reviewed before editing. All layout decisions use local environment size classes or the current geometry; no cached traits, global screens, new playback owners, or navigation resets.

## File coverage and pre-edit decisions

| File | Change | State |
| --- | --- | --- |
| `Views/Home/HomeView.swift` | Regular-width page cap and quick-import toolbar; keep existing source order and sheets | Implemented; device acceptance pending |
| `Views/Settings/VoiceBrowserView.swift` | Local regular-width cap/hit targets; panel honors its own safe area and keyboard exactly once | Implemented; device acceptance pending |
| `Views/Settings/VoiceDiscoveryView.swift` | Regular-width collection cap; shared allowance sheet integration | Implemented; device acceptance pending |
| `Views/Player/MiniPlayerView.swift` | Title, play and close hit targets are44pt at every width; compact bar56→60pt, same session identity | Implemented; real WeRead/Google fold acceptance passed |
| `Views/Auth/LoginView.swift` | Local-size scroll form in all branches, preserve compact-height spacing | Implemented; keyboard regression fixed, repeat device acceptance pending |
| `Views/Paywall/PaywallView.swift` | Local regular-width close target and content cap | Implemented; device acceptance pending |
| `Views/Kobo/KoboLibraryViews.swift` | Local regular-width home and library controls | Implemented; device acceptance pending |
| `Views/GoogleBooks/GoogleBooksLibraryViews.swift` | Local regular-width home and library controls | Implemented; device acceptance pending |
| `Views/WeRead/WeReadLibraryViews.swift` | Local regular-width home and library controls | Implemented; device acceptance pending |
| `Views/YouTube/YouTubeListenView.swift` | Geometry-led wide layout; local regular-width artwork/text cap | Implemented; device acceptance pending |
| `Views/YouTube/YouTubeCaptionLanguagePanel.swift` | Remove inset duplication; clamp panel to current available size | Implemented; device acceptance pending |
| `Views/Settings/SettingsView.swift` | New-window action follows existing `supportsMultipleWindows` capability | Implemented; device acceptance pending |
| `Services/CloneCreditStore.swift` | Selectively port confirmed-total exhaustion predicate from `f4bb046` | Implemented; device acceptance pending |
| `Views/Paywall/CloneCreditPurchaseView.swift` | Selectively port compact purchase sheet from `f4bb046` | Implemented; device acceptance pending |
| `Views/Settings/VoiceGenerationQuotaSummary.swift` | Route summary to shared purchase sheet | Implemented; device acceptance pending |
| `CastReaderTests/CloneCreditPurchaseTests.swift` | Port five-case confirmed-total exhaustion regression | Implemented; device acceptance pending |

Other audited import, phone sign-in, cloud-storage, extraction, voice-creation, and library-connect surfaces contain no targeted layout idiom/screen issue. Their full-bleed backgrounds, scrims, and decorative glow intentionally ignore safe areas and remain unchanged. Web content ignoring only the bottom edge is not changed in this scope. Existing feature/region/account checks, account gate, private voice eligibility, and StoreKit transaction logic remain unchanged.

The playback voice panel stays an overlay: presenting a sheet there would resize the underlying live Kindle surface. Its own normal safe area and keyboard avoidance provide the available geometry; the nested browser must not subtract keyboard space again. The scene owner handles removal of the now-unused `WindowKeyboardInsetReader` helper atomically with the consumer change.

## Acceptance to run on integrated candidate

- Build with Xcode 27.1, then run existing clone-credit balance regressions and purchase-account-boundary tests.
- Duo outer/inner and rotation: Home, quick import, library, Settings, login, paywall, voice browse and playback voice panel remain reachable; retained navigation and selected voice do not reset.
- Open voice search with software keyboard, fold/unfold, dismiss keyboard, reopen panel. Verify one keyboard clearance and no underlying reader restart/reprojection caused solely by opening/closing the overlay.
- Check English, Arabic/Hebrew RTL, Korean single-voice catalog, and large Dynamic Type. Use existing language/voice tests instead of regenerating all live audio for unchanged service paths.
- Verify allowance sheet: monthly zero plus purchased 38 min shows 38 min; unknown total shows syncing; confirmed total zero shows exhausted; close, rules and sync controls reachable in narrow/short layouts. No real purchase is needed for layout acceptance.

No build, UI action, network mutation, TTS generation, or StoreKit purchase performed by this surface-edit task.

## Static verification

- `git diff --check` passed.
- All 12 assigned surface files have nonempty diffs; no remaining `AdaptiveLayout.isPad`, `UIScreen.main`, or manual `safeAreaInsets` reads in those files.
- SwiftUI environments are read at point of use, so window-size changes invalidate layout without a stored trait. Existing condition branches and navigation/session identities are retained. New-window availability now keeps the existing system capability check and removes only the device assumption.
- The quota integration is limited to the five shared files from `f4bb046`; no Mac project settings or other Mac release changes were imported. All 19 directly localized strings in the resulting purchase view have 28 translated catalog entries.
- No new file was added to an Xcode target; the tracking document requires no project registration.
- Build and runtime acceptance are intentionally deferred to the parent task’s single integrated candidate.
- Scene-agent peer review found no source blocker in either overlay: each now uses its own normal safe area, only the scrim is full bleed, bounds are clamped, and the request/navigation identity is unchanged. Keyboard acceptance must additionally confirm that a first responder in the overlay does not shrink the persistent WK reader. If it does, isolate keyboard avoidance at the reader surface; do not restore cached screen-frame calculations.

## Keyboard and recording failure review

- The first `AccountProAndCloudFormsRotate` run found a real login layout regression: a compact-width, regular-height sheet used a plain `VStack`. Its AX tree contained no scroll view; the Send code frame was y=416.5–463 while the keyboard input container began at y=398. The compact branch now uses `AdaptiveFormScroll`, preserving its existing header, spacers, form state, consent flow, and button actions. `login.form` identifies the form; the existing button remains `login.sendCode`. Peer review found no blocker. Source check passed; rerun remains pending.
- Targeted keyboard acceptance: expand email sign-in, enter the non-sensitive fixture address, retain the software keyboard while rotating in both directions, scroll inside `login.form`, and verify the whole Send code button is visible above the keyboard with the email retained. Do not send a code. This checks the product defect rather than treating a missing `scrollViews.firstMatch` as only a selector error.
- The recording failure ended with the clipboard import prompt above the voice page, not the recording sheet. Evidence is preserved in `reports/ios-duo-20261011/ipad-panels-failures/recording-end-hierarchy.txt`. The microphone permission return can trigger `MainTabView`'s unconditional foreground clipboard check, which can present a second sheet while creation is active. The scene owner is reviewing its existing modal eligibility probe to prevent takeover before consuming clipboard metadata. Notification permission is an additional environmental interruption; neither clearing the clipboard nor dismissing product prompts in the test is sufficient to establish a product fix.

## Final coverage checkpoint — 2026-10-12

The integrated final read-only audit found all16 listed files covered and no new source blocker. The historical pending entries above record the original pre-integration state, not new release requirements. The login keyboard rerun, clipboard/modal fix, and integrated layout results are recorded in [the scene audit](duo-scene-audit-2026-10-11.md) and [the current acceptance report](iPhone-Duo-Adaptation-2026-10-11.md). Mini-player title/play/close44pt checks passed in genuine WeRead and Google fold tests. Duo-specific public uppercase keyboard smoke and remaining release/account gates must still be completed by the parent task.

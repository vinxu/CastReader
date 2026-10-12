# Duo scene, navigation and safe-area audit — 2026-10-11

Scope: the existing `codex/ios-duo-adaptation` checkout, incrementally based on the verified iOS release. This report covers the scene/navigation subtask only. It does not certify a build, simulator run, real-device run or App Store submission.

## Prerequisites (read-only)

- `CastReader/Info.plist` supplies no conflicting launch, orientation or full-screen keys.
- Both app configurations in `project.pbxproj` set `INFOPLIST_KEY_UILaunchScreen_Generation = YES`.
- Both app configurations list portrait, upside-down portrait, landscape-left and landscape-right for iPad. The phone declaration retains portrait and both landscapes.
- `UIRequiresFullScreen` and `UIRequiresFullScreenIgnoredStartingWithVersion` are absent from the app plist, project and the referenced `Secrets.xcconfig`; no prerequisite keys were edited. The configuration contains no include overriding these keys.
- The app already uses SwiftUI `App` / `WindowGroup`, generated scene manifest, per-window `RouteReadyRoot` and `@StateObject ReaderSceneContext`. No UIKit AppDelegate-to-SceneDelegate conversion is required. The delegate owns URL fallback, discarded-session bookkeeping and the existing orientation policy, not window creation.

## File coverage

| File / target | Outcome |
| --- | --- |
| `Views/MainTabView.swift` | iOS 18+ uses one stable `TabView` with all four persistent page identities. Horizontal size class changes only native/custom navigation chrome. Compact UI retains Home / import / Voice controls. Mini player and custom bar share a bottom safe-area inset; the window-inset offset was removed. Existing `ReaderHostView`, Kindle and offline surface nodes remain outside navigation and keep their render IDs. `selectedTab` is never reset on size changes. |
| `Utils/AdaptiveLayout.swift` | Removed the global `isPad` layout helper; narrow playback stacking depends on current width. Form width reads the local SwiftUI environment. The settings presentation uses one popover modifier with system compact-sheet adaptation, so changing size class cannot replace its presenting view. Deleted the obsolete notification-frame keyboard measurement after its consumer migrated. |
| `Utils/AdaptiveLayout.swift` — header controls | Kept the existing local UIKit-to-SwiftUI corner-inset bridge; removed the device gate and added `safeAreaInsetsDidChange` invalidation. Each layout independently reads leading and trailing corner-adapted safe-area values. |
| `Services/ReaderSceneContext.swift` | Audited, unchanged: already owns UI state per mounted window, uses a local window probe, differentiates disconnect from background, and retains/migrates an existing playback model. Debug fixture orientation output is telemetry, not layout. |
| `Services/CloudStorageCenter.swift` | Detection false positive, unchanged: line 13 mentions `UIApplicationDelegate` only in documentation for `CloudOAuthCallbackDeduplicator`. The class is a main-actor callback deduplicator, not an app delegate, and creates no windows or lifecycle observers. The shared `handleOAuthRedirect` entry documents duplicate delivery from the existing app-delegate fallback and SwiftUI scene `onOpenURL`; it correctly admits one SDK callback per OAuth attempt. No scene-lifecycle migration applies. |
| `ViewModels/PlayerCoordinator.swift` | Preserved rotation-lock decisions. Their genuine idiom reads now come from the coordinator's own scene window, rather than the removed process-wide layout helper. |
| `CastReaderApp.swift` / `AppOrientationLock` | Kept existing orientation masks and global lock behavior; these are outside automatic layout replacement. Added the skill's actionable migration note for a coordinated, availability-gated `prefersInterfaceOrientationLocked` change. Neither old masks nor a future lock can be used to prevent fold resizing. |
| `Utils/ReaderWindowKeyboard.swift` | Removed the iPad-only restriction. Actual key-window focus, active text input and presented-controller guards determine eligibility. New-window command registration uses SwiftUI `supportsMultipleWindows`. |
| `Utils/ReaderDropImport.swift` | Registers supported drop types for the receiving surface regardless of device idiom. Existing modal, voice-panel, account-boundary, staging and confirmation safeguards are unchanged. |
| `Views/Reader/ReaderMoreButton.swift` | Button width and appearance-sheet detents use the local horizontal size class. |
| `CastReaderTests/ReaderViewportTests.swift` | Added an actual UIKit-window test proving shortcuts yield to an editing text field and a presented panel, and resume after dismissal. |
| `CastReaderUITests/iPadAdaptationUITests.swift` | Added an opt-in by test selection iPad 26+ window-resize regression using the DEBUG legacy navigation route. It selects Library and Settings separately, resizes to compact width and checks that the selected destination remains present. This exercises the iOS 17 navigation structure without redesigning the old-OS UI. |

## Checklist and bounded exceptions

- Width/layout choices read the actual view environment; the environment updates continuously without cached device decisions.
- Reader and playback owners are unchanged; no size-driven `.id`, replacement coordinator, navigation-selection reset or new audio request was added.
- The fixed tab identities also include Library and Settings in compact width, so a fold cannot select a nonexistent tag. The visible compact navigation still follows the existing three-control product design.
- Native presentation uses one stable modifier and existing iOS 17.6-compatible APIs. Native adaptive tabs are guarded at iOS 18; the older navigation fallback remains available.
- Legacy compatibility follow-up: iOS 17.6 keeps its original navigation owner and tab set across size-class changes. The iPad `NavigationSplitView` collapses internally without being replaced by a phone `TabView`; Library/Settings selection therefore remains valid. This compatibility-only idiom check prefers the attached scene window and retains the original device fallback before attachment. It does not drive the iOS 18+ layout. The DEBUG legacy-sidebar route also retains its mini player. On an old-OS phone, keyboard actions do not register Library/Settings tab IDs absent from its original three-tab set.
- Safe-area placement uses system layout rather than root-window inset arithmetic. Background scrims remain full bleed.
- Header inset bridge exception: its two SwiftUI `@State` values are a live measurement bridge, not a one-time inset cache. Replacing it with a different hosting hierarchy would risk losing the already validated iPad window-control exclusion. The parent accepted retaining this bridge for the bounded release, with per-layout reads plus safe-area invalidation. Do not describe this as strict compliance with the skill's blanket no-stored-inset rule.
- Orientation policy exception: `AppOrientationLock` still contains hardware orientation-mask logic and a global lock registry. No layout decision substitutes an orientation enum for size. A wider orientation-policy rewrite is explicitly deferred, and fold acceptance must verify that rendering recovers when the OS resizes despite the legacy lock.
- Process-level analytics/auth/catalog notification observers remain process-level. Actual UI routing and bookmarks already consume per-view `scenePhase`; moving shared-service refreshes into every window would duplicate side effects.

## Validation status and next checks

Source-only `git diff --check` passed at handoff. No build or test was run by this subtask. Peer review of the navigation and presentation changes found no source-level identity blocker; runtime checks remain required.

Prioritize these checks after the parent finishes the common build:

1. On Duo, open Home/Voice and a Library or Settings route; fold and unfold without changing the selected page, entered search, or navigation path. Verify compact 0/1/2 controls against persistent 0/3/2/4 page identities and RTL reversal.
2. During active Read and Explain, fold both ways, minimize/expand, open voice selection and reader settings. Confirm the same session/VM/WK object, audio clock, paragraph, marks and intended paused state survive.
3. Verify last rows remain reachable with no player, with each mini-player variant, and with compact/regular navigation. The existing inner-scroll `BottomOverlayMetrics` still measures actual overlap; ensure native TabView safe-area propagation does not introduce excessive bottom reservation.
4. Focus voice search and import text with a docked keyboard; fold while typing. Confirm the overlay clears the keyboard and the reader's stable surface does not acquire an unintended extra inset. The panel consumer no longer subtracts safe-area/keyboard frames manually.
5. Confirm the iPad window-control region, asymmetric left/right safe areas, Arabic/Hebrew UI, short windows, and ordinary iPhone portrait/landscape. Settings popover-to-sheet adaptation must remain usable.
6. Run the new keyboard eligibility test, existing `ReaderViewportTests`, `ReadingResumeTests.testNewViewModelGetsFreshRenderIdentityButMiniPlayerKeepsCurrentInstance`, window migration/bookmark tests, and affected iPad navigation/popover/keyboard UI tests. Use actual Duo folding for the new transition; rotation tests alone do not establish fold acceptance.

Do not regenerate 28-language audio to validate these source-only layout changes. Real service release gates remain the parent task's separate responsibility.

## Follow-up: legacy compact-window launch failure

Read-only investigation of `reports/ios-duo-20261011/ipad-layout-after-devicehub.xcresult` exported the failing legacy test's attachments to `reports/ios-duo-20261011/legacy-scene-failure/`. The `home-readiness-failure` screenshot (`66F6D710-85F6-440F-8C9E-C4EBF3B12FED.png`) and application hierarchy (`412A1085-790A-4C77-AC80-AC34390BD380.txt`) show a loaded, signed-in Home surface in a restored **375 × 486 point** floating window. This was not an authentication failure or an app-launch failure. The test stopped at `home()`'s import-button readiness assertion before attempting the intended Library/Settings resize sequence.

Two issues were found and fixed:

1. Test setup waited for width-dependent Home chrome before normalizing the restored window. `home()` and `scenario()` now share full-screen preparation: wait for a visible window with finite coordinates, restore its size using the existing title-bar double tap if needed, and verify both dimensions against the display reported by SpringBoard. Reader fixtures also wait for a hittable reading target. The existing PDF playback, manual zoom, page-position and rotation assertions are unchanged. The legacy resize test restores full screen after each case and in teardown, so a failed test does not leave the next test in a floating window.
2. The new width-only Home toolbar condition hid the import button in a legacy compact `NavigationSplitView`, where no phone bottom bar exists. `MainTabView` now communicates whether its navigation actually provides a bottom import control through `hasBottomImportControl`. `HomeView` shows its existing toolbar import action whenever that control is absent. This preserves one import entry on modern compact navigation and restores the entry in legacy compact windows, without a new device/width guess. The legacy regression now also visits Home after resizing and requires its import action to be hittable.

The related reader-test failure investigation independently found a restored 375 × 486 viewport and invalid accessibility frames while the system window-controls menu was covering the fixture. This supports preparing the window and checking hit targets, rather than weakening the playback or rotation acceptance conditions.

`CloudStorageCenter.swift`'s `UIApplicationDelegate` comment was also accounted for explicitly in the coverage table. No Cloud OAuth implementation change was needed.

Validation at this handoff: source diff checks pass; this subtask did not start builds, launch a simulator, or run UI tests. The parent must rerun the focused tests using a newly compiled candidate.

## Follow-up: foreground activation must not replace a modal

The recording test's final hierarchy (`reports/ios-duo-20261011/ipad-panels-failures/recording-end-hierarchy.txt`) shows a clipboard-import prompt above Voice, with no recording controls remaining. The log records accepting the microphone permission immediately before this state. `scenePhase.active` previously invoked `clipboard.check()` even while the scene's root had a presented controller; the check immediately updates persistent pasteboard `changeCount` and drives another sheet.

The foreground path now requires the existing scene-local `hasBlockingSystemPresentation` probe to be clear before checking the clipboard. It neither dismisses a current modal nor consumes the pasteboard change while blocked; a later ordinary foreground entry can still detect that content. This is deliberately limited to the automatic foreground path. The explicit post-onboarding clipboard action remains unchanged.

The recording UI test accepts only an alert mentioning microphone, checks that the recording controls remain present and no clipboard prompt appears after authorization, and repeats the assertion across a real background/foreground transition. The login-form test uses the surface team's `login.form` identifier to scroll the actual form and requires the entire Send code button to remain above a visible docked keyboard in both orientations. It never presses Send code. Its keyboard measurement rejects stale rotated child accessibility frames and uses the keyboard's correctly oriented `inputView` host when present. These assertions are pending the parent's common build and runtime rerun.

## Follow-up: full-screen test preparation coordinate axes

In the parent's `ipad-layout-fixed.xcresult` rerun, `testAccountProAndCloudFormsRotate` passed. The legacy test successfully selected Library and retained its destination after resizing to 375 × 486; it then failed during the first iteration's cleanup before Settings/Home ran. Exported evidence is under `reports/ios-duo-20261011/legacy-restoration-failure/`. The first preparation-failure screenshot (`F98B46C4-043C-4569-BC53-F810D4233189.png`) already shows a full-screen landscape Library. The cleanup log also reads that window as 1180 × 820, then unnecessarily double-taps it a second time. The second failure screenshot (`6B100149-BB29-4BAD-A2E8-609D252B40E9.png`) shows that second gesture shrinking it back to a floating window.

Only the test's full-screen predicate was changed: it now compares the window's long and short dimensions with the display's long and short dimensions, requires both dimensions to match within two points, and requires a finite origin at the screen origin. This accounts for SpringBoard exposing portrait axes while the app is in landscape. It does not weaken the separate `rotate()` window-direction assertion or alter product behavior. PDF had already passed reading start, pause, pinch and manual scrolling before its subsequent rotation readiness failure; the later reader/recording rotation failures must be rerun after preventing the erroneous cleanup gesture.

## Follow-up: genuine Duo duplicate navigation after folding

The user's folded-Duo screenshot (`codex-clipboard-823bfe9f-9b88-4401-aecf-b8ccb92fb639.png`) shows both the system's four-tab navigation and the custom three-control navigation. This is a real product defect, distinct from the XCTest coordinate issue above. The source had competing toolbar preferences: the modern compact `TabView` requested `.hidden`, while the outer `mainContent` requested `.visible` whenever main chrome was not suppressed. The retained `KindleBookView` also published `.visible` while minimized, matching the active Kindle mini-player in the user's screenshot.

`nativeTabBarVisibility` now supplies one policy on each persistent tab page (including the legacy import placeholder). Suppressed chrome always hides the native bar; iOS 17 retains its original visible native three-tab bar; the modern compact shell hides native navigation while providing the custom bar; regular width delegates to the system with `.automatic`. The conflicting outer toolbar preferences were removed. The reader subtask also removed Kindle's redundant toolbar preference while preserving its existing lifecycle updates to `hideMainChrome`. The stable `TabView`, its four modern tags, selection storage, and reader siblings remain unchanged. The custom UIKit tab bar now exposes `compactNavigationBar` for direct acceptance inspection.

The added iPad window-resize regression checks that the Voice selection survives, exactly one Home navigation action is hittable at compact width, native Library/Settings actions are hidden, import still opens, and regular navigation returns after expanding. This is supporting size-class coverage; the parent's actual Duo fold/unfold capture remains required to verify the reported device transition. The reader subtask separately owns the orientation-lock and oversized-playback-control findings in the same screenshot.

## Follow-up: iPadOS restores a floating window on rotation

The parent's `fold-fixes.xcresult` run passed the new modern compact single-navigation test, PDF manual zoom/position rotation, and reader popover/voice-panel rotation. Legacy failed at `rotate()` (line 80 in that candidate), not at `restoreFullScreenWindow()`: initial setup read a full-screen 820 × 1180 window, but the first rotation to landscape restored a 375 × 486 floating Home window before the test selected Library or performed its own resize gesture. The screenshot extracted at second 16 from the failure recording (`reports/ios-duo-20261011/legacy-rotation-failure/at16.png`) shows the system and app content both oriented correctly inside that floating window. Teardown's existing double tap then successfully restored full screen.

The bounded test fix calls the same full-screen preparation immediately after setting the device orientation, then retains the original actual-window direction assertion. No timeout is extended and no product change is made. This corrects the full-screen precondition when iPadOS restores a saved window size for the newly selected orientation. A genuinely orientation-locked full-screen app still fails the direction assertion, because the dimension-normalized full-screen check does not reorient it. This final helper adjustment is pending the parent's next focused rerun.

## Follow-up: Settings selection remains, lower Form rows are virtualized

`legacy-fold-final.xcresult` passed the window/rotation preparation and the Library compact case, then failed to find `settingsLanguageLink` after shrinking Settings. The final hierarchy (`reports/ios-duo-20261011/legacy-settings-failure/82C4082D-442D-4C81-AAF8-ECB73AF6FFB3.txt`) explicitly retains a `Settings` navigation bar and its Account/Pro form in a 375 × 486 window. The recording's second-58 frame (`at58.png` in the same directory) confirms Settings remains the current page. Its Language row follows Account, Pro, Offline Downloads, and New Window; the shortened native Form no longer exposes that offscreen row in its collection-view accessibility subtree.

No product navigation change was justified. The regression now first asserts the retained Settings navigation bar, scrolls its actual collection view to Language, and keeps the original language-destination existence assertion with an additional hittability assertion. It still fails if resizing changes the selected page or makes the intended settings action unreachable. The test's timeout and compact-width requirements remain unchanged. This adjustment requires one focused parent rerun.


## Follow-up: opt-in real Duo stages for three live platforms

`PlatformLiveIPadAcceptanceUITests` now supports `CASTREADER_PLATFORM_DEVICE=duo`. In this mode it does not execute the iPad title-bar double tap for windows narrower than 700 points, and it does not use iPad window-aspect assertions as a substitute for folding. Its screenshot attachments enumerate `XCUIScreen.screens` and retain every exposed display, with the index/count recorded; this avoids using the main-screen image alone when that is the inactive Duo panel. The normal iPad path and its rotation assertions remain unchanged.

The compact reader header's real mode menu is supported alongside the existing segmented picker. Existing session, speaking-source/forward-clock, highlight, paused-time and Explain-mark assertions remain in force. The three live verification entrypoints are:

- `PlatformLiveIPadAcceptanceUITests/testWeReadReadExplainRotation`
- `PlatformLiveIPadAcceptanceUITests/testKoboReadExplainRotation`
- `PlatformLiveIPadAcceptanceUITests/testGoogleBooksBodyReadExplainRotation` (or the current-position `testGoogleBooksReadExplainRotation`)

For actual Duo coverage, also set `CASTREADER_PLATFORM_FOLD_CONTROL` to an absolute, writable directory visible to the test runner and controlling host; set the existing `CASTREADER_PLATFORM_LIVE_ACCEPTANCE=1`. Start the device in **Open** mode. Each stage atomically replaces `request.json` with a fresh UUID `requestID`, `schema: 1`, `test`, `platform`, `phase`, `target`, time, before-window dimensions and current playback metrics. The controller operates the real Device Hub **Closed/Open** control through UI, then atomically writes `ack.json` containing the exact request ID, matching target and `completed: true`. For example:

```json
{"requestID":"COPY-THE-CURRENT-REQUEST-UUID","target":"closed","completed":true}
```

The test waits at most 180 seconds for that unique acknowledgment, then requires the actual window dimensions to change and captures all reported displays. It neither resizes a simulated view nor writes reader/account/library state. A stale acknowledgment cannot release a later stage. The requested sequence for each platform is:

1. `phase=read-playing`, `target=closed`; verify continued speech, same reading VM, forward source/clock and visible word highlight.
2. `phase=read-playing`, `target=open`; repeat the same invariants.
3. `phase=explain-paused-minimized`, `target=closed`; the test then expands the real mini-player and requires the same explanation VM, exact mark IDs, paused clock and visible ink.
4. `phase=explain-paused-expanded`, `target=open`; verify the same paused explanation and ink again, then continue the existing manual-page test.

Duo Read/Explain geometry tests explicitly skip if the fold-control directory is not configured, rather than silently reporting rotation/no-op behavior as fold acceptance. Other live tests can use Duo mode for diagnostics without a handshake. If a run fails while Closed, the controller must restore Open before the next test. This is a bounded acceptance hook only; the parent's live run must still establish actual platform and cloud-service behavior. No build, UI or test run was performed by this subtask.

Final source review of the Kindle cancellation follow-up found the reported old-key fallthrough addressed: native-key restoration and stability observation check task cancellation, navigation generation and mode across awaits; the final read/explain refocus checks its original VM before a subsequent forced visual operation. Reader-owned real WK cancellation tests cover the pending visibility and anchor-reply paths. Their runtime result is left to the parent common build.

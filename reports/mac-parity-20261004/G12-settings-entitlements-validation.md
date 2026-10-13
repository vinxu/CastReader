# G12 Settings and entitlement acceptance

2026-10-05. IN_PROGRESS. International Mac candidate; isolated Mac/iPad regression hosts are separate from the signed-in app.

## Actual baseline findings

- Current signed-in account displays CastReader Pro / Monthly Subscription. No China region or internal debug sections are present in the Release settings.
- Scrollable compact Settings reaches playback, voice, explanation, highlight color, support, version and data controls. Clear All History presents the irreversible-action warning; Escape cancels. No records were deleted.
- The six color swatches are visually present but expose only one unnamed accessibility element. They use tap gestures rather than buttons.
- Quick Import's compact navigation Cancel text is visually truncated to C….
- Source inspection confirms feedback subject still says CastReader iOS Feedback on Mac.
- Cold starts earlier in this run briefly show the generic upgrade card before the existing paid account's server response arrives. An unresolved account should not be presented as an authoritative free result.

## Candidate changes

- Color choices become six named buttons with a selected trait and 44-point hit area, preserving the six original colors and overall row width. Six color names have all nine interface translations.
- Mac feedback uses a Mac subject; the iOS subject remains unchanged.
- Quick Import and Settings reuse the compact Mac dismissal button with Escape support.
- ProManager separately publishes whether a valid current-account server response has settled entitlement presentation. Home upgrade promotion and Settings free-quota copy wait for that result. Access and quota enforcement still use the existing server-authoritative isPro rules. Stale/mismatched responses cannot settle presentation; account changes reset it, while transient refresh failures preserve a prior valid result. Existing nine-language syncing text is reused.
- Three lifecycle regressions cover unresolved startup, later network failure, current paid response, account clearing with a late old response, and principal mismatch.

## Pending

Normal candidate UI replay, dual-platform regression, settings persistence/languages, actual StoreKit availability and clone credit UI remain to be checked. Test transactions are confined to private test applications and Configuration.storekit; no real purchase, cancellation, account deletion or sign-out is authorized by these test results.

## First regression results and StoreKit environment investigation

The complete current-source snapshot built in both private hosts. Seven selected classes executed 99 cases each: Mac 96 PASS / 0 FAIL / 3 purchase SKIP; iPad on iOS 26.5 92 PASS / 4 FAIL / 3 purchase SKIP. The four failing cases require a local StoreKit product; the simulator reports SKInternalErrorDomain Code=3 while saving the configuration and returns zero products. A serial PaymentTests rerun retains the same failure. No failing case was changed to a skip. All 16 server-entitlement synchronization cases (including the three new lifecycle tests), 19 growth, 5 quota, 3 environment, 3 entitlement-pause and 18 appearance cases passed on both platforms.

Apple's [SKTestSession documentation](https://developer.apple.com/documentation/storekittest/sktestsession) advises serial configuration changes. The matching [Apple developer forum report](https://developer.apple.com/forums/thread/826971) contains a DTS acknowledgement and discussion of iOS 26.5 CLI configuration failures; it supports investigating an environment problem, not automatically attributing every local failure to Apple. A task-owned iPad simulator on the already installed iOS 26.2 runtime is being used as a controlled comparison. Its ID is F4B84DFB-D1B8-4689-A133-F948A8EBB6C5.

An initial iPad launch was interrupted before the final recorded run to remove the unrelated UI-test target from the unit-only manifest. Final reports use ios-tests2, not that interrupted bundle.

### iOS 26.2 controlled comparison

The same product-loading, trial-offer and signed-out purchase-gate cases pass on iOS 26.2, supporting an iOS 26.5 test-runtime limitation for the initial zero-product failures. Three actual transaction tests now run instead of skipping and expose stale test setup: they seed a transaction while signed out (the current restore contract requires an account), then read currentEntitlements before StoreKit has published the new receipt. The helper now uses the existing synthetic sign-in helper without any provider credential/production bearer, and waits up to 60 × 50ms for a real verified entitlement. No production purchase or entitlement rule changed. The cross-platform entitlement assertion also explicitly confirms a local receipt alone does not grant server Pro. These amended integration cases are being rerun.

### Actual settings candidate observations

Cold launch showed Syncing Pro status, then correctly switched to Monthly Subscription; the early Home snapshot had no upgrade promotion. The six named colors expose selection independently and selecting Blue/Green updates the selected trait without moving the settings scroll position. English explanation and Deep depth persist after closing and reopening the sheet. Playback switches changed to off through actual checkbox actions. Dragging the slider set 1.25 in its real model, but the old %.2g label rendered 1.2x; the candidate now uses exact quarter-step text and a localized accessible slider label. A programmatic AX slider set changed the native thumb without dispatching the bound value; actual pointer drag was used for the accepted result.

### Final local transaction comparison

The corrected iOS 26.2 PaymentTests suite is 35 PASS / 0 FAIL / 0 SKIP (`/tmp/g12-ios26-2-payment-final.xcresult`). Together with the 64 non-Payment cases in `/tmp/g12-ios26-2-final.xcresult`, current non-overlapping coverage is 99 PASS. This is an aggregation across two bundles, not a single all-green 99-test run. Earlier bundles and failures are retained.

Restore coverage specifically tests a synthetic profile with no valid CMS session: account/session revalidation clears the unbound local account snapshots, while the verified StoreKit transaction remains in currentEntitlements. It does not prove a successful authenticated production restore. Mac's three unavailable StoreKit transaction helper cases remain SKIP, with 96 PASS and no failure; iOS-only error injection is compile-guarded without changing the production purchase path.

### Live preferences and localization

- Speed 1.25x, Auto-play off, Auto-scroll off, English explanation, Deep depth and Blue highlighting survived a complete process exit and relaunch. Opening the cloud sample with Auto-play off remained paused.
- Explicit playback logged actual rate 1.25 and displayed the final word in Blue. The retained cursor was near the end, so this is a brief settings-effect check, not a long-read result.
- All nine interface language choices were exercised, including Hindi, and Follow System restored. Source and compiled localization audits agree for 63 added/reused values. The settings title now resolves from the current app language; Chinese Settings/Language/back title were observed together in the normal build.
- Both Settings and the ReaderHost speed labels use exact quarter-step values instead of the two-significant-digit formatting that displayed 1.25 as 1.2.
- Normal Debug build4 and strict deep signature validation passed. Six named color buttons support Tab entry, Left/Right focus, Space/Return activation, and Down to leave the row. Yellow was selected by keyboard, then Orange restored by keyboard. Catalyst groups the row for directional navigation; repeated Tab within the row did not advance, so Tab-only traversal is not claimed.
- Quick Import's complete xmark dismissal control is visible and Escape closes the sheet; the old C… truncation is gone.
- Restored preferences: Follow System, 1x, Auto-play on, Auto-scroll on, Match Source, Standard depth, Orange.

Remaining at that checkpoint (subsequent results below): reader label replay, small-window settings, universal Release, authenticated purchase/restore and clone-credit UI. No live payment or destructive data operation has been performed.

### Follow-up live acceptance

The updated reader displayed 1.25x both in the speed selector and playback bar; selecting 1x restored the original preference. An 800×600-point main window retained the 470×400-point settings sheet, which scrolled through all controls to Clear All History. The Pro page also scrolled to its complete legal links and restore control.

A real Restore Purchases action was executed in the signed-in normal Mac build. It eventually returned the app's “Pro restored” alert and re-enabled the control; current account Pro remained active. This is a successful current-account restore UI/revalidation result. Since this account already had server Pro before the action, it does not establish that an Apple receipt independently granted entitlement. No purchase was made.

### Universal Release checkpoint

Release build succeeded with arm64 and x86_64, macOS minimum 14.6; strict deep signature verification passed. The normal Release launched with the existing account and displayed Monthly Subscription. Keyboard Yellow selection and restoring Orange were repeated successfully in Release. Fixture exclusion scanned 107 files / 54 markers with zero matches and a passing Debug positive control. Binary identity is recorded in `g12-settings/release-static.json`; it is still a development-signed candidate, not a distributed/notarized release.

During first foreground activation after cold launch, Settings returned to the top once; subsequent interaction stayed stable. This remains a final UI-gate observation to isolate, rather than being silently counted as a pass.


### Clone-credit local integration: iPad pass / Mac blocked

Nine opt-in CloneCreditPurchaseTests passed on the task-owned iPad iOS 26.2 simulator (`/tmp/g12-ios-credit-pinned.xcresult`); summary frozen in `g12-settings/ios-clone-credit-summary.json`. This separate selection covers cancellation, Ask to Buy, positive/zero balance purchases, repeated delivery, another-account rejection, expired Pro, exhausted-credit waiting/cancel, delivery retry/lost acknowledgement, one-second fixture audio/replay and failed generation releasing a reservation. The SSH/live generated-audio case was excluded, not counted as a pass.

The test backend at 127.0.0.1:55446 and disposable PostgreSQL at 127.0.0.1:55447 exercised the existing production credit handlers/ledger against synthetic owners. It pinned this simulator's public Xcode certificate (SHA256 2E:99:DB:A3:C9:82:6C:A1:CC:B0:07:8F:0C:72:CE:96:4F:28:64:56:8B:86:28:87:81:F2:5E:A5:81:C9:90:30), verified the ES256 chain/JWS, required the private test bundle, then normalized the bundle/environment only for the disposable database. Earlier runs with the historical and Mac certificates correctly failed verification; those failures are retained. Dynamic public-certificate capture was removed before the accepted run. Production certificate validation and purchase rules were unchanged. The local server and database were stopped after testing; no real purchase, production ledger write or upstream voice-worker request was made.

Mac's fresh isolated identity encountered ASDErrorDomain 505 while configuring SKTestSession and returned no configured consumable. Its attempted suite was interrupted when a dependent waiter could not complete; it is not a completed nine-case result. Tests now fail immediately when the product prerequisite is absent and cancel an exhausted-credit waiter when purchase did not deliver a usable balance. A speculative transaction-ID workaround was removed; Mac clone purchase acceptance remains BLOCKED. Apple's macOS 26.5 release notes list a fix for SKTestSession configuration selection (172583218 / FB22237318); current macOS is 26.2, but this alone does not prove the exact cause here. See https://developer.apple.com/documentation/macos-release-notes/macos-26_5-release-notes .

The development-signed universal Release is installed at `/Users/xuxuheng/Applications/CastReader for Mac.app`. Existing Safari application bundles remain in place. G12 settings/current-account restore UI are verified, while genuine Mac purchase and clone-credit UI remain open.


## 2026-10-06 核心收敛补验

取代历史 Mac 505 阻塞：隔离 Mac 宿主正确签名后四项本地 StoreKit 核心测试通过，Product.purchase 实际取得 verified xcode 交易；恢复账号边界与失效权益通过。测试重置补 AppStore.sync 清理旧收据缓存。无真实扣款，正式商店交易未验证。 详见 `core-convergence-20261006/README.md`。

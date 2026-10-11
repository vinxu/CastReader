# Duo reader resizability audit — 2026-10-11

Scope: the released iOS reader implementation, preserving the existing document,
WebKit view, playback owner, accepted audio, reading position and annotations as
the available viewport changes. Apple `app-resizability` references were reviewed
before editing; no device-model or global-screen fallback is introduced.

## File coverage

- [x] `CastReader/Views/Reader/ReaderHostView.swift`: local layout traits and a stable playback dock.
- [x] `CastReader/Views/Kindle/KindleBookView.swift`: local layout traits; retain accepted audio during viewport reflow; local diagnostic scale.
- [x] `CastReader/Views/Reader/PDFReaderView.swift`: preserve page-space anchor and relative zoom on every resized viewport.
- [x] `CastReader/Views/Reader/TextReaderView.swift`: local width/display scale; image cache keyed by explicit pixel budget.
- [x] `CastReader/Views/Reader/PhotoReaderCanvas.swift`: recovery depends on a stalled gesture rather than device idiom.
- [x] `CastReader/Views/Kindle/KindleOfflineReaderView.swift`: local text-column width and gesture recovery.
- [x] `CastReader/Services/HistoryStore.swift`: persisted covers use an explicit resource pixel budget.
- [x] `CastReaderTests/DocumentImagePreservationTests.swift`: regression for one image requested at different pixel budgets.
- [x] `CastReaderTests/KindleWebViewContainerTests.swift`: reader identity and CSS viewport follow a fold-size transition without rebuilding the native reader.
- [x] `CastReader/Utils/AdaptiveLayout.swift`: follow-up restores the 72-point phone dock and reduces the truly narrow two-row dock.
- [x] `CastReader/ViewModels/PlayerCoordinator.swift`: follow-up releases the visible reader's orientation policy when returning Home.
- [x] `CastReaderTests/KindleReadingSettingsOwnershipTests.swift`: follow-up checks the actual hidden WebKit viewport through minimize/fold/foreground/expand.

## Pre-edit checklist

- Layout choices use each SwiftUI view's size class or the existing measured viewport.
- Size changes do not become a reader identity, document identity or playback owner.
- Existing ownership, cancellation, loading, overlay, page-identity and user-pause guards stay in place.
- Image generation takes an explicit pixel budget; the local display-scale input and cache key change together.
- The internal decoder and both known callers can change atomically; no compatibility wrapper needs a global display.
- Orientation-lock masks are a capability/lifecycle decision and are not converted to layout size classes.
- Full-bleed backgrounds and scrims remain full bleed. Existing image/DOM canvas inset behavior is kept; safe-area changes belong in the hosting layout.
- The portrait and compact control layouts may differ, but their reader remains on one structural path.

## Implementation review

- All nine tracked source/test files have a nonempty diff. The six reader files
  contain no `AdaptiveLayout.isPad` or `UIScreen.main` after the change.
- The initial migration retained `KindlePlaybackCenter.minimize`'s orientation
  lock using owning-window traits. The later user-reported fold failure below
  showed that policy itself was wrong for Home; the follow-up removes it and
  protects the hidden WebKit viewport directly instead.
- The device-only branches removed are the Kindle accepted-audio reflow gate,
  PDF anchor/zoom recovery gate, and stalled-pinch handler registration gates.
  Actual resize, loaded-document, active-session and recognized-stall checks remain.
- Layout choices update through SwiftUI environments or existing bounds callbacks.
  Image decoding is recomputed from `displayScale` on demand and keyed by pixel
  budget. The diagnostic scale helper accepts its local WebKit traits explicitly;
  it has no stored display-scale state.
- The generic reader now uses the same dock as Kindle, outside the native reading
  surface. Switching control style does not move the reader to another conditional
  branch. Web adapters still report zero additional bottom occlusion because the
  dock has already removed that region from their actual viewport.
- The decoder is an internal application API. Both production callers were updated
  atomically to explicit budgets, with no deprecated wrapper or global fallback.
  Persisted covers are resource assets with a 640-pixel maximum; reader illustrations
  keep the previous 1400-point budget multiplied by their current local display scale.
- Full-bleed backgrounds, native-page canvas inset handling, existing OCR transforms,
  document/VM identities, generated explanation state and pause intent were not replaced.
- `git diff --check` passed after the owned edits. No build or test was run while
  parallel source edits remained in progress.

## Targeted tests to run after integration

New regressions:

- `CastReaderTests/DocumentImagePreservationTests/testDownsampledCoverCannotPoisonLargerReaderImageCache`
- `CastReaderTests/KindleWebViewContainerTests/testFoldSizeChangesKeepReaderMountedAndReserveCurrentPlaybackDock`

Affected existing contracts:

- `CastReaderTests/KindleWebViewContainerTests/testLandscapeDockKeepsActualWebViewAndLastPageLineAboveControls`
- `CastReaderTests/KindleWebViewContainerTests/testLandscapeDockKeepsCSSViewportWhenPlaybackControlsAreTemporarilyHidden`
- `CastReaderTests/KindleWebViewContainerTests/testRealSurfaceResizeStillUpdatesNativeFrameAndCSSViewport`
- `CastReaderTests/KindleWebViewContainerTests/testOldContainerCannotResizeWebViewAfterNewContainerTakesOwnership`
- `CastReaderTests/KindleWebViewContainerTests/testTransientZeroSurfaceRetainsNativeFrameAndCSSViewport`
- `CastReaderTests/KindleSentenceBufferTests/testReflowSealsAcceptedAudioWithoutReplayingOrAcceptingOldLayout`
- `CastReaderTests/KindleSentenceBufferTests/testReflowSealKeepsUserPauseAndDrainsExactlyOnceAfterResume`
- `CastReaderTests/OCRTokenGeometryCoverageTests/testReflowProjectionUsesSemanticParagraphIDsForMarksAndWords`

UI follow-up: use the existing PDF manual zoom/page-position and native reader
rotation scenarios, replacing a rotation with a Duo outer/inner/outer transition.
Check active Read session/time, paused Explain session/time/marks, one natural
continuation, and whether the last line stays above the dock. Narrow headers now
offer `kindleModeMenu`; a UI test must select the mode through that menu when the
wide `kindleModeButton_explain` is absent.

This record does not claim a build, device/simulator run, live narration, or
App Store submission has passed.

## Integrated post-file review

Read-only review repeated against the integrated diff and Apple's idiom,
orientation, screen-scale and safe-area checklists. The original nine files and
the three follow-up files above have nonempty diffs; no owned file was dropped.
The six reader files contain no remaining global screen/idiom/connected-scene
lookup. Orientation masks themselves remain capability policy and were not
translated into width/height heuristics. The follow-up changes when that policy
is active, as described below.

- The generic and Kindle reader surfaces retain one structural path while their
  playback dock changes size. Neither the document/VM identity nor the audio
  completion callback owner is changed by this work.
- The decoder migration and all two production callers remain atomic. The
  internal API deliberately accepts a complete pixel budget; the parent approved
  migrating all controlled callers rather than preserving a deprecated global
  display fallback. `displayScale` is read by SwiftUI at the point of use; a
  differently scaled cached image has a different key. The fixed cover budget
  describes a persisted asset, not display geometry.
- The private Kindle diagnostic helper has five migrated local-trait callers.
  Its scale is not stored, so no trait observer is needed. Native viewport
  recovery continues to run from existing size/layout callbacks, retaining all
  loaded-document, active-owner, overlay, cancellation and pause guards.
- Removed branch gates were device assumptions around resize recovery, not
  independent safety guards: actual dimensions, active playback and native
  stalled-gesture state remain authoritative. The wider user-requested fold
  behavior intentionally extends those existing recovery paths to every viewport.
- Full-bleed fills/scrims and loading layers remain intentionally full bleed.
  Native canvas/OCR geometry remains unchanged. The web reader's existing
  keyboard safe-area exception remains scoped to the bottom keyboard region;
  it is not an all-edge container exception. The shared dock reserves controls
  outside the reader instead of compensating with an invented inset.
- The cache regression can fail if image budget is removed from the cache key.
  The dock regression mounts a real WKWebView and asserts a single native mount,
  retained JavaScript state, matching CSS/native viewport and nonoverlapping
  reader/control frames across narrow/wide/short/narrow sizes. It does not claim
  to cover the live voice keyboard, a system fold event or account services.

## Investigation of the first integrated iPad UI failures

Source evidence: `reports/ios-duo-20261011/ipad-layout-after-devicehub.log` and
`ipad-layout-after-devicehub.xcresult`. Attachments were exported read-only;
selected evidence is retained in
`reports/ios-duo-20261011/ipad-ui-failure-analysis/`.

`testPDFManualZoomAndPositionSurviveRotation` failed at its initial
`playing=true` wait (then line 421), before any pinch, swipe or rotation. At
5.49 seconds XCTest computed the seek button's hit point as `{-1, -1}`. The
status attachment reports `paragraph=-1;segment=-1;playing=false`, a 375×486
viewport and an inaccessible window/status frame `{inf, inf, 0, 0}`. The video
frame `pdf-target-tap-small-window.png` shows the app in an iPad floating window,
with expanded system window controls covering the fixture's Read target area.
This run therefore did not exercise the PDF zoom/anchor assertions.

`testReaderPopoverAndVoicePanelRotation` failed in the shared rotation helper
(then line 48). The log at 18.51–18.64 seconds explicitly records both device
rotation to Landscape Left and interface rotation to Landscape Right. The
`reader-rotated-small-window.png` frame shows the rotated system and app, with
the floating window still retaining its 375×486 portrait dimensions. Requiring
`app.windows.firstMatch.width > height` is invalid for such a floating window.
The preceding appearance attachment also confirms that the test exercised a
compact sheet, rather than the intended regular-width iPad popover.

No Debug orientation lock explains either failure: the fixture opens text/PDF,
which do not request the portrait-only policy, and the shared orientation policy
returns `.all` and ignores lock requests on iPad. The same result bundle's
`testUniversalNavigationAndAllOrientations` passed; its `home()` helper already
restores a full-size starting window, while `scenario()` lacked that setup.

Minimal corrective action is test isolation: share initial full-size-window
normalization between `home()` and `scenario()`, restore size after the legacy
compact-window case, wait for a finite/nonzero visible window and require the
Read target control to be hittable before tapping. Keep the PDF zoom, page-space
anchor, playback continuity and full-screen rotation assertions intact. The
scene owner is making those test changes; this investigation did not edit the
UI-test source, run a build/test, operate a device or change product reader code.
Both cases need rerunning after fixture setup is corrected; neither is counted
as a passed reader regression based on this investigation.

## User-reported outer-display dock and Home orientation

The later user screenshots show a distinct real product issue, not the iPad
test setup above. The compact outer-display reader used the universal `<500`
rule introduced during adaptation: that made an ordinary 375/390-point phone
use a 128-point two-row dock. The follow-up restores the prior 72-point single
row at widths of at least 360 points; smaller available widths use a 104-point
dock with a 96-point console (52-point playback row plus 44-point utility row).
Neither the reader nor its parent explicitly adds the bottom system inset a
second time. Actual system safe areas are retained; no device-name check or
hardcoded subtraction of an inset is introduced.

The sideways Home screenshot includes the minimized Kindle player. Source
inspection found `KindlePlaybackCenter.minimize` calling `lockCurrent` on every
non-iPad, while `PlayerCoordinator.minimize` likewise retained a current/portrait
lock. The app delegate applies this mask to the whole app, so Home inherits the
expanded reader's orientation. Merely reading idiom from local traits does not
correct that lifecycle policy.

The bounded fix removes the minimized-reader lock. Kindle captures its actual
container size, crop and presentation fit synchronously before exposing Home;
the existing stable reader path consumes this snapshot while minimized. A
foreground cycle preserves it, and expanding clears it so existing viewport
recovery uses the current available size. `ReaderHostView` similarly retains
its last valid surface dimensions while hidden. Audio callbacks, VMs, accepted
segments, document identity and playback state are not replaced. Visible
WeRead/YouTube readers still use the existing portrait policy; minimizing now
releases it and expanding reapplies it. `AppOrientationLock` itself and the
separate offline-download policy are not refactored in this fix.

The persistent Kindle view also published `.toolbar(.visible, for: .tabBar)`
after minimization. This competed with MainTab's compact navigation policy and
could expose a second tab bar, matching the user's Home screenshot. That
redundant preference is removed in coordination with the scene owner; the
existing `hideMainChrome` lifecycle updates remain.

Follow-up regression checks (source added/updated, execution delegated to the
parent):

- `KindleReadingSettingsOwnershipTests/testMinimizedReaderKeepsActualViewportAcrossFoldUntilExpanded`
  uses a real local WKWebView, calls the actual playback-center minimize path,
  and verifies native/CSS dimensions, crop, fit, retained document identity,
  foreground-cycle stability and release on expansion.
- `KindleWebViewContainerTests/testFoldSizeChangesKeepReaderMountedAndReserveCurrentPlaybackDock`
  now independently expects 72 points at 375-point width, 104 at 320, and 68
  for short landscape, while continuing to assert one native reader mount.
- Rerun the existing voice-panel and inactive-app viewport ownership tests.
- Duo UI: play on the expanded display, minimize, fold to the outer display,
  confirm upright Home and one navigation bar, expand again and confirm the
  same reading session/position. Verify 375/390-point ordinary iPhone controls
  stay in one row and that the final text line remains above the dock.

`git diff --check` passed after this follow-up. No build, simulator operation or
live generation was performed by this subtask; actual display/orientation and
playback acceptance remain with the parent task.

## 2026-10-12 — expanding the minimized reader after a fold

The live Duo run confirmed two preceding fixes: outer-display playback kept
playing/highlighting on Open, and expanded playback → minimize → Closed kept
Home upright with one navigation bar and a speaking mini player. Reopening
that mini player on the outer display exposed a separate recovery race.

Evidence: `kindle-background-probe.log` in simulator
`2F655B89-D1D5-4869-930F-B4AF9C512176`, app container
`D5DB73C6-557D-46EF-ADB7-DED2A778FF1E/Documents`:

- 00:03:12.531–.532: presentation released the retained viewport and scheduled
  ordinary `expand` recovery before SwiftUI had delivered the new geometry.
- 00:03:12.557–.563: the current 382×519-point surface arrived and correctly
  started `reader-size`/`ipad-viewport` recovery.
- 00:03:13.393–.437: the earlier expand refocus acquired the shared refocus
  flag; layout repair ran, but its viewport refocus returned immediately as
  busy. A missing projection revision was treated as a failed match.
- 00:03:19.153 onwards: the obsolete expand request searched for old page key
  `1773d3790a4d`; Amazon had genuinely repaginated to `8a4ee2f94ed1` (1152×1560),
  so exact-key checks correctly rejected the images. This repeated through
  00:03:45. No inference about later recovery is made from this log excerpt.

The bounded fix cancels the view's pending/in-flight ordinary refocus when a
real surface/orientation change takes over. Model-level viewport recovery has
priority over ordinary expand/foreground/highlight recovery. Refocus now
reports `deferred` separately from completion/unavailability; the existing
layout-repair retry handles a still-unwinding owner without pausing playback or
claiming that semantic positioning failed. Async boundaries reject cancelled
or superseded ordinary refocus work before OCR/overlay results commit.
Exact-page checks remain mandatory outside viewport reflow, and reflow still
requires semantic word matching, current navigation/mode ownership and a new
projection revision. No VM, accepted audio queue or reading location is reset.

Additional file tracking for this follow-up:

- [x] `CastReader/Views/Kindle/KindleBookView.swift`: recovery ownership and
  cancellation only; the same reader surface, snapshot lifetime and geometry
  source remain. Existing orientation masks/capability exceptions are unchanged.
- [x] `CastReaderTests/KindleReadingSettingsOwnershipTests.swift`: real model,
  real audio-session claim and local WK fixture. A DEBUG-only seam suspends
  the slow rendering await; no production OCR, TTS, navigation or account is used.
- [x] This audit record: evidence, test scope and unchanged invariants recorded.

Targeted additions:

- `KindleReadingSettingsOwnershipTests/testResizeRecoveryWaitsForExistingExpandWithoutPausingOwner`
  forces the actual busy ordering and verifies scheduled retry, retained
  recovery/VM/audio owner, no synthetic pause/error, and subsequent owner release.
- `KindleReadingSettingsOwnershipTests/testPendingResizeRecoveryDefersOrdinaryExpandAndForeground`
  verifies queued ordinary refocus cannot enter while viewport recovery owns
  the page, but the viewport operation can.

Retain the existing minimized-viewport, voice-panel and native-font unchanged
expand regressions. Runtime acceptance is the bounded previously failing
sequence: play expanded → minimize → Closed → reopen outer-display reader;
confirm accepted audio, correct current-word highlighting and no persistent
refocus state. The parent owns execution; this subtask performed no build,
device operation or live request. Post-file checklist: local current geometry
continues to drive layout, no idiom/hardware-name assumption was introduced,
structural/native reader identity and independent guards remain, and no other
reader/device policy was changed. `git diff --check` passed after these edits.

### Cancellation follow-through review

Peer review found that cancellation could still fall through inside the old
key-restoration helper: a cancelled stable-page wait returned `false`, then
anchor restoration began, and the anchor loop swallowed cancelled sleeps.
The restore operation now retains its navigation/mode identity and rechecks
cancellation after each awaited result and before issuing another mutation.
Only the ordinary `refocus-target` path additionally yields to viewport
recovery; legitimate render-switch and native page processing remain allowed.
The stable-page observer also rejects cancelled/stale replies, and its caller
cannot convert a cancellation into an anchor fallback. The final refocus
scroll/highlight sequence rechecks cancellation, viewport priority and the
same VM after its await; it retains the model's existing combined audio owner
policy, including accepted continuous-read audio.

Two additional targeted regressions use real delayed WK replies, without
mocking the cancellation predicate or sending a live request:

- `KindleReadingSettingsOwnershipTests/testCancelledStablePageReplyCannotStartAnchorOrScrollAgain`
  cancels while WebContent is returning page visibility, then asserts there
  is no anchor restoration and exactly one initial positioning operation.
- `KindleReadingSettingsOwnershipTests/testCancelledAnchorReplyCannotContinuePositioningLoop`
  cancels while WebContent is returning the anchor operation, then asserts
  that no further positioning operation is dispatched.

The same three files listed above are the entire follow-up scope. Page-key
requirements, word matching and VM/audio ownership rules remain unchanged.
Source whitespace validation passes; builds and runtime validation remain
with the parent.

## Google paused Explain source recovery (2026-10-12)

Real Duo acceptance retained the Explain VM, marks and paused audio clock on
Closed, but opening reset Google's provider to the chapter's first spread.
The 05:24:04 event in `reader-pagination-20261012-052051.log` mapped every old
source to `-1`; `google-explain-mini-fixed.xcresult` consequently lost visible
ink. Read already used the provider's verified native page sequence to locate
a unique exact source when all old visible neighbors disappeared. Explain had
only neighbor-based directions and silently kept the unrelated visible page.

File coverage for this bounded follow-up:

- [x] `CastReader/Services/WebReaderBridge.swift`: Google Explain reuses the
  existing exact-source refresh command only for a valid mark and a source of
  24–16000 UTF-16 units. Existing frame, baseline, pending-turn and native unique
  match checks remain. Keep the retry set on a miss; clear it only when the
  latest active mark overlaps a verified DOM fragment. Kobo retains its prior
  behavior. A DEBUG-only test entry reaches the existing page-message route
  after origin validation; it is not exposed to JS or launch arguments.
- [x] `CastReaderTests/GoogleBooksWebBridgeTests.swift`: four local WK tests run
  the existing Google adapter and mark renderer through the native bridge,
  with explicit fixture relay wiring and no network speech. They cover two
  sequential native turns back to the source with real ink, a second identical
  reflow after successful recovery, missing source with bounded same/different
  signature attempts, repeated source rejection, and short-source rejection.
  Original explanation source, mark identity, block, playback session and paused
  clock must remain intact. These are post-origin routing tests, not an
  end-to-end test of Google's trusted iframe; existing origin tests remain.
- [x] This audit record: exact scope and validation limits recorded.

Targeted tests are `GoogleBooksWebBridgeTests/` followed by:

- `testGooglePausedExplanationRecoversSourceWithoutVisibleNeighbors`
- `testGooglePausedExplanationMissingSourceStopsRetrying`
- `testGooglePausedExplanationRepeatedSourceNeverChoosesAPage`
- `testGooglePausedExplanationShortSourceNeverScansPages`

Parent-run RED evidence: `reports/ios-duo-20261011/google-explain-recovery-red-v2.log`
and its `.xcresult`. Unique source produced zero restore requests, zero turns
and no post-reflow ink; missing/repeated source cases also received no restore
request. Initial ink and retained session/pause assertions did not fail. The
earlier `red` run had fixture wiring problems and is not product evidence.
Green execution and the real paused-audio fold sequence are owned by the
parent. This subtask does not claim those runtime results before they finish.

Parent-run GREEN evidence is now available: `google-explain-recovery-green.log`
passed unique-source recovery twice (four verified requests/turns with visible
ink), repeated-source and short-source safety, plus four existing viewport,
path, baseline and relay regressions. Its only failure was the fixture's
multiple-signature loop: a 180 ms pause was shorter than the adapter's required
420 ms stable geometry, so each iteration cancelled the previous candidate.
The fixture now waits for native page adoption, verifies distinct committed
signatures, and checks the capped request count after each revision.
`google-explain-missing-green.log` / `.xcresult` passes that case with zero
failures. Across these two executions all eight selected checks pass; the
real provider fold acceptance remains with the parent.

Apple post-file checklist: this change adds no device-name, idiom, screen,
orientation, inset, geometry cache or lifecycle assumption; all such API
migration items are unchanged/N/A for this follow-up. Reader/VM/audio identity
is stable, original source matching is exact, and independent ownership guards
are retained. No JS, vendor source, bundle, external dependency, project file
or localization was changed. Peer pre-review found no blocking issue; source
and final diff reviews found no blocking issue, and source whitespace
validation passes. No build or device operation ran in this subtask.

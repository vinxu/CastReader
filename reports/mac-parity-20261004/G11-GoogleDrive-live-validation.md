# G11 Google Drive Mac parity verification

2026-10-05. CORE_PASS (current-account scope). Normal signed international Mac app, current existing Drive authorization. No credentials copied, access scopes expanded, or Drive files changed.

## Actual provider observations

- Import → Google Drive initially displayed Not connected, then Connecting account. The existing authorization completed and My Drive loaded without a new consent screen. This verifies the current-session connection, not a fresh OAuth grant.
- My Drive folders and exportable document rows rendered in the compact sheet. Search for `CastReader` returned the existing OAuth demo folder, TXT sample and QA Google Doc. Unsupported file selection displayed an accurate alert and returned to the same search results.
- Search result folder → Reading Samples showed the correct breadcrumb path and the existing `CastReader OAuth Demo Reading Sample.txt`. Selecting it displayed metadata/download progress and opened the native reader paused.
- The sample has 26 paragraphs. Explicit Play used Bella at 1x, showed individual word highlights (`selected`, `also`, `and` observed at different paragraphs), automatically scrolled and reached the completed state. Home displayed Finished and the saved final paragraph. This run used the universal Release candidate; no exact duration claim is made because its debug playback log is disabled.
- Closing the completed playback session, quitting, then cold-launching the new signed Debug candidate retained the cloud history reference. Continue Listening performed connection/reopen and restored paragraph 26 paused. Actual new process and paragraph-25 zero-based refocus were observed.
- Explain started from that reopened content with real service audio and original-text highlight, circle, underline and numbered marks. Both 1024×768 and 800×600 layouts were inspected during playback; all eight blocks completed naturally (17:31:27.865 first playing event through 17:33:55.294 final segment completion). Bounded events and result are in `g11-cloud-live/txt-explain-*`.

## Repair

The English browser search placeholder fell back to Chinese. An audit found three literal cloud strings absent from `CloudStorage.xcstrings`: Search Google Drive, Remove from history, Connect account. Added all nine supported locales without changing cloud/auth/import behavior. Normal Debug build and strict deep signature verification passed. The compiled-resource audit covers 100 literal CloudLocalized keys, zero missing catalog keys, and all 27 newly compiled translations (`g11-cloud-live/localization-audit.json`). Actual rebuilt browser shows Search Google Drive in English, verified at 800×600.

## Limitations and next checks

Google Docs automatically exports to DOCX under the existing iOS policy; it has only one supported format, so no format chooser is expected. The existing QA sample exported successfully and completed all 14 readable paragraphs, preserving bullets, repeated paragraphs and both exported document tabs. Search-empty and narrow browser UI passed; account actions and scrollable privacy disclosure passed; the mid-paragraph cold resume passed as detailed below. Prior isolated cloud regressions passed Mac 85 and iPad 108; they remain fixture coverage, not evidence of a fresh provider grant, different-account flow, revoked permission or externally edited/deleted file. No existing account was disconnected or production document modified for testing.

## Shared completed-playback defect (17:42)

Actual DOCX completed at paragraph 13, but tapping the reader Play button made no new audio progress. Two real AVPlayer integration tests reproduced this on both Mac and iPad: normal reader `togglePlayPause()` and mini-player `start()` retained the ended item and never replayed the first paragraph. Both old-source tests failed on each platform (see red summaries).

The candidate routes the explicit finished-state toggle through `start()`, bypasses ended-item resume shortcuts, retains the normal growth/quota gate, clears the terminal audio cursor and starts the first readable paragraph. Existing pending/playing resume behavior is unchanged. Final affected selection passed Mac 158/158 and iPad 158/158 with no failures/skips. The iPad run is 138 + a nonoverlapping 20-case cloud import follow-up: this reused isolated host originally lacked CloudImportIntegrationTests target membership, so that file was registered only in the private test project and then executed. The production iOS project membership was not modified.

## Actual fixed-candidate replay and cold recovery

- Reader Play after actual DOCX completion now starts at paragraph 0 and naturally completes 0–13 in order, with visible synchronized word highlighting. `docx-reader-replay-events.log` freezes that complete replay.
- Mini-player Play after completion also starts from paragraph 0. Pausing midway stopped at paragraph 10 (zero based), 1.169800084 seconds.
- Closing the session, quitting (verified process exit), reopening and selecting cloud history downloaded/reconstructed the current document and located paragraph 10 while paused. Explicit Play resolved the seek to 1.1701334173 seconds; first playing sample was 1.201865042 seconds with the same word fingerprint (32.065 ms after the saved clock). Paragraphs 10–13 then completed naturally. This verifies same-account/same-revision recovery, not remote revision migration.
- Candidate binary/source hashes and strict-signature/build success are recorded; original failing evidence is retained.

## Integrated universal Release confirmation

The final development-signed arm64/x86_64 Release built successfully, passed strict deep signature and fixture-residue checks, and actually launched. The cloud browser displays Search Google Drive; the privacy disclosure shows the Mac laptop symbol, scrolls to all footer controls and returns Home through Done. Native popup screenshot/AX clicking was unreliable in this tool session, but keyboard selection opened the expected disclosure without changing the account. Fresh consent, other accounts, revocation and remote-revision tests remain open. This closes the current-account G11 core gate only. See `g11-cloud-live/release-static.json`.

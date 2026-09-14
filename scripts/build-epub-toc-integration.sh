#!/bin/bash
# Local integration only. Never uploads, submits, signs out or clears app data.
set -euo pipefail
integration_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
release_baseline=b10d83c
git -C "$integration_root" merge-base --is-ancestor "$release_baseline" HEAD || {
  printf '%s\n' 'Refusing to build: checkout does not contain the verified iOS 1.2.39 release.' >&2
  exit 1
}
cd "$integration_root"
for required in   CastReaderTests/KindleNavigationPositionTests.swift   CastReaderTests/KindleReadingSettingsOwnershipTests.swift   CastReaderTests/ReadingResumeTests.swift; do
  test -f "$required" || { printf 'Missing release regression: %s\n' "$required" >&2; exit 1; }
done
rg -q 'old-cursor-unavailable' CastReader/Views/Kindle/KindleBookView.swift
rg -q 'isWarmingBookSession' CastReader/Views/Kindle/KindleBookView.swift
rg -q 'relocatedKindleCheckpoint' CastReader/ViewModels/ReadAloudViewModel.swift
rg -q 'restoreOpeningWeReadPageIfNeeded' CastReader/Services/WebReaderBridge.swift
printf 'Integration source: %s\nRelease baseline: %s\nHEAD: %s\n' "$integration_root" "$release_baseline" "$(git rev-parse HEAD)"
printf 'Tracked patch SHA-256: '
git diff --binary HEAD | shasum -a 256
git ls-files --others --exclude-standard CastReader CastReaderTests CastReaderUITests scripts/build-epub-toc-integration.sh |
  while IFS= read -r integration_file; do shasum -a 256 "$integration_file"; done
if [ "${1:---check}" = --check ]; then exit 0; fi
if [ "$1" != --device ]; then printf '%s\n' 'Usage: bash scripts/build-epub-toc-integration.sh [--check|--device]' >&2; exit 2; fi
xcodebuild -workspace "$integration_root/CastReader.xcworkspace" -scheme CastReader   -destination 'platform=iOS,id=00008130-001C64800C60001C'   -derivedDataPath "${CASTREADER_DEVICE_DERIVED_DATA:-/tmp/CastReaderEPUBTOCDevice20260914}" build-for-testing   DEVELOPMENT_TEAM=KQW6UNZE8J -allowProvisioningUpdates

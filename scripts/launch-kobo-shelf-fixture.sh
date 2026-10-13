#!/bin/bash
set -euo pipefail

# Launch an already-built Debug app against the same local, four-page Kobo
# fixture, or the complete home/binding/reader flow. Installing over the app
# preserves its authorized profile; simulated shelves use separate storage.
build_variant="${1:-fixed}"
simulator_udid="${2:-6A08602F-01D6-4B70-979D-5A5028E894E6}"

launch_arguments=(-CastReaderKoboShelfFixture)
case "$build_variant" in
  baseline)
    derived_data="/tmp/castreader-kobo-baseline-build"
    ;;
  fixed)
    derived_data="/tmp/castreader-kobo-fixed-build"
    ;;
  hundred)
    derived_data="/tmp/castreader-kobo-fixed-build"
    launch_arguments=(-CastReaderKoboHomeValidation -CastReaderSkipLibraryOnboarding
      -CastReaderKoboHundredShelfFixture -CastReaderResetKoboHundredFixture)
    ;;
  home)
    derived_data="/tmp/castreader-kobo-fixed-build"
    launch_arguments=(-CastReaderKoboHomeValidation -CastReaderSkipLibraryOnboarding)
    ;;
  *)
    printf 'Usage: %s baseline|fixed|hundred|home [simulator-UDID] [CastReader.app-path]\n' "$0" >&2
    exit 2
    ;;
esac

app_path="${3:-$derived_data/Build/Products/Debug-iphonesimulator/CastReader.app}"
if [[ ! -d "$app_path" ]]; then
  printf 'Debug app not found: %s\nBuild this variant before launching the fixture.\n' "$app_path" >&2
  exit 1
fi

if ! xcrun simctl list devices booted | rg -Fq "$simulator_udid"; then
  xcrun simctl boot "$simulator_udid"
fi
xcrun simctl bootstatus "$simulator_udid" -b
open -a Simulator --args -CurrentDeviceUDID "$simulator_udid"
xcrun simctl terminate "$simulator_udid" com.same.castreader 2>/dev/null || true
xcrun simctl install "$simulator_udid" "$app_path"
xcrun simctl launch "$simulator_udid" com.same.castreader \
  "${launch_arguments[@]}" \
  -AppleLanguages '(zh-Hans)' \
  -AppleLocale zh_CN \
  -interfaceLanguage zh-Hans
printf 'Launched %s Kobo fixture on %s.\n' "$build_variant" "$simulator_udid"

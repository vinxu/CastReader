#!/bin/bash
set -euo pipefail

mode="${1:-home}"
simulator_udid="${2:-5E6C9500-D581-413A-8D75-A8586AB3C60B}"
app_path="${3:-/tmp/castreader-kobo-fixed-build/Build/Products/Debug-iphonesimulator/CastReader.app}"
case "$mode" in
  home) launch_arguments=(-CastReaderGoogleBooksHomeValidation -CastReaderSkipLibraryOnboarding) ;;
  bind) launch_arguments=(-CastReaderGoogleBooksHomeValidation -CastReaderSkipLibraryOnboarding -CastReaderGoogleBooksOpenConnection) ;;
  hundred) launch_arguments=(-CastReaderGoogleBooksHomeValidation -CastReaderSkipLibraryOnboarding -CastReaderGoogleBooksHundredShelfFixture -CastReaderResetGoogleBooksHundredFixture) ;;
  login) launch_arguments=(-CastReaderGoogleBooksLoginFixture) ;;
  blank) launch_arguments=(-CastReaderGoogleBooksBlankFixture) ;;
  popup) launch_arguments=(-CastReaderGoogleBooksPopupFixture) ;;
  *) printf 'Usage: %s home|bind|hundred|login|blank|popup [simulator-UDID] [CastReader.app]\n' "$0" >&2; exit 2 ;;
esac
[[ -d "$app_path" ]] || { printf 'Build the Debug app first: %s\n' "$app_path" >&2; exit 1; }
if ! xcrun simctl list devices booted | rg -Fq "$simulator_udid"; then
  xcrun simctl boot "$simulator_udid"
fi
xcrun simctl bootstatus "$simulator_udid" -b
xcrun simctl terminate "$simulator_udid" com.same.castreader 2>/dev/null || true
xcrun simctl install "$simulator_udid" "$app_path"
xcrun simctl launch "$simulator_udid" com.same.castreader "${launch_arguments[@]}" \
  -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN -interfaceLanguage zh-Hans
open -a Simulator --args -CurrentDeviceUDID "$simulator_udid"
printf 'Launched Google Books %s on %s.\n' "$mode" "$simulator_udid"

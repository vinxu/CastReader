#!/bin/bash
# Release integration: preserve shipped playback, discovery, navigation and document images.
set -euo pipefail
integration_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
for required_commit in 64c2dbd 633f6bb ad4b885 48998e7 f94b41d 9935c6d 94499d2 d4e427c; do
  git -C "$integration_root" merge-base --is-ancestor "$required_commit" HEAD || {
    printf 'Refusing to build: missing integrated source %s\n' "$required_commit" >&2
    exit 1
  }
done
bash "$integration_root/scripts/build-reader-more-integration.sh" "${1:---check}"

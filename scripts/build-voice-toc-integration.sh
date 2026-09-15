#!/bin/bash
# Local iPhone integration: retain both voice discovery and EPUB navigation.
set -euo pipefail
integration_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
for required_commit in 64c2dbd 633f6bb ad4b885; do
  git -C "$integration_root" merge-base --is-ancestor "$required_commit" HEAD || {
    printf 'Refusing to build: missing integrated source %s\n' "$required_commit" >&2
    exit 1
  }
done
bash "$integration_root/scripts/build-reader-more-integration.sh" "${1:---check}"

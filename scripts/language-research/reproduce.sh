#!/bin/bash
# Research only: downloads public fixtures into /tmp, never modifies the app.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
research_temp=/tmp/CastReaderLanguageResearch20261011
mkdir -p "$research_temp"
fetch() {
  local url="$1" destination="$2" digest="$3"
  if [ ! -f "$destination" ]; then
    curl --fail --location --retry 2 --max-time 180 "$url" -o "$destination"
  fi
  local actual
  actual=$(shasum -a 256 "$destination" | cut -d ' ' -f 1)
  if [ "$actual" != "$digest" ]; then
    echo "Public fixture digest mismatch: $destination" >&2
    exit 1
  fi
}
fetch https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.ftz \
 "$research_temp/lid.176.ftz" 8f3472cfe8738a7b6099e8e999c3cbfae0dcd15696aac7d7738a8039db603e83
fetch https://tinyurl.com/flores200dataset \
 "$research_temp/flores200.tar.gz" b8b0b76783024b85797e5cc75064eb83fc5288b41e9654dabc7be6ae944011f6
fetch https://raw.githubusercontent.com/UniversalDependencies/UD_Cantonese-HK/master/yue_hk-ud-test.conllu \
 "$research_temp/yue_hk-ud-test.conllu" c639341f69097e76d9d7a199ac897214b5f14eadd8010b41745a8466ae391417
/usr/bin/python3 scripts/language-research/prepare-data.py
/usr/bin/python3 scripts/language-research/build-probe.py
# The recorded simulator must already be booted. Set CASTREADER_LID_SIMULATOR
# to another available simulator UUID for a new host/OS. Physical devices are
# intentionally unsupported by this standalone host-filesystem harness.
/usr/bin/python3 scripts/language-research/run-probes.py
/usr/bin/python3 scripts/language-research/run-edge-cases.py
/usr/bin/python3 scripts/language-research/analyze.py

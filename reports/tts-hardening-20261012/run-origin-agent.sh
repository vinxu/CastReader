#!/bin/bash
set -e
. /opt/supervisor-scripts/utils/environment.sh
exec /usr/bin/python3 -I -B -u /opt/castreader-ops/tts-origin/20261012/tts-origin-agent.py

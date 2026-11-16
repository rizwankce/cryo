#!/bin/sh
# Install from a checkout: build and sign `cryo` into ~/.cryo/bin, then set up
# this Mac with `cryo bay install` (LaunchAgent, pf root helper, one sudo prompt, then `cryo doctor`).
# Remove with `~/.cryo/bin/cryo bay uninstall`.
set -e
cd "$(dirname "$0")/.."
scripts/build-bay.sh
exec "$HOME/.cryo/bin/cryo" bay install

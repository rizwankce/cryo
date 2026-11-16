#!/bin/sh
# Build `cryo` for macOS, sign it with the virtualization entitlement (ad hoc) and install it to
# ~/.cryo/bin. Run the bay from there: vmnet refuses binaries under ~/Documents.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product cryo
codesign -f -s - --entitlements scripts/cryo.entitlements .build/release/cryo
mkdir -p "$HOME/.cryo/bin"
# Replace, never overwrite in place: the kernel caches a binary's signature per inode, and a
# signed binary rewritten in place is killed (SIGKILL) on its next launch.
cp .build/release/cryo "$HOME/.cryo/bin/cryo.new"
mv -f "$HOME/.cryo/bin/cryo.new" "$HOME/.cryo/bin/cryo"
echo "installed: $HOME/.cryo/bin/cryo"

#!/usr/bin/env bash
# Checks the build prerequisites and explains how to fix anything missing.
set -u
ok=true
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; ok=false; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

echo "Splicewright build check"

if [[ "$(uname)" != "Darwin" ]]; then
  fail "macOS is required to build the app (only the SWCore tests run elsewhere)."
  exit 1
fi

macos=$(sw_vers -productVersion)
if [[ ${macos%%.*} -ge 15 ]]; then pass "macOS $macos"; else fail "macOS $macos — macOS 15 or newer is required."; fi

arch=$(uname -m)
if [[ "$arch" == "arm64" ]]; then pass "Apple silicon ($arch)"; else warn "Intel Mac ($arch): builds, but hardware HEVC/ProRes performance targets assume Apple silicon."; fi

developer_dir=$(xcode-select -p 2>/dev/null || true)
if [[ -z "$developer_dir" ]]; then
  fail "No developer tools selected. Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
elif [[ "$developer_dir" == *CommandLineTools* ]]; then
  fail "Command Line Tools are selected, not Xcode. Run: sudo xcode-select -s /Applications/Xcode.app"
else
  version=$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')
  if [[ -z "$version" ]]; then
    fail "xcodebuild doesn't run. Open Xcode once to finish setup, or run: sudo xcodebuild -license accept"
  elif [[ ${version%%.*} -ge 16 ]]; then
    pass "Xcode $version ($developer_dir)"
  else
    fail "Xcode $version — Xcode 16 or newer is required."
  fi
fi

if command -v ffmpeg >/dev/null; then pass "ffmpeg (optional, for make fixtures)"; else warn "ffmpeg not found (optional; only needed for make fixtures)"; fi

$ok && echo "Ready: run 'make run' or open Splicewright.xcodeproj and press ⌘R." || exit 1

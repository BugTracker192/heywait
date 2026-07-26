#!/usr/bin/env bash
set -euo pipefail

sender_app="${1:?usage: fakesign-trollstore.sh <sender.app>}"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
broadcast_app="${sender_app}/PlugIns/ScreenShareBroadcast.appex"
sender_info="${sender_app}/Info.plist"
broadcast_info="${broadcast_app}/Info.plist"

command -v ldid >/dev/null 2>&1 || {
  echo "ldid is required to embed the TrollStore entitlements." >&2
  exit 1
}

sender_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${sender_info}")"
broadcast_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${broadcast_info}")"
sender_binary="${sender_app}/${sender_executable}"
broadcast_binary="${broadcast_app}/${broadcast_executable}"

test -x "${sender_binary}"
test -x "${broadcast_binary}"

# Sign the nested code first. TrollStore preserves these embedded entitlements
# when it applies its CoreTrust-compatible signature during installation.
ldid -S"${repo_root}/Config/Broadcast.entitlements" "${broadcast_binary}"
ldid -S"${repo_root}/Config/Sender.entitlements" "${sender_binary}"

verification_dir="${repo_root}/build/embedded-entitlements"
mkdir -p "${verification_dir}"
ldid -e "${broadcast_binary}" > "${verification_dir}/broadcast.plist"
ldid -e "${sender_binary}" > "${verification_dir}/sender.plist"

expected_group='group.dev.screenshare.sender'
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "${verification_dir}/broadcast.plist")" = "${expected_group}"
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "${verification_dir}/sender.plist")" = "${expected_group}"

echo "Embedded and verified shared App Group entitlements for TrollStore."

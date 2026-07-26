#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: package-ipa.sh <path-to-app> <output-ipa>"
  exit 64
fi

app_path="$1"
output_ipa="$2"

if [[ ! -d "$app_path" ]]; then
  echo "app bundle not found: $app_path"
  exit 66
fi

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/Payload"
ditto "$app_path" "$staging/Payload/$(basename "$app_path")"
mkdir -p "$(dirname "$output_ipa")"
(
  cd "$staging"
  /usr/bin/zip -qry "$OLDPWD/$output_ipa" Payload
)


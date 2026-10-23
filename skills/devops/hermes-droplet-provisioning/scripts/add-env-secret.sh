#!/usr/bin/env bash
# Add or replace KEY=VALUE lines in a Hermes .env without ever putting the secret
# into shell history, a chat message, or argv. The value is read with a hidden prompt.
#
# Usage:  bash add-env-secret.sh KEY_NAME [ENV_FILE]
# Run it over an interactive SSH session (`ssh -t`) so the hidden prompt works.
set -euo pipefail

KEY_NAME="${1:?usage: add-env-secret.sh KEY_NAME [env_file]}"
ENV_FILE="${2:-$HOME/.hermes/.env}"

case "$KEY_NAME" in
  *[!A-Z0-9_]*) echo "invalid key name: $KEY_NAME" >&2; exit 2 ;;
esac

read -r -s -p "Paste value for $KEY_NAME (hidden): " VALUE; echo
[ -n "$VALUE" ] || { echo "empty value, aborting" >&2; exit 2; }

# Env files are parsed plainly; reject anything that would corrupt quoting.
if [[ "$VALUE" == *" "* || "$VALUE" == *'"'* || "$VALUE" == *"'"* || "$VALUE" == *'\\'* ]]; then
  echo "value must not contain spaces, quotes, or backslashes" >&2
  exit 2
fi

mkdir -p "$(dirname "$ENV_FILE")"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"
cp -a "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d-%H%M%S)"

TMP="$(mktemp)"
grep -v "^${KEY_NAME}=" "$ENV_FILE" > "$TMP" || true
printf '%s=%s\n' "$KEY_NAME" "$VALUE" >> "$TMP"
cat "$TMP" > "$ENV_FILE"
rm -f "$TMP"
chmod 600 "$ENV_FILE"

echo "wrote $KEY_NAME to $ENV_FILE"

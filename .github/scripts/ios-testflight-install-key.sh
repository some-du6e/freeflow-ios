#!/usr/bin/env bash
# Write the App Store Connect API key to a private file on the runner.
#
# Reads from the environment:
#   ASC_KEY_P8  the contents of AuthKey_<key ID>.p8: the PEM text itself, or
#               the file encoded as base64
#   ASC_KEY_ID  the key's 10-character ID
#
# Writes $RUNNER_TEMP/private_keys/AuthKey_<key ID>.p8 with mode 600, the
# name and place altool looks for, and adds ASC_KEY_PATH and
# API_PRIVATE_KEYS_DIR to $GITHUB_ENV. The workflow deletes the directory in
# an always() step. This script never prints the key.
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is not set}"
: "${GITHUB_ENV:?GITHUB_ENV is not set}"

if [ -z "${ASC_KEY_P8:-}" ]; then
  echo "::error::The testflight environment secret APP_STORE_CONNECT_API_KEY_P8 is empty."
  exit 1
fi
if [[ ! ${ASC_KEY_ID:-} =~ ^[A-Z0-9]{10}$ ]]; then
  echo "::error::The testflight environment secret APP_STORE_CONNECT_KEY_ID must be the 10-character key ID."
  exit 1
fi

begin="-----BEGIN PRIVATE KEY-----"
end="-----END PRIVATE KEY-----"
key=${ASC_KEY_P8//$'\r'/}
if [[ $key != *"$begin"* ]]; then
  # No PEM header, so this should be the .p8 file encoded as base64.
  if ! key=$(printf '%s' "$key" | tr -d ' \t\n' | base64 --decode 2> /dev/null); then
    echo "::error::APP_STORE_CONNECT_API_KEY_P8 is neither the text of the .p8 file nor base64 of it."
    exit 1
  fi
  key=${key//$'\r'/}
fi
# A PEM pasted with literal \n sequences instead of line breaks.
if [[ $key != *$'\n'* && $key == *'\n'* ]]; then
  key=${key//\\n/$'\n'}
fi
while [[ $key == *$'\n' ]]; do
  key=${key%$'\n'}
done
if [[ $key != *"$begin"* || $key != *"$end"* ]]; then
  echo "::error::APP_STORE_CONNECT_API_KEY_P8 must be the whole AuthKey_<key ID>.p8 file, including the $begin and $end lines."
  exit 1
fi

key_dir="$RUNNER_TEMP/private_keys"
key_path="$key_dir/AuthKey_$ASC_KEY_ID.p8"
umask 077
mkdir -p "$key_dir"
chmod 700 "$key_dir"
printf '%s\n' "$key" > "$key_path"
chmod 600 "$key_path"
unset key

if ! openssl pkey -in "$key_path" -noout 2> /dev/null; then
  rm -f "$key_path"
  echo "::error::APP_STORE_CONNECT_API_KEY_P8 is not a readable private key. Paste the whole .p8 file you downloaded from App Store Connect."
  exit 1
fi

{
  echo "ASC_KEY_PATH=$key_path"
  echo "API_PRIVATE_KEYS_DIR=$key_dir"
} >> "$GITHUB_ENV"
echo "Wrote the App Store Connect API key to \$RUNNER_TEMP/private_keys (mode 600)."

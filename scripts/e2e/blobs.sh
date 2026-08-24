#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# Upload a blob, then verify the mailbox reports it stored. register-hashes
# is the mailbox's source of truth for what it holds: the uploaded hash must
# come back as already_stored. (Raw blob download happens over iroh, not
# HTTP, so presence via already_stored is the HTTP-verifiable equivalent.)

note "blobs: upload, then verify the mailbox reports it stored"
head -c 65536 /dev/urandom > "$tmp/blob.bin"
hash="$(hcurl -X POST "$base/blobs/upload" --data-binary @"$tmp/blob.bin" | jq -r .hash)"
[ -n "$hash" ] && [ "$hash" != null ] || fail "blobs/upload returned no hash"

sender="$(health_json | jq -r .endpoint_addr.id)"
req="$(jq -n --arg h "$hash" --arg s "$sender" \
  '{blob_hashes: [$h], sender_pubkey: $s, expect_upload: false, signature: []}')"
hcurl -X POST "$base/blobs/register-hashes" -H 'content-type: application/json' -d "$req" \
  | jq -e --arg h "$hash" '.already_stored | index($h) != null' > /dev/null \
  || fail "uploaded blob $hash not reported as already_stored"
note "blobs: ok ($hash)"

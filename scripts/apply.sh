#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: apply.sh SOURCE PROPOSAL DESTINATION ACTIVITY" >&2
  exit 64
fi

source_file=$1
proposal=$2
destination=$3
activity=$4

jq -e --arg activity "$activity" '.state=="CLOSED" and .apply_activity==$activity and .authority_scope=="temporary_output"' "$proposal" >/dev/null
mkdir -p "$(dirname "$destination")"

awk '
  /^[[:space:]]*$/ { if (blank == 0) { print ""; blank = 1 }; next }
  { sub(/[[:space:]]+$/, ""); print; blank = 0 }
' "$source_file" > "$destination"

jq -S -n \
  --arg activity "$activity" \
  --arg source_digest "$(sha256sum "$source_file" | awk '{print "sha256:" $1}')" \
  --arg output_digest "$(sha256sum "$destination" | awk '{print "sha256:" $1}')" \
  '{schema:"gooo/reflexive-loop/application-receipt/v1",decision:"CLOSED",activity:$activity,source_digest:$source_digest,output_digest:$output_digest,repository_writes:0,write_scope:"temporary_output"}' \
  > "${destination}.receipt.json"

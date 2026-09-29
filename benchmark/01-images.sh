#!/usr/bin/env bash
# 01-images — FR-02/FR-01/FR-16 prereqs: record image sizes the run actually uses.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

OUT="$1"      # run dir
mkdir -p "$OUT"

att="$(image_size_mib "$(img_att)")"
tgt="$(image_size_mib "$(img_tgt)")"

cat > "$OUT/images.json" <<JSON
{
  "attacker_image":     "$(img_att)",
  "target_image":       "$(img_tgt)",
  "attacker_size_mib":  $att,
  "target_size_mib":    $tgt
}
JSON

printf 'images: attacker=%s MiB  target=%s MiB\n' "$att" "$tgt"

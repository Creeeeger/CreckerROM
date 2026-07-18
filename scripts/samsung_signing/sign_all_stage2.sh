#!/usr/bin/env bash
set -euo pipefail

SOC="exynos990"
ROLLBACK_REVISION="${ROLLBACK_REVISION:?Set ROLLBACK_REVISION for the target model}"

TEE_KEY="crecker_stage2_tee_private.pem"
REE_KEY="crecker_stage2_ree_private.pem"

sign_replace() {
  local stage="$1"
  local input="$2"
  local key="$3"
  local rollback="$4"
  shift 4

  local signed="${input}.signed.tmp"

  echo "Signing ${input} (${stage})..."

  python3 stage2_sign_tool.py \
    --soc "${SOC}" \
    --stage "${stage}" \
    -i "${input}" \
    -o "${signed}" \
    -k "${key}" \
    -r "${rollback}" \
    "$@"

  rm -f "${input}"
  mv "${signed}" "${input}"

  echo "Replaced ${input}"
}

# Basic checks
for f in \
  stage2_sign_tool.py \
  "${TEE_KEY}" \
  "${REE_KEY}" \
  epbl.img \
  bl2.img \
  lk.bin \
  el3_mon.img \
  tzsw.img \
  ldfw.img
do
  if [[ ! -f "${f}" ]]; then
    echo "Missing required file: ${f}" >&2
    exit 1
  fi
done

sign_replace "epbl"    "epbl.img"     "${TEE_KEY}" "${ROLLBACK_REVISION}"
sign_replace "bl2"     "bl2.img"      "${REE_KEY}" "${ROLLBACK_REVISION}" --key-type 1
sign_replace "lk"      "lk.bin"       "${REE_KEY}" "${ROLLBACK_REVISION}" --key-type 1
sign_replace "el3_mon" "el3_mon.img"  "${TEE_KEY}" "${ROLLBACK_REVISION}"
sign_replace "tzsw"    "tzsw.img"     "${TEE_KEY}" "${ROLLBACK_REVISION}"
sign_replace "ldfw"    "ldfw.img"     "${TEE_KEY}" "${ROLLBACK_REVISION}"

echo "All images signed and replaced."

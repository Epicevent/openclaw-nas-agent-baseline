#!/usr/bin/env bash
set -euo pipefail

commands=(
  python3
  node
  npm
  rg
  jq
  yq
  fdfind
  file
  unzip
  7zz
  7z
  libreoffice
  soffice
  pandoc
  pdftotext
  pdfinfo
  tesseract
  ocrmypdf
  xlsx2csv
  in2csv
  ssconvert
  antiword
  catdoc
  openclaw
  clawhub
)

printf '%-14s %s\n' "COMMAND" "STATUS"
printf '%-14s %s\n' "-------" "------"

for command_name in "${commands[@]}"; do
  if command -v "$command_name" >/dev/null 2>&1; then
    printf '%-14s %s\n' "$command_name" "ok: $(command -v "$command_name")"
  else
    printf '%-14s %s\n' "$command_name" "missing"
  fi
done

echo
echo "OpenClaw skills:"
openclaw skills check || true

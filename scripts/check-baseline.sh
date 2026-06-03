#!/usr/bin/env bash
set -euo pipefail

commands=(
  python3
  node
  npm
  fc-list
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
  hwp5txt
  hwp5proc
  openclaw-hwp-text
  openclaw-document-tools
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
echo "Korean runtime:"
if locale charmap 2>/dev/null | grep -qi UTF-8; then
  echo "locale_utf8=ok"
else
  echo "locale_utf8=missing"
fi

if locale -a 2>/dev/null | grep -Eiq '^ko_KR(\.utf8|\.UTF-8)?$'; then
  echo "ko_locale=ok"
else
  echo "ko_locale=missing"
fi

if command -v fc-list >/dev/null 2>&1 && [[ "$(fc-list :lang=ko 2>/dev/null | wc -l)" -gt 0 ]]; then
  echo "korean_fonts=ok"
else
  echo "korean_fonts=missing"
fi

echo
echo "OpenClaw skills:"
openclaw skills check || true

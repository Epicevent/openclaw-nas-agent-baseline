#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run as root: sudo bash scripts/install-system-baseline.sh" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
  ca-certificates \
  curl \
  wget \
  git \
  openssh-client \
  rsync \
  file \
  tree \
  less \
  vim-tiny \
  ripgrep \
  fd-find \
  jq \
  yq \
  zip \
  unzip \
  tar \
  gzip \
  bzip2 \
  xz-utils \
  unrar-free \
  poppler-utils \
  qpdf \
  ghostscript \
  tesseract-ocr \
  tesseract-ocr-eng \
  tesseract-ocr-kor \
  ocrmypdf \
  imagemagick \
  ffmpeg \
  libreoffice \
  libreoffice-writer \
  libreoffice-calc \
  libreoffice-impress \
  python3-uno \
  unoconv \
  pandoc \
  antiword \
  catdoc \
  xlsx2csv \
  csvkit \
  gnumeric \
  python3 \
  python3-pip \
  python3-venv \
  python3-dev \
  python3-lxml \
  python3-bs4 \
  python3-pandas \
  python3-openpyxl \
  python3-docx \
  python3-pptx \
  nodejs \
  npm

if apt-cache show 7zip >/dev/null 2>&1; then
  apt-get install -y 7zip
else
  apt-get install -y p7zip-full p7zip-rar || apt-get install -y p7zip-full
fi

if command -v npm >/dev/null 2>&1; then
  npm install -g clawhub || true
fi

echo "system baseline install complete"

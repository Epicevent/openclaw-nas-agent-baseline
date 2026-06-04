# Tool Baseline

Expected command baseline inside the OpenClaw runtime:

- Search and inspection: `rg`, `fd` or `fdfind`, `jq`, `yq`, `file`, `tree`
- Archives: `zip`, `unzip`, `7z`, `7zz`, `tar`, `gzip`, `bzip2`, `xz`
- PDF and OCR: `pdftotext`, `pdfinfo`, `qpdf`, `ghostscript`, `tesseract`, `ocrmypdf`
- Office documents: `libreoffice`, `soffice`, `pandoc`, `xlsx2csv`, `in2csv`, `ssconvert`
- Legacy documents: `antiword`, `catdoc`
- Runtimes: `python3`, `node`, `npm`, `openclaw`, `clawhub`

Check with:

```bash
cd ~/openclaw-nas-agent-baseline 2>/dev/null || cd ~/.openclaw/workspace/openclaw-nas-agent-baseline
bash scripts/internal/check-baseline.bash
```

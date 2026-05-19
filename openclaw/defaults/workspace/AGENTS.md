# OpenClaw Workspace Baseline

This workspace is expected to run inside a per-user OpenClaw container.

Operational rules:
- Treat `~/nas_docs`, `./nas_docs`, and `./nas` as the same per-user NAS document root.
- Assume the NAS path is read-only unless an operator explicitly says otherwise.
- Use installed document tools before guessing: `file`, `pdftotext`, `pdfinfo`, `libreoffice`, `pandoc`, `tesseract`, `ocrmypdf`, `xlsx2csv`, `in2csv`, `ssconvert`, `antiword`, `catdoc`, `7z`, `rg`, `jq`, and `yq`.
- Do not store secrets, tokens, or NAS credentials in this workspace.
- If OpenClaw behavior looks broken, run the recovery scripts from `openclaw-nas-agent-baseline` instead of hand-editing state files.

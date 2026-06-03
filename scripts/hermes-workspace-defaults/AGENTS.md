# Hermes Workspace Runtime Notes

This slot runs inside a Hermes Agent container prepared by OpenClaw NAS Agent.

Important paths:

```text
/workspace
/workspace/nas_docs
```

Use `/workspace/nas_docs` as the canonical NAS document root. Do not treat
`/opt/data` as the NAS root.

HWP and HWPX files:

```bash
openclaw-document-tools
openclaw-hwp-text "/workspace/nas_docs/SHARE/path/to/file.hwp" | sed -n '1,160p'
openclaw-hwp-text "/workspace/nas_docs/SHARE/path/to/file.hwpx" | sed -n '1,160p'
```

Do not use `pandoc` for `.hwp` files. Do not conclude that HWP support is
missing just because `read_file` cannot read `.hwp` directly. Use the terminal
helper `openclaw-hwp-text`, also available as `read-hwp`, `hwp-read`, and
`hwp2txt`.

When a user asks about a `.hwp` or `.hwpx` document, try the helper first.
Do not ask the user to convert the file to TXT/PDF before trying the helper.

For PDFs, use `pdftotext`. For spreadsheets, use `xlsx2csv`, `in2csv`, or
Python. For plain text search, use `rg`.

Do not print or store provider API keys, gateway tokens, NAS passwords, or
credential file contents.

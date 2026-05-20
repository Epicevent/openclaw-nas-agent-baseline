# Install Settings

Fresh install has to include settings that are required for first use.

For this environment, `GEMINI_API_KEY` is not a restore item. It is install
input. A new account is not considered successfully installed unless Gemini
search/model settings are present and the Gateway receives `GEMINI_API_KEY` in
its runtime environment.

The API key itself must not be materialized into `~/.openclaw/openclaw.json`.
OpenClaw can use the `GEMINI_API_KEY` environment fallback for Gemini search.

## Contract

`openclaw-bootstrap` owns the install flow.

When an install env file is provided, bootstrap should:

1. create or clone `~/openclaw`
2. create `~/.openclaw`
3. apply install settings into the new config
4. start/restart the gateway
5. finish only after the container is healthy

The package repo provides the helper that materializes those settings:

```bash
bash scripts/apply-openclaw-install-env.sh \
  --home "$HOME" \
  --env-file "$HOME/.openclaw-install.env"
```

That helper is meant to be called by bootstrap. It is not a separate recovery
flow for the operator to remember after install.

## Install Env File

Put account-specific install settings in a private file readable by the admin
bootstrap path, not by the customer account:

```bash
$HOME/.openclaw-install.env
```

Permissions:

```bash
chown root:root "$HOME/.openclaw-install.env"
chmod 600 "$HOME/.openclaw-install.env"
```

Example keys:

```bash
GEMINI_API_KEY=...
OPENCLAW_DEFAULT_MODEL=...
OPENCLAW_SANDBOX=...
OPENCLAW_CONTROL_UI_BASEPATH=/$(id -un)
OPENCLAW_PROXY_PUBLIC_ORIGIN=https://ji-tech.co.kr
OPENCLAW_PROXY_ALLOWED_ORIGINS=https://ji-tech.co.kr,https://www.ji-tech.co.kr
```

Do not commit this file to GitHub.

## Gateway Token Policy

The gateway token is different from Gemini.

Default fresh-install behavior:

- generate or keep the new gateway token
- do not copy `OPENCLAW_GATEWAY_TOKEN` from the install env file

Only use `--import-gateway-token` when the operator explicitly wants the old
gateway token reused.

## Verify Without Printing Secrets

```bash
jq '{
  gateway: {
    auth_mode: .gateway.auth.mode,
    token_present: (.gateway.auth.token != null),
    controlUi: .gateway.controlUi
  },
  gemini_config_api_key_present: (.plugins.entries.google.config.webSearch.apiKey != null),
  gemini_search_provider: .tools.web.search.provider,
  default_model: .agents.defaults.model.primary
}' "$HOME/.openclaw/openclaw.json"

grep -q '^GEMINI_API_KEY=' "$HOME/openclaw/.env" && echo gemini_runtime_env_present
```

Expected:

```json
{
  "gateway": {
    "auth_mode": "token",
    "token_present": true
  },
  "gemini_config_api_key_present": false,
  "gemini_search_provider": "gemini"
}
```

```text
gemini_runtime_env_present
```

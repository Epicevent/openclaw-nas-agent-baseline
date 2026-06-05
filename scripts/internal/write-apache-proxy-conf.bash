#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  internal/write-apache-proxy-conf.bash --user USER [--mode subdomain|path] [options]

Writes an Apache reverse-proxy config for one OpenClaw account.

Customer deployments should prefer subdomain mode:

  sudo scripts/slot-control.sh subdomain \
    --user oc3 \
    --mode subdomain \
    --host oc3.ji-tech.co.kr \
    --apply \
    --reload

Modes:
  subdomain  https://ocN.example.com/...      -> http://127.0.0.1:PORT/...
  path       https://www.example.com/ocN/...  -> http://127.0.0.1:PORT/ocN/...

Options:
  --user USER          Target account, for example oc3. Required.
  --mode MODE          subdomain or path. Default: subdomain.
  --host HOST          Public host for subdomain mode. Default: USER.BASE_DOMAIN.
  --base-domain NAME   Base domain for default host. Default: ji-tech.co.kr.
  --port PORT          Backend host port. Default: docker port, then ocN slot.
  --output FILE        Config path. Defaults:
                         subdomain: /home/USER/openclaw/deploy/apache-subdomain-USER.conf
                         path:      /home/USER/openclaw/deploy/apache-USER.conf
                       With --apply, /etc/apache2/openclaw/apache-subdomain-USER.conf
                       is also allowed for the server include path.
  --cert-live-name NAME Let's Encrypt live cert name. Default: BASE_DOMAIN.
  --cert-file FILE      Certificate file for subdomain VirtualHost.
  --cert-key FILE       Certificate key file for subdomain VirtualHost.
  --apply              Write the file. Without this, print the config only.
  --reload             With --apply, run apache2ctl -t and reload apache2.

Notes:
  - subdomain mode writes a complete <VirtualHost *:443> file like deploy.zip.
  - subdomain mode requires DNS and TLS/certificate coverage outside this script.
  - subdomain mode expects OpenClaw gateway controlUi.basePath="/".
  - path mode keeps /ocN in the backend path and therefore expects basePath="/ocN".
USAGE
}

target_user=""
mode="subdomain"
host=""
base_domain="${OPENCLAW_BASE_DOMAIN:-ji-tech.co.kr}"
cert_live_name=""
cert_file=""
cert_key=""
port=""
output=""
apply=0
reload_apache=0
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/internal/lib-safe-compose.bash
source "$script_dir/lib-safe-compose.bash"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="${2:?missing --user value}"
      shift 2
      ;;
    --mode)
      mode="${2:?missing --mode value}"
      shift 2
      ;;
    --host)
      host="${2:?missing --host value}"
      shift 2
      ;;
    --base-domain)
      base_domain="${2:?missing --base-domain value}"
      shift 2
      ;;
    --cert-live-name)
      cert_live_name="${2:?missing --cert-live-name value}"
      shift 2
      ;;
    --cert-file)
      cert_file="${2:?missing --cert-file value}"
      shift 2
      ;;
    --cert-key)
      cert_key="${2:?missing --cert-key value}"
      shift 2
      ;;
    --port)
      port="${2:?missing --port value}"
      shift 2
      ;;
    --output)
      output="${2:?missing --output value}"
      shift 2
      ;;
    --apply)
      apply=1
      shift
      ;;
    --reload)
      reload_apache=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$target_user" ]]; then
  echo "error: --user is required" >&2
  usage >&2
  exit 2
fi

openclaw_assert_managed_slot_name "$target_user" || exit $?

case "$mode" in
  subdomain|path) ;;
  *)
    echo "error: --mode must be subdomain or path" >&2
    exit 2
    ;;
esac

if [[ "$apply" -eq 1 && "$(id -u)" -ne 0 ]]; then
  echo "error: --apply requires root. Re-run with sudo." >&2
  exit 1
fi

target_home="$(getent passwd "$target_user" | cut -d: -f6 || true)"
if [[ -z "$target_home" ]]; then
  echo "error: user not found: $target_user" >&2
  exit 1
fi

if [[ -z "$host" ]]; then
  host="${target_user}.${base_domain}"
fi

if [[ ! "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]; then
  echo "error: invalid host: $host" >&2
  exit 2
fi

if [[ -z "$cert_live_name" ]]; then
  cert_live_name="$base_domain"
fi

if [[ -z "$cert_file" ]]; then
  cert_file="/etc/letsencrypt/live/${cert_live_name}/fullchain.pem"
fi

if [[ -z "$cert_key" ]]; then
  cert_key="/etc/letsencrypt/live/${cert_live_name}/privkey.pem"
fi

if [[ -z "$output" ]]; then
  case "$mode" in
    subdomain) output="$target_home/openclaw/deploy/apache-subdomain-${target_user}.conf" ;;
    path) output="$target_home/openclaw/deploy/apache-${target_user}.conf" ;;
  esac
fi

if [[ -z "$port" ]]; then
  container="openclaw-${target_user}-openclaw-gateway-1"
  port="$(docker port "$container" 18789/tcp 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -1 || true)"
  if [[ -z "$port" ]]; then
    port="$(openclaw_slot_default_gateway_port "$target_user" 2>/dev/null || true)"
  fi
fi

if [[ -z "$port" ]]; then
  echo "error: could not determine backend port; pass --port" >&2
  exit 1
fi

if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
  echo "error: invalid port: $port" >&2
  exit 2
fi

if [[ "$apply" -eq 1 ]]; then
  expected_output_subdomain="$target_home/openclaw/deploy/apache-subdomain-${target_user}.conf"
  expected_output_path="$target_home/openclaw/deploy/apache-${target_user}.conf"
  expected_output_server="/etc/apache2/openclaw/apache-subdomain-${target_user}.conf"
  case "$output" in
    "$expected_output_subdomain"|"$expected_output_path"|"$expected_output_server") ;;
    *)
      echo "error: --output must stay on a managed Apache path: $expected_output_subdomain, $expected_output_path, or $expected_output_server" >&2
      exit 2
      ;;
  esac
  openclaw_assert_managed_slot_prewrite "$target_user"
fi

render_subdomain() {
  cat <<EOF
# Subdomain VirtualHost - ${target_user} (port ${port})
# Server: /etc/apache2/sites-available/${host}.conf -> a2ensite -> reload
# DNS: ${host} -> server IP, or a wildcard ${base_domain} A record
# OpenClaw: OPENCLAW_PROXY_MODE=subdomain
#           OPENCLAW_PROXY_PUBLIC_ORIGIN=https://${host}
#           OPENCLAW_CONTROL_UI_BASEPATH=/

<VirtualHost *:443>
    ServerName ${host}

    SSLEngine on
    SSLCertificateFile      ${cert_file}
    SSLCertificateKeyFile   ${cert_key}

    ProxyRequests Off
    ProxyPreserveHost On
    ProxyTimeout 3600

    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} =websocket [NC]
    RewriteCond %{HTTP:Connection} .*upgrade.* [NC]
    RewriteRule ^/(.*)$ ws://127.0.0.1:${port}/\$1 [P,L]

    <Location />
        ProxyPreserveHost On
        RequestHeader set X-Forwarded-Proto "https"
        RequestHeader set X-Forwarded-Host expr=%{HTTP_HOST}
    </Location>

    ProxyPass        / http://127.0.0.1:${port}/ retry=0 timeout=3600
    ProxyPassReverse / http://127.0.0.1:${port}/
</VirtualHost>
EOF
}

render_path() {
  cat <<EOF
# Managed by openclaw-nas-agent-baseline.
# Mode: path
# Public:  https://${host}/${target_user}/...
# Backend: http://127.0.0.1:${port}/${target_user}/...
# Requires OpenClaw gateway controlUi.basePath="/${target_user}".

RedirectMatch 301 ^/${target_user}\$ /${target_user}/

ProxyRequests Off
ProxyPreserveHost On
ProxyTimeout 3600

RewriteEngine On

# WebSocket: /${target_user}/... -> ws://127.0.0.1:${port}/${target_user}/...
RewriteCond %{HTTP:Upgrade} =websocket [NC]
RewriteCond %{HTTP:Connection} .*upgrade.* [NC]
RewriteRule ^/${target_user}(/.*)?$ ws://127.0.0.1:${port}/${target_user}\$1 [P,L]

<Location /${target_user}/>
    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto "https"
    RequestHeader set X-Forwarded-Prefix "/${target_user}"
    RequestHeader set X-Forwarded-Host expr=%{HTTP_HOST}
</Location>

ProxyPass        /${target_user}/ http://127.0.0.1:${port}/${target_user}/ retry=0 timeout=3600
ProxyPassReverse /${target_user}/ http://127.0.0.1:${port}/${target_user}/
ProxyPassReverseCookiePath / /${target_user}/
EOF
}

render() {
  case "$mode" in
    subdomain) render_subdomain ;;
    path) render_path ;;
  esac
}

if [[ "$apply" -eq 0 ]]; then
  echo "dry_run=yes"
  echo "mode=$mode"
  echo "user=$target_user"
  echo "host=$host"
  echo "port=$port"
  echo "output=$output"
  render
  exit 0
fi

mkdir -p "$(dirname "$output")"
if [[ -f "$output" ]]; then
  backup="${output}.$(date +%Y%m%d%H%M%S).bak"
  cp -a "$output" "$backup"
  echo "backup=$backup"
fi

tmp="$(mktemp)"
render > "$tmp"
cat "$tmp" > "$output"
rm -f "$tmp"
chown root:root "$output"
chmod 0644 "$output"
echo "written=$output"

if [[ "$reload_apache" -eq 1 ]]; then
  apache2ctl -t
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload apache2
  else
    service apache2 reload
  fi
fi

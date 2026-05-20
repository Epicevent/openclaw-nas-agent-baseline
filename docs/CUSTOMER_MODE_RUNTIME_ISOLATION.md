# Customer Mode Runtime Isolation

This document records the customer-mode direction validated on `oc1`.

The goal is not only to keep API keys out of Git and Docker images. The goal is
also to prevent the customer Linux account from reading the runtime environment
or config files that contain secrets, while still allowing that customer to read
their own NAS mount.

## Problem

The lab flow originally used one Linux account for everything:

```text
ocN
  logs in over SSH
  owns ~/nas_docs
  owns ~/.openclaw and ~/openclaw/.env
  belongs to the docker group
  runs the OpenClaw gateway container as the same UID
```

That is convenient for a first install test, but it is not acceptable for
customer accounts.

There are two separate leaks:

1. A user in the `docker` group can inspect or exec the container and read
   runtime environment variables.
2. Even without Docker access, if the gateway process runs as the same UID as
   `ocN`, the customer can read same-UID process environment through
   `/proc/<pid>/environ`.

So removing `ocN` from the Docker group is required, but not sufficient.

## Target Model

Customer mode splits the human login account from the process runtime identity:

```text
ocN
  human/customer Linux account
  can read /home/ocN/nas_docs
  is not in the docker group
  cannot read ~/openclaw/.env
  cannot read ~/.openclaw/openclaw.json
  cannot read the gateway process environment

ocN_rt
  system/runtime Linux account
  no interactive login
  runs the OpenClaw gateway container
  can read OpenClaw state/config and runtime env
  can read NAS through a shared data group

ocN_data
  per-account data group
  grants NAS read access to both ocN and ocN_rt
```

The important property is:

```text
gateway process UID != customer login UID
```

That blocks same-UID `/proc/<pid>/environ` reads from the customer account.

## NAS Permission Model

`ocN` must still read their own NAS mount. The NAS mount therefore uses the
customer UID as owner and the per-account data group as group:

```bash
uid=<ocN_uid>,gid=<ocN_data_gid>,forceuid,forcegid,ro,file_mode=0440,dir_mode=0550
```

Result:

```text
ocN
  reads NAS as owner

ocN_rt
  reads NAS through ocN_data group

other oc accounts
  cannot read the mount
```

The container receives the NAS bind mount as usual, but the container process is
run as the runtime UID and given the data group:

```yaml
services:
  openclaw-gateway:
    user: "<ocN_rt_uid>:<ocN_rt_gid>"
    group_add:
      - "<ocN_data_gid>"

  openclaw-cli:
    user: "<ocN_rt_uid>:<ocN_rt_gid>"
    group_add:
      - "<ocN_data_gid>"
```

## Secret Placement

OpenClaw can use `GEMINI_API_KEY` from the Gateway runtime environment. The API
key must not be written into `~/.openclaw/openclaw.json`.

Customer mode expects:

```text
~/.openclaw/openclaw.json
  no literal provider API key
  owned/readable by the runtime identity, not by ocN

~/openclaw/.env
  contains runtime env such as GEMINI_API_KEY
  owned by root/admin or runtime identity
  not readable by ocN

~/.openclaw-install.env
  install input
  not readable by ocN in customer mode
```

## oc1 Validation

On 2026-05-20, `oc1` was converted from lab mode to customer-mode isolation.

Observed success output:

```text
container_user=995:982 status=running health=healthy
oc1_nas_read_ok
oc1_runtime_env_blocked
oc1_config_blocked
oc1_docker_blocked=yes
oc1_proc_env_gemini_visible=no
container_env_gemini_present
container_nas_read_ok
container_nas_sample=3
```

Meaning:

```text
oc1 can read its NAS.
oc1 cannot read ~/openclaw/.env.
oc1 cannot read ~/.openclaw/openclaw.json.
oc1 cannot use Docker.
oc1 cannot read the gateway's GEMINI_API_KEY through /proc.
The container still receives GEMINI_API_KEY.
The container still reads NAS.
```

## Verification Commands

Run these as the customer account after opening a new SSH session:

```bash
id
ls ~/nas_docs | head
cat ~/openclaw/.env
cat ~/.openclaw/openclaw.json
docker ps
```

Expected:

```text
id
  no docker group

ls ~/nas_docs
  works

cat ~/openclaw/.env
  Permission denied

cat ~/.openclaw/openclaw.json
  Permission denied

docker ps
  permission denied
```

Run these as an admin:

```bash
docker inspect "openclaw-ocN-openclaw-gateway-1" \
  --format 'user={{.Config.User}} status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'

sudo -u ocN test -r /home/ocN/nas_docs && echo customer_nas_read_ok
sudo -u ocN test ! -r /home/ocN/openclaw/.env && echo customer_runtime_env_blocked
sudo -u ocN test ! -r /home/ocN/.openclaw/openclaw.json && echo customer_config_blocked
```

To check `/proc` exposure without printing secrets:

```bash
gateway_pids="$(pgrep -f 'node dist/index.js gateway' || true)"
proc_seen=no
for pid in $gateway_pids; do
  if sudo -u ocN sh -c "tr '\\000' '\\n' < /proc/$pid/environ 2>/dev/null | grep -q '^GEMINI_API_KEY='"; then
    proc_seen=yes
  fi
done
echo "customer_proc_env_gemini_visible=$proc_seen"
```

Expected:

```text
customer_proc_env_gemini_visible=no
```

## Next Work

This document records the validated shape. The next repository changes should
make it repeatable without a one-off script:

1. Add a customer-mode account preparation script.
2. Teach bootstrap or its patch layer to support runtime UID/GID and data group
   overrides.
3. Separate README flows into lab mode and customer mode.
4. Add a customer-mode check script that prints only presence/blocking status,
   never secret values.

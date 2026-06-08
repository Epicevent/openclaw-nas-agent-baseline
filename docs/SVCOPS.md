# svcops 계정

`svcops`는 일상 운영용 제한 계정이다. full sudo/root 계정이 아니다. 기존
baseline 작업은 `/opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh`
wrapper를 통해서만 실행한다.

새 설치와 새 운영 기준은 `agent-runtime-ops`다. `svcops`에서 새 기준 상태를 볼
때는 먼저 `opsctl`을 사용한다.

```bash
opsctl profile list
opsctl status oc1
opsctl plan oc1
```

## Responsibility

```text
svcops may:
  inspect slot state
  run the NAS request monitor
  run managed fstab user-mount registration through the wrapper
  refresh gateways, adjust heartbeat settings, and run image rollout commands
  run the localhost-only ops console

svcops must not:
  run sudo bash
  run sudo su
  run sudo docker directly
  read secret files directly
  edit /opt/openclaw-nas-agent-baseline directly
```

Linux account creation, Docker/image build, global Apache setup, and creation of
`svcops` itself are root-admin tasks. See `docs/ROOT_ADMIN_TASKS.md`.

## sudo Policy

`svcops` may run only the wrapper without a password. This is required for PM2
health and NAS request monitors.

Allowed form:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh ...
```

Disallowed forms:

```bash
sudo bash
sudo su
sudo docker
sudo cat /home/ocN/openclaw/.env
```

## PM2 Processes

Health monitor:

```bash
pm2 start /opt/openclaw-nas-agent-baseline/scripts/ops-monitor.sh   --name openclaw-ops-health   -- health-watch
```

NAS request monitor:

```bash
pm2 start /opt/openclaw-nas-agent-baseline/scripts/ops-monitor.sh   --name openclaw-nas-requests   -- nas-request-watch
```

Status:

```bash
pm2 status
pm2 logs openclaw-ops-health --lines 80 --nostream
pm2 logs openclaw-nas-requests --lines 80 --nostream
```

## Ops Console

The console binds to `127.0.0.1` only. Operators access it through an SSH tunnel.

```bash
pm2 start /opt/openclaw-nas-agent-baseline/admin-cli/bin/openclaw-ops-console   --name openclaw-ops-console   -- --host 127.0.0.1 --port 18088
```

Operator PC:

```bash
ssh -L 18088:127.0.0.1:18088 svcops@SERVER
```

Browser:

```text
http://127.0.0.1:18088
```

Actions run through the console are appended to
`/srv/openclaw-ops/reports/actions.log` as JSONL. NAS passwords, API keys, and
gateway tokens must not be written to that log.

## NAS Requests

The customer still enters the NAS username and password from the customer
account. `svcops` does not receive or store NAS passwords. Automatic approval is
decided by account grants in `/srv/openclaw-ops/nas-policy.yaml`.

Inspect pending requests:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-requests 1 20
```

Run one policy pass for diagnostics or immediate retry only:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/ops-monitor.sh nas-request-check
```

Manual exception approval:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-approve-share oc1
```

Manual rejection:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-reject-share oc1 policy_denied
```

## Common Read Commands

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-status oc1
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-verify oc1
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-tree oc1
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-status oc1
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh check oc1 oc1.ji-tech.co.kr
```

## Image Rollout

`slots.yaml` stores rollout lanes only. It is not a NAS approval registry and is
not the source of truth for live mounts.

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-list
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-status-all 1 20
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-rollout openclaw
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh image-rollout hermes
```

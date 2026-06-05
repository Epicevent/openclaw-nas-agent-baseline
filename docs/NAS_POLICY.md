# NAS Policy

`/srv/openclaw-ops/nas-policy.yaml` controls automatic NAS request approval.
`/srv/openclaw-ops/slots.yaml` is only the rollout lane registry.

## Files

```text
/srv/openclaw-ops/slots.yaml
  slot -> lane

/srv/openclaw-ops/nas-policy.yaml
  account -> allowed NAS source grants
```

`slots.yaml` does not store the expected NAS share, mount name, credentials,
handoff state, or release gate history.

## Grant Policy

```yaml
meta:
  schema_version: 1

defaults:
  auto_approve: false

accounts:
  oc1:
    auto_approve: true
    grants:
      - allow: "//192.168.0.222/*"
    max_mounts: unlimited
  dev-hermess:
    auto_approve: true
    grants:
      - allow: "//192.168.0.222/*"
    max_mounts: unlimited
```

Grant forms:

```text
*                  any NAS source
//HOST/*           any share on that host
//HOST/SHARE       exact share
//HOST/PREFIX-*    share prefix
```

Automatic approval succeeds only when:

```text
account policy exists
auto_approve=true
requested_share matches one grant
max_mounts is not exceeded
request has no path override
slot lane is not hold
```

The monitor registers the fstab entry only. The slot user still enters the NAS
username and password in that Linux account. Dev slots are allowed only when
they have an explicit account grant.

## Monitor

One-shot check:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/ops-monitor.sh nas-request-check
```

PM2 watch:

```bash
sudo -u svcops pm2 start /opt/openclaw-nas-agent-baseline/scripts/ops-monitor.sh \
  --name openclaw-nas-requests \
  -- nas-request-watch
```

The monitor writes action audit records to:

```text
/srv/openclaw-ops/reports/actions.log
```

Manual approval remains available for exception handling:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-approve-share oc1
```

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
      - allow: "//nas01.example.local/*"
      - allow: "//nas02.example.local/*"
    max_mounts: unlimited
  dev-hermess:
    auto_approve: true
    grants:
      - allow: "//nas01.example.local/*"
      - allow: "//nas02.example.local/*"
    max_mounts: unlimited
```

Grant forms:

```text
*                  any NAS source
//HOST/*           any share on that host
//HOST/SHARE       exact share
//HOST/PREFIX-*    share prefix
```

Multiple grants can be active at the same time:

```text
allow: "//nas01.example.local/*"
allow: "//nas02.example.local/*"
allow: "//nas02.example.local/OC1"
```

Default local paths branch by NAS source. The NAS host is always rendered as a
deterministic hash label:

```text
//nas01.example.local/OC1 -> ~/nas_docs/host-<hash>/OC1
//nas02.example.local/OC1 -> ~/nas_docs/host-<hash>/OC1
```

Normal customer requests should omit `--mount-name` so the wrapper derives the
collision-safe local path:

```text
agent-nas-mount --request-share //nas01.example.local/OC1
  -> ~/nas_docs/host-<hash>/OC1 points to //nas01.example.local/OC1

agent-nas-mount --request-share //nas02.example.local/OC1
  -> ~/nas_docs/host-<hash>/OC1 points to //nas02.example.local/OC1
```

Explicit `--mount-name` is an advanced override for a single local path. It is
not needed for normal requests and should not be used to represent multiple NAS
sources with the same share name.

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

Normal operation is the PM2 watcher:

```bash
sudo -u svcops pm2 start /opt/openclaw-nas-agent-baseline/scripts/ops-monitor.sh \
  --name openclaw-nas-requests \
  -- nas-request-watch
```

The monitor writes action audit records to:

```text
/srv/openclaw-ops/reports/actions.log
```

`nas-request-check` is a one-shot diagnostic or immediate retry command. It is
not the normal approval flow.

Manual approval remains available for exception handling:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-approve-share oc1
```

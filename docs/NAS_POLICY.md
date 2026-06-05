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

Default local paths branch by the full NAS source. The host and share both
contribute deterministic labels, so the same share name on two NAS hosts cannot
collide locally:

```text
//nas01.example.local/OC1 -> ~/nas_docs/host-<hosthash>/OC1-<sharehash>
//nas02.example.local/OC1 -> ~/nas_docs/host-<hosthash>/OC1-<sharehash>
```

Customer requests use the full NAS share path. The wrapper derives the local
path from that full path:

```text
agent-nas-mount --request-share //nas01.example.local/OC1 --reset-credential --wait
  -> ~/nas_docs/host-<hosthash>/OC1-<sharehash> points to //nas01.example.local/OC1

agent-nas-mount --request-share //nas02.example.local/OC1 --reset-credential --wait
  -> ~/nas_docs/host-<hosthash>/OC1-<sharehash> points to //nas02.example.local/OC1
```

After approval, the customer mounts the same full NAS share path:

```bash
agent-nas-mount --share //nas01.example.local/OC1 --reset-credential
```

The same account can unmount the exact registered NAS share without removing
the operator-managed fstab rule:

```bash
agent-nas-mount --share //nas01.example.local/OC1 --unmount
```

The operator unregisters the same full NAS share path:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh \
  nas-unregister oc1 //nas01.example.local/OC1 --unmount --delete-credential --delete-empty-dir
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

Normal operation is the PM2 watcher:

```bash
sudo -u svcops pm2 start /opt/openclaw-nas-agent-baseline/scripts/ops-monitor.sh \
  --name openclaw-nas-requests \
  -- nas-request-watch
```

The watcher writes a public liveness state without secrets:

```text
/var/lib/openclaw-nas-agent/nas-request-watch.state
```

`agent-nas-mount --request-share ... --wait` prints that state while it waits,
then mounts as soon as the fstab entry appears.

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

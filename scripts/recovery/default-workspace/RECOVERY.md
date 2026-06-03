# Recovery Notes

This workspace is repair-first, not lock-first.

The baseline does not try to prevent every user change. Instead it keeps enough
state in a repeatable form so an operator can restore the account quickly.

Useful commands:

```bash
# host side, as an operator with sudo
cd /opt/openclaw-nas-agent-baseline
sudo bash scripts/recovery/backup-openclaw-state.sh --user oc1
sudo bash scripts/recovery/repair-openclaw-state.sh --user oc1
```

Restore from a known snapshot:

```bash
sudo bash scripts/recovery/repair-openclaw-state.sh --user oc1 \
  --snapshot /home/oc1/.openclaw-recovery/snapshots/openclaw-state-oc1-YYYYMMDDHHMMSS.tar.gz
```

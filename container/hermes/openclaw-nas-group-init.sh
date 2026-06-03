#!/command/with-contenv sh
set -eu

data_gid="${OPENCLAW_NAS_DATA_GID:-}"
case "$data_gid" in
  ""|*[!0-9]*)
    exit 0
    ;;
esac

group_name="$(getent group "$data_gid" 2>/dev/null | awk -F: 'NR == 1 { print $1 }')"
if [ -z "$group_name" ]; then
  group_name="openclaw-nas-data"
  if ! groupadd -g "$data_gid" "$group_name" 2>/dev/null; then
    group_name="$(getent group "$data_gid" 2>/dev/null | awk -F: 'NR == 1 { print $1 }')"
  fi
fi

if [ -z "$group_name" ]; then
  echo "WARN openclaw_nas_data_group_unavailable=$data_gid"
  exit 0
fi

for user_name in hermes node; do
  if id "$user_name" >/dev/null 2>&1; then
    usermod -a -G "$group_name" "$user_name" 2>/dev/null || true
  fi
done

echo "openclaw_nas_data_group=$group_name:$data_gid"

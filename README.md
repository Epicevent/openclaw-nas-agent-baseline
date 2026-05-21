# OpenClaw NAS Agent Baseline

이 저장소는 고객사별 Linux 계정(`oc1`, `oc2`, ...)마다 독립된 OpenClaw
컨테이너를 만들고, 각 계정 전용 NAS 경로를 컨테이너에 붙이기 위한 운영
패키지다.

이 README는 **제한 운영계정 `svcops` 담당자**가 일상 운영 중에 따라가는
문서다. full sudo/root 권한이 필요한 작업은 여기서 직접 풀지 않고
[root 관리자 작업](docs/ROOT_ADMIN_TASKS.md)에 분리한다.

## 실행 주체

```text
[운영계정: svcops]
  운영자가 평소 로그인하는 제한 계정.
  sudo로 svcops-control.sh wrapper만 실행한다.

[root 관리자]
  서버 초기 설정, Linux 계정 생성, API key 설치, Docker 이미지 설치,
  Apache 운영 반영처럼 root 권한이 필요한 작업을 맡는다.

[고객 계정: ocN]
  실제 고객이 SSH로 접속하는 계정.
  자기 NAS credential을 직접 만들고 자기 nas_docs만 mount한다.

[런타임 계정: ocN_rt]
  사람이 로그인하지 않는 시스템 계정.
  OpenClaw gateway 컨테이너의 실행 UID/GID로만 사용된다.
```

## 운영 모델

```text
고객은 자기 Linux 계정으로 접속한다.
고객은 자기 NAS만 읽을 수 있다.
고객은 Docker, API key, OpenClaw 원본 설정 파일을 볼 수 없다.
OpenClaw는 계정별 컨테이너에서 실행한다.
계정별 Web UI는 서로 다른 subdomain으로 분리한다.
```

고객에게 전달하는 URL은 계정별 subdomain을 사용한다.

```text
권장: https://oc13.ji-tech.co.kr/
비권장: https://www.ji-tech.co.kr/oc13/
```

path 방식(`/oc13`)은 브라우저 저장소가 같은 origin에 묶여 여러 계정의 Gateway
URL/token 설정이 섞일 수 있다. 고객 배포에서는 `oc13.ji-tech.co.kr`처럼
브라우저 origin을 계정별로 분리한다.

계정 하나는 아래처럼 나뉜다.

```text
고객 계정 ocN:
  SSH 접속 가능
  /home/ocN/nas_docs CIFS mount 읽기 가능
  Docker 사용 불가
  API key가 들어 있는 실행 환경 파일 읽기 불가
  OpenClaw 원본 설정 파일 읽기 불가

런타임 계정 ocN_rt:
  OpenClaw gateway 컨테이너 실행용 시스템 계정
  ocN_data 그룹을 통해 NAS 읽기 가능
  사람이 직접 로그인하지 않음

NAS 공유 그룹 ocN_data:
  ocN과 ocN_rt가 같은 NAS mount를 읽기 위한 계정별 그룹
```

## 신규 계정 배포 흐름

```text
1. [root 관리자] 호스트와 svcops 준비
2. [root 관리자] 고객 Linux 계정과 설치 입력 파일 준비
3. [운영계정: svcops] NAS user-mount fstab 규칙 등록
4. [고객 계정: ocN] NAS credential 작성 및 mount
5. [운영계정: svcops] NAS 상태 확인
6. [root 관리자] baseline 이미지와 계정별 OpenClaw 설치
7. [운영계정: svcops] subdomain 설정 적용 및 배포 확인
8. [root 관리자] 필요한 경우 Apache 운영 반영과 Gateway token 전달
9. [고객 계정: ocN] 접속 smoke test
```

root가 해야 하는 1, 2, 6, 8번의 실제 명령은
[root 관리자 작업](docs/ROOT_ADMIN_TASKS.md)에 있다.

## 1. 대상 계정 지정

실행 주체: **[운영계정: svcops]**

작업할 계정만 바꾼다.

```bash
TARGET_USER=oc1
CONTROL_UI_HOST="$TARGET_USER.ji-tech.co.kr"
BASE_DOMAIN=ji-tech.co.kr
```

root 관리자가 아직 호스트 준비나 고객 계정 준비를 하지 않았다면 먼저 이 문서를
전달한다.

- [root 관리자 작업](docs/ROOT_ADMIN_TASKS.md)
- [svcops 운영계정](docs/SVCOPS.md)

## 2. 현재 상태 확인

실행 주체: **[운영계정: svcops]**

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-status "$TARGET_USER"
```

처음 준비하는 계정이라면 `credential_file=missing` 또는 `fstab_rule=missing`가
나올 수 있다. 기존 운영 계정이라면 여기서 현재 NAS mount 상태를 먼저 확인한다.

## 3. NAS mount 규칙 등록

실행 주체: **[운영계정: svcops]**

`NAS_SHARE`는 NAS 계정명이 아니라 SMB 공유 경로다. 설치 현장에서 확인한 공유
경로를 넣는다.

```bash
NAS_SHARE='//NAS_HOST/SHARE_NAME'

sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-register \
  "$TARGET_USER" \
  "$NAS_SHARE"
```

이 단계는 고객의 NAS username/password를 받지 않는다. 실행 후 고객 계정에서
입력할 명령까지 같이 출력한다. 고객 credential은 다음 단계에서 고객 계정 안에
생성된다.

여러 슬롯에 같은 공유 경로를 등록할 때:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-register-all \
  1 \
  20 \
  "$NAS_SHARE"
```

NAS가 고객 계정에서 mount된 뒤 OpenClaw 컨테이너가 같은 NAS를 보고 있는지 실제로
확인할 때:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-verify "$TARGET_USER"
```

호스트 mount는 정상인데 컨테이너가 아직 빈 디렉터리를 보고 있으면 이 명령이
gateway만 재생성한 뒤 다시 확인한다.

## 4. 고객 NAS credential 작성과 mount

실행 주체: **[고객 계정: `$TARGET_USER`]**

고객이 자기 계정으로 SSH 접속한 뒤 실행한다. 최초 실행 때만 NAS
username/password를 묻고, 이후에는 저장된 `~/.nas-cifs.cred`로 바로 mount한다.

```bash
openclaw-nas-mount
```

다시 입력해야 할 때:

```bash
openclaw-nas-mount --reset-credential
```

현재 상태만 볼 때:

```bash
openclaw-nas-mount --status
```

`--status`는 고객 Linux 계정 기준의 상태다. mount 대상 SMB 공유 경로, fstab
등록 여부, 저장된 NAS username, 실제 mount 상태, 다음 행동을 같이 보여준다.
OpenClaw 컨테이너가 같은 NAS를 보고 있는지는 운영계정의 `nas-verify`로 확인한다.
mount 실행 시에도 credential 입력 전에 등록된 공유 경로를 먼저 출력한다.

root는 Linux 보안 모델상 고객 credential 파일을 읽을 수 있다. 그래서 평소
운영자는 full sudo가 아니라 `svcops` wrapper만 사용한다. root 접근자는
break-glass 권한으로 관리한다.

## 5. NAS 상태 재확인

실행 주체: **[운영계정: svcops]**

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-status "$TARGET_USER"
```

정상 상태의 핵심은 아래 두 가지다.

```text
credential_file=present
fstab_rule=present
```

`findmnt` 출력에서 `/home/ocN/nas_docs`가 `cifs`로 잡혀 있어야 한다.

## 6. OpenClaw 설치 요청

실행 주체: **[root 관리자]**

root 관리자가 baseline 이미지와 계정별 OpenClaw 설치를 수행한다.

필요한 명령은 [root 관리자 작업 - 계정별 OpenClaw 설치](docs/ROOT_ADMIN_TASKS.md#계정별-openclaw-설치)에 있다.

## 7. subdomain 설정 적용

실행 주체: **[운영계정: svcops]**

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh subdomain \
  "$TARGET_USER" \
  "$CONTROL_UI_HOST"
```

이 명령은 계정별 OpenClaw 설정과 deploy용 Apache conf를 맞추고 gateway를 다시
띄운다.

Apache가 `/home/ocN/openclaw/deploy/apache-subdomain-ocN.conf`를 실제 운영
VirtualHost로 읽도록 만드는 작업은 서버 Apache 구조에 따라 root 작업일 수 있다.
그 경우 [root 관리자 작업 - Apache 운영 반영](docs/ROOT_ADMIN_TASKS.md#apache-운영-반영)을 따른다.

## 8. 배포 확인

실행 주체: **[운영계정: svcops]**

단일 계정 확인:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh check \
  "$TARGET_USER" \
  "$CONTROL_UI_HOST"
```

여러 계정 확인:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh check-all \
  1 \
  20 \
  "$BASE_DOMAIN"
```

최종 완료 판정에는 아래 항목들이 포함되어야 한다.

```text
PASS customer_not_in_docker_group
PASS customer_nas_read_ok
PASS customer_nas_mounted_cifs
PASS runtime_env_exists
PASS config_exists
PASS customer_runtime_env_blocked
PASS customer_config_blocked
PASS config_has_no_literal_api_key
PASS control_ui_device_auth_disabled
PASS control_ui_basepath_ok
PASS control_ui_allowed_origin_ok
PASS customer_docker_blocked
PASS customer_proc_env_gemini_blocked
PASS container_env_gemini_present
PASS container_nas_read_ok
PASS container_nas_mounted_cifs
PASS customer_isolation_ok
PASS container_exists_for_document_baseline
PASS container_locale_utf8
PASS container_ko_locale_available
PASS container_korean_fonts_available
PASS container_cmd_hwp5txt_ok
PASS container_cmd_hwp5proc_ok
PASS apache_subdomain_basepath_ok
PASS apache_expected_host_parse_ok
PASS apache_syntax_ok
PASS apache_vhost_registered_ok
PASS apache_vhost_config_exists
PASS apache_backend_port_ok
PASS public_url_openclaw_page_ok
```

Apache 관련 PASS가 실패하면 OpenClaw 자체보다 Apache 운영 반영을 먼저 본다.
브라우저가 회사 기본 홈페이지를 보여주는 경우도 이 범주다.

## 9. 고객에게 전달할 정보

실행 주체: **[root 관리자]**

고객에게 전달할 URL 형식:

```text
https://ocN.ji-tech.co.kr/
```

예:

```text
https://oc13.ji-tech.co.kr/
```

Gateway token 출력과 device approval 예외 처리는
[root 관리자 작업 - 고객 전달 정보](docs/ROOT_ADMIN_TASKS.md#고객-전달-정보)에 있다.

## 10. 고객 계정 smoke test

실행 주체: **[고객 계정: `$TARGET_USER`]**

새 터미널에서 고객 계정으로 SSH 접속한다.

```bash
SSH_HOST=YOUR_CUSTOMER_SSH_HOST
ssh "$TARGET_USER@$SSH_HOST"
```

고객 계정에서 확인한다.

```bash
id
ls ~/nas_docs | head
cat ~/openclaw/.env
cat ~/.openclaw/openclaw.json
docker ps
```

기대 결과:

```text
id
  docker group 없음

ls ~/nas_docs
  읽기 가능

cat ~/openclaw/.env
  Permission denied

cat ~/.openclaw/openclaw.json
  Permission denied

docker ps
  permission denied
```

## 참고 문서

- [root 관리자 작업](docs/ROOT_ADMIN_TASKS.md)
- [svcops 운영계정](docs/SVCOPS.md)
- [운영 모델](docs/OPERATION_MODEL.md)
- [Slot turnover](docs/SLOT_TURNOVER.md)
- [Updates](docs/UPDATES.md)
- [Image fast install](docs/IMAGE_FAST_INSTALL.md)
- [Container baseline](docs/CONTAINER_BASELINE.md)
- [Recovery](docs/OPENCLAW_RECOVERY.md)
- [Remount guide](docs/REMOUNT_GUIDE.md)
- [Bootstrap compatibility install](docs/BOOTSTRAP_COMPAT.md)

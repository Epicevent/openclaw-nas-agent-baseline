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
  서버 초기 설정, Linux 계정 생성, runtime secret 주입, Docker 이미지 설치,
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

## Production 보안 판정

현재 production 경로는 **Acceptable with conditions**로 본다. 이 말은 “아무렇게나
운영해도 안전하다”가 아니라, 아래 조건을 지키는 전제에서 고객 운영에 올릴 수
있다는 뜻이다.

```text
반드시 지킬 조건:
  root/admin이 fresh install, turnover, secret 주입, subdomain 재적용을 할 때
  고객 계정의 active session이 없어야 한다.

  recovery snapshot restore는 trusted recovery 절차에서만 실행한다.
  고객이 임의로 준 tarball을 그대로 restore하지 않는다.

  장기 production에서는 baseline image의 base image와 외부 dependency를 pinning한다.

  nas-unregister는 fstab rule 제거일 뿐 active CIFS unmount 완료가 아니다.

  fresh install smoke check와 provider/API key 주입 후 final check를 구분한다.
```

이 조건을 지키지 않으면 다시 **Not acceptable**이다.

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
  /home/ocN/nas_docs 아래의 CIFS 공유 폴더 읽기 가능
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
2. [root 관리자] 고객 Linux 계정 준비
3. [운영계정: svcops] NAS user-mount fstab 규칙 등록
4. [고객 계정: ocN] NAS credential 작성 및 mount
5. [운영계정: svcops] NAS 상태 확인
6. [root 관리자] baseline 이미지와 계정별 OpenClaw 설치
7. [root 관리자] provider/API key 주입 또는 교체
8. [운영계정: svcops] subdomain 설정 적용 및 배포 확인
9. [root 관리자] 필요한 경우 Apache 운영 반영과 Gateway token 전달
10. [고객 계정: ocN] 접속 smoke test
```

root가 해야 하는 1, 2, 6, 7, 9번의 실제 명령은
[root 관리자 작업](docs/ROOT_ADMIN_TASKS.md)에 있다.

root 관리자가 6, 7, 8, 9번처럼 고객 홈 안의 OpenClaw 상태를 쓰거나 gateway를
재생성하는 작업을 할 때는 먼저 고객 세션이 없는지 확인한다.

다음 주 고객 테스트처럼 여러 slot을 넘기기 전에는
[테스트 운영 절차](docs/TEST_OPERATIONS.md)에 따라 baseline commit, 공통 image
tag, private slot 원장, release gate를 먼저 고정한다.

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

이 레포의 기본 운영 흐름에서 `nas_docs`는 고객에게 보이는 NAS 루트 폴더이고,
실제 CIFS mountpoint는 SMB 공유 이름으로 만든 하위 폴더다.

```text
원격 NAS source/share: //NAS_HOST/SHARE_NAME
호스트 mountpoint:     /home/ocN/nas_docs/SHARE_NAME
컨테이너 경로:          /home/node/nas_docs/SHARE_NAME
```

`nas-register`와 `--request-share`에서 말하는 `share`는 첫 줄의 원격 SMB 공유
경로를 뜻한다. 붙는 폴더명은 이 공유 경로에서 자동으로 정한다.

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

고객이 자기 계정으로 SSH 접속한 뒤 실행한다. 운영자가 `nas-register` 또는
`nas-approve-share`를 실행하면 고객에게 줄 명령이 같이 출력된다.

```bash
openclaw-nas-mount --mount-name SHARE_NAME --reset-credential
```

예를 들어 `//192.168.0.222/hanpass`를 등록했다면:

```bash
openclaw-nas-mount --mount-name hanpass --reset-credential
```

현재 상태만 볼 때:

```bash
openclaw-nas-mount --mount-name SHARE_NAME --status
```

다른 NAS 공유 경로가 필요할 때 고객 계정에서 요청만 생성한다:

```bash
openclaw-nas-mount --request-share '//NAS_HOST/SHARE_NAME'
```

`--status`는 고객 Linux 계정 기준의 상태다. mount 대상 SMB 공유 경로, fstab
등록 여부, 저장된 NAS username, 실제 mount 상태, 다음 행동을 같이 보여준다.
OpenClaw 컨테이너가 같은 NAS를 보고 있는지는 운영계정의 `nas-verify`로 확인한다.
mount 실행 시에도 credential 입력 전에 등록된 공유 경로를 먼저 출력한다.

여러 NAS 공유가 필요하면 같은 방식으로 공유 이름별 폴더가 추가된다.

```text
//NAS_HOST/hanpass   -> /home/ocN/nas_docs/hanpass
//NAS_HOST/project-a -> /home/ocN/nas_docs/project-a
```

공유 이름이 같은 두 NAS를 같은 계정에 동시에 붙이는 경우는 아직 자동 충돌 처리를
하지 않는다. 그런 경우에는 운영자가 고객 요청을 다른 공유 이름으로 정리한 뒤 등록한다. 고객 요청으로 별도 mountpoint나 credential path를 받지 않는다.

root는 Linux 보안 모델상 고객 credential 파일을 읽을 수 있다. 그래서 평소
운영자는 full sudo가 아니라 `svcops` wrapper만 사용한다. root 접근자는
break-glass 권한으로 관리한다.

## 5. NAS 상태 재확인

실행 주체: **[운영계정: svcops]**

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-status "$TARGET_USER"
```

고객이 share 변경 요청을 만든 경우:

```bash
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-requests 1 20
sudo /opt/openclaw-nas-agent-baseline/scripts/svcops-control.sh nas-approve-share "$TARGET_USER"
```

`nas-requests`는 승인할 요청이 있으면 `approve_command`를 함께 출력한다.

`nas-status`를 기본 경로로 보면 등록된 공유가 하위 mount로 보여야 한다.

```text
registered_child_mount_1=/home/ocN/nas_docs/SHARE_NAME
registered_child_share_1=//NAS_HOST/SHARE_NAME
```

개별 mount의 credential과 mount 상태는 고객 계정에서
`openclaw-nas-mount --mount-name SHARE_NAME --status`로 본다. 실제 CIFS 여부는
`nas-verify`가 고객 계정과 OpenClaw 컨테이너 양쪽에서 확인한다.

## 6. OpenClaw 설치 요청

실행 주체: **[root 관리자]**

root 관리자가 baseline 이미지와 계정별 OpenClaw 설치를 수행한다. 이 단계는
provider/API key 없이 완료될 수 있어야 한다.

필요한 명령은 [root 관리자 작업 - 계정별 OpenClaw 설치](docs/ROOT_ADMIN_TASKS.md#계정별-openclaw-설치)에 있다.

## 7. runtime secret 주입 또는 교체

실행 주체: **[root 관리자]**

Gemini/API key 같은 runtime secret은 설치 이후 별도 절차로 주입하거나 교체한다.

필요한 명령은 [root 관리자 작업 - runtime secret 주입 또는 교체](docs/ROOT_ADMIN_TASKS.md#runtime-secret-주입-또는-교체)에 있다.

## 8. subdomain 설정 적용

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

## 9. 배포 확인

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
PASS cross_tenant_data_group_isolation
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

## 10. 고객에게 전달할 정보

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

## 11. 고객 계정 smoke test

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

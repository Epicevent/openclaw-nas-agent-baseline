# 운영 모델

## Slot

`ocN`은 사람 자체가 아니라 운영 슬롯이다.

```text
ocN:
  고객 SSH/Web UI 접속 계정
  sudo 없음
  Docker group 없음
  자기 NAS credential 보유
  자기 nas_docs mount 가능

ocN_rt:
  OpenClaw gateway 컨테이너 runtime identity
  고객에게 로그인 계정으로 제공하지 않음

ocN_data:
  ocN과 ocN_rt가 같은 NAS mount를 읽기 위한 그룹

svcops:
  운영자가 사용하는 제한 운영계정
  full sudo 아님
  허용된 운영 wrapper만 sudo 실행
```

## NAS

기본 운영 모델은 고객 계정이 자기 credential을 보유하고 sudo 없이 정해진
mountpoint만 mount하는 방식이다.

```text
fstab rule:
  관리자/root가 등록

NAS_SHARE:
  SMB 공유 경로
  설치 현장에서 받은 값을 사용

NAS username/password:
  고객이 자기 ~/.openclaw-nas/credentials/SHARE_NAME.cred에 입력
```

현재 공식 운영 흐름에서 `nas_docs`는 mountpoint 하나가 아니라 고객에게 보이는
NAS 루트 폴더다. 실제 CIFS mountpoint는 SMB 공유 이름으로 만든 하위 폴더다.

```text
//NAS_HOST/SHARE_NAME -> /home/ocN/nas_docs/SHARE_NAME -> /home/node/nas_docs/SHARE_NAME
```

`share`는 원격 SMB 공유 경로이고, `mountpoint`는 로컬에 붙는 위치다. 운영자가
등록하는 것은 “이 고객 슬롯의 `nas_docs` 아래에 어떤 원격 공유 경로를 붙일지”다.
기본 mountpoint 이름은 SMB 공유 이름에서 자동으로 만든다.

여러 NAS 공유는 같은 규칙으로 추가한다.

```text
//NAS_HOST/hanpass   -> /home/ocN/nas_docs/hanpass
//NAS_HOST/project-a -> /home/ocN/nas_docs/project-a
```

같은 공유 이름을 가진 서로 다른 NAS를 한 계정에 동시에 붙이는 경우는 자동 충돌
처리 대상이 아니다. 그때는 운영자가 고객 요청을 다른 공유 이름으로 정리한 뒤 등록한다. 고객 요청으로 별도 mountpoint나 credential path를 받지 않는다.

컨테이너는 host의 `/home/ocN/nas_docs`를 read-only bind mount로 받는다. 컨테이너
안에서 CIFS mount를 직접 하지 않는다.

## OpenClaw

OpenClaw 설치물과 runtime env는 운영자가 관리한다.

```text
/home/ocN/openclaw:
  compose/runtime env
  고객이 읽지 못해야 함

/home/ocN/.openclaw:
  OpenClaw 상태/config/workspace
  gateway runtime 계정이 읽음
  고객이 raw config를 읽지 못해야 함
```

## 운영 작업 구분

```text
신규 설치:
  README 절차

제한 운영계정:
  docs/SVCOPS.md

슬롯 인계:
  docs/SLOT_TURNOVER.md

NAS 리마운트:
  docs/REMOUNT_GUIDE.md

OpenClaw 업데이트:
  docs/UPDATES.md

손상 복구:
  docs/OPENCLAW_RECOVERY.md
```

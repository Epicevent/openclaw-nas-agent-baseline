# OpenClaw NAS Agent Baseline

## Current Focus: Repairable OpenClaw State

This repo now treats OpenClaw settings as repairable state, not as something that must be locked forever.

- Container images pin the tool/runtime layer.
- `scripts/backup-openclaw-state.sh` snapshots repairable per-user OpenClaw files.
- `scripts/repair-openclaw-state.sh` restores a snapshot or reseeds workspace defaults.
- `install.sh` and `scripts/build-install-package.sh` build a simple tar.gz install package.
- NAS content and secrets stay outside this public repo.

See [docs/OPENCLAW_RECOVERY.md](docs/OPENCLAW_RECOVERY.md).
See [docs/INSTALL_PACKAGE.md](docs/INSTALL_PACKAGE.md) for packaging.

계정형 OpenClaw/NAS 환경에서 사용자가 리눅스 계정 하나만 받고 접속했을 때, 에이전트가 NAS 문서를 읽고 처리할 수 있도록 준비해야 하는 기본 설치 목록과 운영 스크립트 모음이다.

이 repo의 기준 환경은 다음과 같다.

```text
OS: Ubuntu 24.04 LTS
사용자 계정: oc1 ~ oc20
NAS 마운트: /home/ocN/nas_docs
에이전트: OpenClaw
목표: 사용자가 별도 설치 없이 NAS 문서 읽기/요약/검색 요청을 할 수 있게 함
```

## 핵심 원칙

OpenClaw 에이전트가 알아서 설치할 수 있는 것과 관리자가 미리 설치해야 하는 것을 분리한다.

에이전트가 사용자 홈 안에서 처리 가능한 영역:

```text
ClawHub skill 검색
workspace skill 설치
~/.openclaw 아래 캐시/설정 생성
사용자 영역 Python/Node 패키지 설치
```

관리자가 미리 처리해야 하는 영역:

```text
리눅스 계정 생성
SSH 접속 설정
NAS CIFS 마운트
mount 권한/소유권 설정
apt/system 패키지 설치
/usr/bin 계열 도구 설치
Tesseract 언어팩 설치
LibreOffice, Poppler, Pandoc, 7z 등 시스템 도구 설치
```

## 문서

- [설치 매니페스트](docs/INSTALL_MANIFEST.md)
- [운영 모델](docs/OPERATION_MODEL.md)
- [컨테이너 베이스라인](docs/CONTAINER_BASELINE.md)
- [리마운트 가이드](docs/REMOUNT_GUIDE.md)

## 빠른 설치 순서

OpenClaw가 호스트에서 직접 실행되는 경우:

```bash
sudo bash scripts/install-system-baseline.sh
```

OpenClaw가 컨테이너 안에서 실행되는 경우:

```bash
BASE_IMAGE=<current-openclaw-runtime-image> bash scripts/build-container-baseline.sh
```

OpenClaw skill을 계정별로 설치:

```bash
sudo bash scripts/install-user-openclaw-skills.sh
```

설치 상태 확인:

```bash
bash scripts/check-baseline.sh
sudo bash scripts/check-users.sh
```

## 사용자가 접속 후 확인할 것

```bash
whoami
pwd
ls ~/nas_docs
openclaw skills list
```

## 현재 결론

이 환경은 “관리자가 OS/NAS/기본 런타임을 제공하고, 에이전트가 workspace skill 계층을 자가 확장하는 구조”로 운영한다.

즉 사용자가 아무것도 설치하지 않아도 되게 하려면, OpenClaw 실행 위치에 맞춰 기본 패키지와 skill 세트를 계정 생성 시점에 같이 준비해야 한다.

```text
OpenClaw가 host에서 실행됨       -> scripts/install-system-baseline.sh
OpenClaw가 container에서 실행됨  -> container/Dockerfile로 image 확장
```

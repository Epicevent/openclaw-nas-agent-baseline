# 운영 모델

## 1. 계정/접속 계층

사용자는 `oc1`, `oc2`, ..., `oc20` 같은 리눅스 계정 하나를 받는다.

접속 방식:

```bash
ssh oc14@jitechhi.iptime.org
```

또는 OpenClaw 접속 URL을 통해 들어온다.

이 계층에서 관리자가 해야 할 일:

```text
계정 생성
비밀번호 또는 SSH 공개키 설정
shell 설정
홈 디렉터리 권한 설정
docker 그룹 여부 결정
```

## 2. NAS 마운트/권한 계층

각 계정은 자기 홈 아래 NAS 마운트를 갖는다.

```text
/home/oc1/nas_docs
/home/oc2/nas_docs
...
/home/oc20/nas_docs
```

권장 마운트 옵션:

```text
ro
uid=<각 계정 UID>
gid=<각 계정 GID>
file_mode=0400
dir_mode=0700
```

의미:

```text
각 계정은 자기 nas_docs를 읽을 수 있음
다른 일반 계정은 남의 nas_docs에 접근할 수 없음
sudo/root 권한자는 예외
```

## 3. OpenClaw 실행 계층

각 계정에는 OpenClaw 실행 환경이 있어야 한다.

확인:

```bash
openclaw --version
openclaw skills list
openclaw skills check
```

OpenClaw는 사용자 홈의 설정과 workspace를 사용한다.

대표 경로:

```text
~/.openclaw
~/.openclaw/workspace
~/.openclaw/workspace/skills
```

## 4. 에이전트 workspace/skill 계층

에이전트가 자가 확장할 수 있는 영역이다.

가능한 것:

```text
ClawHub에서 skill 검색
workspace에 skill 설치
사용자 홈 아래 캐시/설정 생성
일부 사용자 영역 패키지 설치
```

예:

```bash
openclaw skills search hwp
openclaw skills install hwp-reader
```

## 5. 시스템 패키지/런타임 계층

에이전트가 sudo 없이 설치하기 어려운 영역이다. 관리자가 미리 깔아야 한다.

OpenClaw가 호스트에서 직접 실행되면 host에 설치한다.

OpenClaw가 컨테이너 안에서 실행되면 컨테이너 image 안에 설치한다. host에만 설치하면 컨테이너 내부 에이전트는 해당 도구를 사용할 수 없다.

예:

```text
libreoffice
poppler-utils
tesseract-ocr
tesseract-ocr-kor
pandoc
7zip
python3-venv
python3-pip
```

컨테이너형 운영의 필수 조건:

```text
NAS CIFS mount는 host에서 수행
/home/ocN/nas_docs를 OpenClaw 컨테이너에 read-only bind mount
문서 처리 도구는 OpenClaw runtime image 안에 설치
```

## 6. 문서 처리 가능 범위

기본 목표:

```text
txt, md, csv, json, yaml
pdf
doc, docx
xls, xlsx
ppt, pptx
hwp, hwpx
html, xml
압축 파일
이미지 OCR
```

HWP/HWPX는 ClawHub의 `hwp-reader` 또는 `hwp-extract-pipeline` 같은 skill을 기본 설치 대상으로 본다.

## 7. 보고 문장

이 서비스는 계정별 NAS 마운트와 OpenClaw 실행 환경을 결합한 격리형 문서 작업 환경이다. 에이전트는 ClawHub를 통해 skill 계층을 일부 자가 확장할 수 있지만, 시스템 패키지와 NAS 마운트는 sudo/root 또는 컨테이너 이미지 빌드 영역이므로 관리자가 사전 구성해야 한다.

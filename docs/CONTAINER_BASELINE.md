# Container Baseline

## 왜 host 설치만으로는 부족한가

OpenClaw가 호스트에서 직접 실행되면 `scripts/install-system-baseline.sh`로 설치한 `/usr/bin` 도구들을 그대로 사용할 수 있다.

하지만 OpenClaw가 Docker 컨테이너 안에서 실행되면 이야기가 다르다.

```text
host에 설치된 pdftotext/libreoffice/tesseract
!=
container 안의 pdftotext/libreoffice/tesseract
```

컨테이너 안의 에이전트는 컨테이너 파일시스템에 설치된 도구만 안정적으로 사용할 수 있다. 따라서 문서 읽기 도구는 OpenClaw 런타임 이미지 안에 들어가야 한다.

## 필요한 구조

컨테이너형 운영에서는 다음 세 가지가 모두 필요하다.

```text
1. host: 계정 생성, NAS CIFS 마운트, 권한 분리
2. image: 문서 읽기용 apt/node/python 도구 설치
3. runtime: 계정별 NAS 경로와 OpenClaw home/workspace bind mount
```

## 이미지 빌드

현재 OpenClaw 컨테이너가 쓰는 base image를 확인한 뒤, 그 이미지를 `BASE_IMAGE`로 넘겨 빌드한다.

```bash
cd /opt/openclaw-nas-agent-baseline

docker build \
  --build-arg BASE_IMAGE=<current-openclaw-runtime-image> \
  -t openclaw-nas-agent:baseline \
  -f container/Dockerfile .
```

`BASE_IMAGE`를 반드시 실제 OpenClaw 런타임 이미지로 지정해야 한다. 기본값 `ubuntu:24.04`는 패키지 설치 테스트용 placeholder일 뿐이다.

## 런타임 bind mount

컨테이너 안의 OpenClaw가 NAS를 읽으려면 host의 계정별 NAS 마운트가 컨테이너 안으로 들어와야 한다.

예:

```yaml
services:
  openclaw-gateway:
    image: openclaw-nas-agent:baseline
    user: "<runtime_uid>:<runtime_gid>"
    group_add:
      - "<data_gid>"
    environment:
      HOME: /home/node
    volumes:
      - /home/ocN/.openclaw:/home/node/.openclaw
      - /home/ocN/nas_docs:/home/node/nas_docs:ro
    working_dir: /home/node
```

중요한 점:

```text
NAS CIFS mount는 host에서 수행
컨테이너는 /home/ocN/nas_docs를 read-only bind mount로 받음
컨테이너 내부에서 CIFS mount를 직접 하지 않음
```

컨테이너 내부에서 CIFS를 직접 mount하려면 `SYS_ADMIN` 같은 강한 권한이 필요하므로 기본 운영 모델에서 제외한다.

## 한글 런타임

한글 NAS 문서와 파일명을 안정적으로 처리하려면 컨테이너 안에서도 UTF-8 locale과
한글 폰트가 필요하다. `tesseract-ocr-kor`는 OCR 언어 데이터일 뿐이고,
LibreOffice 변환이나 파일명 처리를 위한 locale/font를 대신하지 않는다.

필수 상태:

```text
LANG=ko_KR.UTF-8
locale charmap -> UTF-8
locale -a -> ko_KR.UTF-8 또는 ko_KR.utf8
fc-list :lang=ko -> 1개 이상
hwp5txt/hwp5proc -> pyhwp fallback 명령
```

## 컨테이너 내부 검증

컨테이너에 들어가서 확인한다.

```bash
whoami
id
ls /home/node/nas_docs
locale charmap
locale -a | grep -Ei '^ko_KR(\.utf8|\.UTF-8)?$'
fc-list :lang=ko | head
command -v pdftotext
command -v libreoffice
command -v tesseract
command -v pandoc
command -v xlsx2csv
command -v hwp5txt
command -v hwp5proc
openclaw skills check
```

## 결론

host 설치 스크립트는 host에서 OpenClaw를 직접 실행하는 경우에만 충분하다. 컨테이너형 OpenClaw에서는 `container/Dockerfile`로 런타임 이미지를 확장하고, 계정별 NAS 경로를 컨테이너에 bind mount해야 한다.

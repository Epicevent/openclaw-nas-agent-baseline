# 설치 매니페스트

이 문서는 계정형 OpenClaw/NAS 환경에서 파일 읽기와 문서 처리를 위해 설치해야 하는 항목을 계층별로 정리한다.

중요:

```text
OpenClaw가 host에서 실행되면 이 패키지들을 host에 설치한다.
OpenClaw가 container에서 실행되면 이 패키지들을 OpenClaw container image 안에 설치한다.
```

컨테이너형 운영에서는 [컨테이너 베이스라인](CONTAINER_BASELINE.md)을 같이 따른다.

## 1. 시스템 기본 도구

```text
ca-certificates
curl
wget
git
openssh-client
rsync
file
tree
less
vim-tiny
```

용도:

```text
다운로드
GitHub/ClawHub 연동
파일 타입 판별
기본 탐색/진단
```

## 2. 검색/구조화 데이터 도구

```text
ripgrep
fd-find
jq
yq
```

용도:

```text
NAS 문서/텍스트 검색
JSON/YAML/TOML 설정 확인
대량 파일 후보 탐색
```

참고: Ubuntu에서는 `fd` 실행 파일명이 `fdfind`일 수 있다.

## 3. 압축 파일 도구

```text
zip
unzip
7zip
p7zip-full
p7zip-rar
unrar-free
tar
gzip
bzip2
xz-utils
```

용도:

```text
zip, 7z, rar, tar.gz, tar.xz 등 첨부/문서 묶음 처리
```

## 4. PDF 도구

```text
poppler-utils
qpdf
ghostscript
```

주요 명령:

```text
pdftotext
pdfinfo
qpdf
gs
```

용도:

```text
PDF 텍스트 추출
PDF 메타데이터 확인
PDF 분할/병합/복구
```

## 5. OCR/이미지 도구

```text
tesseract-ocr
tesseract-ocr-eng
tesseract-ocr-kor
ocrmypdf
imagemagick
ffmpeg
```

용도:

```text
스캔 PDF OCR
이미지 내 한글/영문 텍스트 추출
동영상/이미지 프레임 처리
```

## 6. Office 문서 도구

```text
libreoffice
libreoffice-writer
libreoffice-calc
libreoffice-impress
python3-uno
unoconv
pandoc
antiword
catdoc
```

용도:

```text
doc/docx/xls/xlsx/ppt/pptx 변환
문서 텍스트 추출
Office 문서를 PDF/HTML/TXT로 변환
```

## 7. CSV/Excel 도구

```text
xlsx2csv
csvkit
gnumeric
```

주요 명령:

```text
xlsx2csv
in2csv
csvlook
ssconvert
```

용도:

```text
Excel/CSV 읽기
표 데이터 변환
대량 행/열 분석 전처리
```

## 8. Python 런타임

```text
python3
python3-pip
python3-venv
python3-dev
python3-lxml
python3-bs4
python3-pandas
python3-openpyxl
python3-docx
python3-pptx
```

추가 pip 패키지 후보:

```text
olefile
lxml
beautifulsoup4
python-docx
openpyxl
python-pptx
pandas
pypdf
pdfplumber
pymupdf
tabula-py
markdown
pyyaml
```

## 9. Node/ClawHub 도구

```text
nodejs
npm
```

ClawHub CLI가 필요하면:

```bash
sudo npm install -g clawhub
```

주의:

```text
OpenClaw의 native skills search/install은 clawhub CLI 없이도 동작할 수 있다.
clawhub CLI는 publish, whoami, sync, registry 관리 흐름에 필요하다.
```

## 10. HWP/HWPX

ClawHub 검색 결과 기준 주요 후보:

```text
hwp-reader
hwp-extract-pipeline
hwp-batch-convert-repo
hwp-batch-convert
gonggong-hwpxskills-main
```

Linux NAS 문서 읽기 기본값으로는 아래를 우선 설치한다.

```bash
openclaw skills install hwp-reader
openclaw skills install hwp-extract-pipeline
```

Windows COM 자동화가 필요한 batch convert 계열은 리눅스 서버 기본값에서 제외한다.

## 11. OpenClaw Skill 기본 설치 후보

문서 읽기 기본 세트:

```text
hwp-reader
hwp-extract-pipeline
pdf
document-parser
spreadsheet
summarize
```

검색/관리 보조:

```text
clawhub
session-logs
skill-creator
```

## 12. 최소 검증 명령

```bash
python3 --version
node --version
npm --version
rg --version
jq --version
yq --version
file --version
pdftotext -v
pdfinfo -v
tesseract --version
libreoffice --version
pandoc --version
7zz
xlsx2csv --help
openclaw skills check
```

## 13. 현재 서버에서 확인된 상태

확인된 설치 항목:

```text
python3
node
npm
rg
jq
unzip
libreoffice
soffice
pdftotext
pdfinfo
tesseract
file
```

확인 시점에 없던 항목:

```text
clawhub
hwp5txt
hwp5proc
pandoc
xlsx2csv
7z
yq
fd
antiword
catdoc
```

# ONLYOFFICE 10.0 서버 없이 쓰기: 실현성 시험 결과 (1단계)

시험일: 2026-11-23. 로컬 정적 서버 + Chrome, 시험 페이지는 wasmtools/office-web 앱을 그대로 썼다.

## 구성

| 부분 | 출처 | 비고 |
|---|---|---|
| 편집 화면 web-apps | 공식 Docker `onlyoffice/documentserver:10.0.0` (digest `sha256:ca17889f…`) | 고친 곳 5줄 (api.js 버전 경로, 편집기 4종 시작 HTML에 shim 로드) |
| 편집 엔진 sdkjs | 공식 소스 `ONLYOFFICE/sdkjs` v10.0.0.176 + `sdkjs-forms` v10.0.0.176, `build.py`(이어 붙이기만) | Docker 판은 이름이 난독화돼 shim이 붙지 않는다. 소스 빌드가 필수 |
| 실행 중 생성 파일 | Docker에서 꺼냄 (AllFonts.js, 글꼴 미리보기, 테마 그림, fonts/) | 185개 |
| 변환기 x2t | `Kangchanghwan/onlyoffice-x2t-wasm` 릴리스 `cs-x2t-10.0.0-ed63e94` | core ed63e94(DocumentServer v10.0.0), 빌드 57분 |
| 오프라인 연결 코드 | wasmtools/office-web `80b7e9e` offline-shim.js | AGPL-3.0 |

재현: `cs/oo10/assemble-vendor.sh` (손으로 조립한 결과와 파일 단위로 같음, 서버 전용 sdk-all.bin 만 제외).

## 결과

| 항목 | 결과 | 확인 방법 |
|---|---|---|
| docx 열기·수정·저장 | 통과 | python-docx 로 저장본에 추가 글자 확인 |
| xlsx 열기·수정·저장 | 통과 | openpyxl, A1=5 → SUM 7 |
| **xls 로 저장 (10.0 신기능)** | 통과 | xlrd, 값·한글·수식 결과 유지, 파일 형식 CDFV2 Excel |
| xls 열기 | 통과 | 시트 3개, 수식 계산 |
| pptx 열기·수정·저장 | 통과 | python-pptx |
| **PDF 본문 수정 후 저장** | 통과 (한글·영문·혼합) | pdftotext 로 글자 확인 + 그림으로 렌더해 눈으로 확인 |
| x2t 초기화 시간 | 1.9초 | 로컬 |

## 고친 문제 (순서대로)

1. Docker 10.0 sdkjs 는 속성 이름이 난독화돼 shim 의 `AscCommon.getEmpty`, `_onEndPermissions` 가 없다 → sdkjs 를 공식 소스 태그에서 직접 빌드.
2. x2t 마지막 링크에 drawingfile.cpp 를 넣으면 링크가 끝나지 않음 → 빼고 editors.cpp 한 줄만 `#ifndef __EMSCRIPTEN__`.
3. CryptPad pre-js 의 `new URL(mySrc)` 가 상대 경로에서 오류 → `new URL(mySrc, document.baseURI)`.
4. `-Os` 링크에서 전역 초기화 함수가 14MB 한 덩어리가 돼 브라우저 한도(약 7.6MB) 초과 → 마지막 링크만 `-O1`. 빌드 시간도 2시간 36분 → 57분.
5. PDF 에 입력한 영문이 두 글자씩 밀려 보임(L→N) → 입력 글꼴(Arial)이 변환기 글꼴 폴더에 없어서였다. 저장 전에 해당 글꼴을 넣으면 정상. (`patches/app.js.diff`)
6. XLS 저장이 목록에 안 보임 → shim 과 앱의 형식 목록에 258(XLS) 추가.

## 2단계로 넘길 일

- ranuts 포크에 위 vendor 와 x2t 를 넣고, ranuts 의 9.3 용 보정 코드(lib/onlyoffice/guards 등)를 하나씩 확인.
- PDF 저장 때 넣을 글꼴: 지금은 Arial 만 고정으로 넣었다. 편집한 글자의 글꼴 이름을 보고 fonts-index 에서 찾아 넣도록 바꿔야 한다.
- 크기: x2t.wasm 69.6MB(brotli 7.9MB). Cloudflare 파일당 25MiB 한도 때문에 brotli 본만 올리거나 나눠야 한다.
- AI 탭 끄기(`customization.ai.disabled`), 라이선스 처리(shim 이 branding 을 켜는 부분은 끄고 로고 유지).

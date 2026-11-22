#!/usr/bin/env bash
# ONLYOFFICE 10.0 편집 화면을 서버 없이 쓰도록 vendor 폴더를 조립한다.
#
# 재료
#   1) web-apps, fonts, 실행 중 생성되는 sdkjs 파일: 공식 Docker 이미지에서 꺼낸 폴더
#      (cs-extract-vendor workflow 결과, onlyoffice/documentserver:10.0.0)
#   2) sdkjs 코드: 공식 소스 태그를 그대로 이어 붙여 빌드 (난독화 없음)
#   3) 오프라인 연결 코드(offline-shim.js): wasmtools/office-web (AGPL-3.0)
#
# 사용: assemble-vendor.sh <docker에서 꺼낸 폴더> <출력 vendor 폴더>
set -euo pipefail

DOCKER_DIR=$(cd "$1" && pwd)
OUT=$2
SDKJS_TAG=${SDKJS_TAG:-v10.0.0.176}
SHIM_REPO=${SHIM_REPO:-https://github.com/wasmtools/office-web.git}
SHIM_COMMIT=${SHIM_COMMIT:-80b7e9ebcd2b3d8b6f8208eb4f4d526739d6be5e}
WORK=${WORK:-$(mktemp -d)}

echo "== sdkjs $SDKJS_TAG 소스 빌드"
git clone -q --depth 1 --branch "$SDKJS_TAG" https://github.com/ONLYOFFICE/sdkjs.git "$WORK/sdkjs"
git clone -q --depth 1 --branch "$SDKJS_TAG" https://github.com/ONLYOFFICE/sdkjs-forms.git "$WORK/sdkjs-forms"
(cd "$WORK/sdkjs/build" && PRODUCT_VERSION=10.0.0 BUILD_NUMBER=${SDKJS_TAG##*.} \
  python3 build.py --addon "$WORK/sdkjs-forms" >/dev/null)

echo "== 오프라인 연결 코드 받기 ($SHIM_COMMIT)"
git clone -q --filter=blob:none --no-checkout "$SHIM_REPO" "$WORK/shim"
(cd "$WORK/shim" && git sparse-checkout set --no-cone '/web/vendor/web-apps/apps/*/main/offline-shim.js' && git checkout -q "$SHIM_COMMIT")

echo "== 조립"
rm -rf "$OUT"; mkdir -p "$OUT"
cp -R "$DOCKER_DIR/web-apps" "$OUT/web-apps"
cp -R "$DOCKER_DIR/fonts" "$OUT/fonts"
cp -R "$WORK/sdkjs/deploy/sdkjs" "$OUT/sdkjs"
# Docker 이미지에만 있는 파일(글꼴 목록, 미리보기 그림, 테마)은 실행 중 생성된 것이라 그대로 가져온다.
python3 - "$DOCKER_DIR/sdkjs" "$OUT/sdkjs" <<'EOF'
import os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
n = 0
for d, _, fs in os.walk(src):
    for f in fs:
        rel = os.path.relpath(os.path.join(d, f), src)
        if rel.endswith('sdk-all.bin'):
            continue  # 서버(x2t) 전용 스냅샷, 브라우저는 쓰지 않음
        out = os.path.join(dst, rel)
        if not os.path.exists(out):
            os.makedirs(os.path.dirname(out), exist_ok=True)
            shutil.copy2(os.path.join(d, f), out); n += 1
print(f'생성 파일 {n}개 복사')
EOF

for e in documenteditor spreadsheeteditor presentationeditor pdfeditor; do
  cp "$WORK/shim/web/vendor/web-apps/apps/$e/main/offline-shim.js" "$OUT/web-apps/apps/$e/main/"
done

python3 - "$OUT/web-apps/apps" <<'EOF'
import re, sys
base = sys.argv[1]
# 1) 서버 경로용 버전 접두어를 끈다 (정적 파일을 그대로 서비스하므로)
api = f'{base}/api/documents/api.js'
s = open(api).read()
s2 = re.sub(r"const ver = '/10\.0\.0-[0-9a-f]+';", "const ver = '/10.0.0-{{HASH_POSTFIX}}';", s)
assert s2 != s, 'api.js ver 줄을 찾지 못함'
open(api, 'w').write(s2)
# 2) 편집기 4종의 시작 HTML에서 require.js보다 먼저 offline-shim.js를 읽게 한다
tag = '<script src="../../../vendor/requirejs/require.js"></script>'
for e in ['documenteditor', 'spreadsheeteditor', 'presentationeditor']:
    p = f'{base}/{e}/main/index.html'
    s = open(p).read(); assert s.count(tag) == 1, p
    open(p, 'w').write(s.replace(tag, '<script src="offline-shim.js"></script>\n    ' + tag))
p = f'{base}/pdfeditor/main/index.html'
s = open(p).read(); old = '        function startApp() {\n'
assert s.count(old) == 1, p
open(p, 'w').write(s.replace(old, old + "            document.write('<script src=\"offline-shim.js\"><\\/script>');\n"))
print('패치 5곳 적용')
EOF
echo "완료: $OUT"

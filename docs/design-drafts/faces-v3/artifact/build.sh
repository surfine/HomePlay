#!/bin/zsh
# 把 template + engine + 目前錶面縮圖組成單檔 artifact，另出一份本機預覽（加 doctype）
cd "${0:A:h}"
python3 - <<'PY'
import json
t=open('template.html').read(); e=open('engine.js').read(); now=json.load(open('now.json'))
for k,v in now.items(): t=t.replace('{{NOW_%s}}'%k, v)
t=t.replace('{{ENGINE}}', e)
open('HomePlay錶面v3.html','w').write(t)
open('/private/tmp/claude-501/-Users-aaron-Documents-HomePlay/a262c541-e876-43f2-9b1a-ddb7055c5598/scratchpad/preview.html','w').write('<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head><body>'+t+'</body></html>')
PY

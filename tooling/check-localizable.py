#!/usr/bin/env python3
"""桌寵本地化檢查（照 WindowShade tests/check-localizable.py 的口徑）。

  python3 tooling/check-localizable.py

失敗條件：
  1. 程式裡 L("鍵", "简体原文") 的鍵不在 Localizable.xcstrings；
  2. 目錄裡的 zh-Hans 和程式裡的簡體原文不一致（改了程式忘了改目錄）；
  3. 任何一個鍵缺 en / zh-Hans / zh-Hant，或狀態不是 translated；
  4. 譯文的格式參數（%@、%d、%.1f…）和原文對不上；
  5. 程式裡還有沒走 L() 的中文介面字串（log、註解、print 除外；確實不是介面的加進 ALLOW）。
目錄裡沒被程式用到的鍵只警告。
"""
import json, os, re, sys

ROOT = os.environ.get("HOMEPLAY_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Sources", "homeplay-pet")
CATALOG = os.path.join(SRC, "Resources", "Localizable.xcstrings")
LANGS = ("en", "zh-Hans", "zh-Hant")
CALL = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)+)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)')
STR = re.compile(r'"((?:[^"\\]|\\.)*)"')
CJK = re.compile(r"[㐀-鿿]")
FMT = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSaAp%]")
# 不是介面文字的中文字面量：行內含這些就跳過
SKIP_LINE = re.compile(r"^\s*//|\blog\(|\bprint\(|\bfatalError\(|FileHandle\.standardError|\bcheck\(|Selftest|selftest")
ALLOW = {
    "简体中文", "繁體中文",   # 語言選單裡每種語言用自己的寫法，不翻譯
    "解码报错",              # health.act(why:) 只進日誌，沒人在畫面上看到
    "島錶面背景：没照片退回随时段", r"playing\t歌\t人\t200,5\t50",   # --selftest 的斷言訊息與樣本資料
    # ConnectHelp.logMilestones：拿來數 receiver.log 里程碑的日誌原文，不顯示在畫面上
    "身份自检通过", "MFi 认证通过", "要 Wi-Fi 配置", "送 0x4301", "补发 0x4301", "手机连入控制口", "会话开始，等画面",
    "会话结束：", "连不上（", "→ 首次配对", "自愈：", "蓝牙 iAP2 结束", "SSID 未知",
}

def swift_files():
    for d, _, fs in os.walk(SRC):
        for f in fs:
            if f.endswith(".swift"):
                yield os.path.join(d, f)

def unescape(s):
    return s.encode().decode("unicode_escape").encode("latin-1").decode("utf-8") if "\\" in s else s

def main():
    cat = json.load(open(CATALOG, encoding="utf-8"))
    strings = cat["strings"]
    errors, used = [], {}
    for path in swift_files():
        rel = os.path.relpath(path, ROOT)
        for n, line in enumerate(open(path, encoding="utf-8"), 1):
            code = line.split(" // ")[0]
            if code.lstrip().startswith("//"):
                continue
            for key, src in CALL.findall(code):
                src = unescape(src)
                if key in used and used[key][0] != src:
                    errors.append(f"{rel}:{n} 鍵 {key} 的簡體原文和 {used[key][1]} 不一樣")
                used.setdefault(key, (src, f"{rel}:{n}"))
            if SKIP_LINE.search(code):
                continue
            rest = CALL.sub("", code)
            for s in STR.findall(rest):
                if CJK.search(s) and s not in ALLOW:
                    errors.append(f"{rel}:{n} 介面中文沒走 L()：\"{s[:40]}\"")
    for key, (src, where) in used.items():
        e = strings.get(key)
        if not e:
            errors.append(f"{where} 鍵 {key} 不在 Localizable.xcstrings"); continue
        loc = e.get("localizations", {})
        for lang in LANGS:
            u = loc.get(lang, {}).get("stringUnit", {})
            if u.get("state") != "translated" or not u.get("value"):
                errors.append(f"{key}：缺 {lang}")
            elif sorted(FMT.findall(u["value"])) != sorted(FMT.findall(src)):
                errors.append(f"{key}：{lang} 的格式參數和原文不一致")
        zh = loc.get("zh-Hans", {}).get("stringUnit", {}).get("value")
        if zh is not None and zh != src:
            errors.append(f"{where} 鍵 {key}：程式原文「{src}」≠ 目錄 zh-Hans「{zh}」")
    unused = sorted(set(strings) - set(used))
    for k in unused:
        print(f"警告：目錄裡的 {k} 程式沒用到")
    if errors:
        print("\n".join(f"✗ {e}" for e in errors)); print(f"本地化檢查失敗：{len(errors)} 處"); sys.exit(1)
    print(f"✓ 本地化：{len(used)} 個鍵，{'/'.join(LANGS)} 齊全，原文一致")

main()

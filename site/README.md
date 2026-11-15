# HomePlay 官網

獨立靜態產品站，三種語言共用模板和互動：繁體中文首頁（`/`）、簡體中文（`/zh-hans/`）、英文（`/en/`）。零框架：Node ESM 腳本直接輸出 `dist/`，在 Cloudflare Pages 用 Wrangler Direct Upload 發布。

```sh
cd site
node scripts/build.mjs      # 或 npm run build，輸出 dist/
node scripts/check.mjs      # 或 npm run check
node scripts/serve.mjs      # 或 npm run dev，http://127.0.0.1:4321
```

建置、檢查、預覽只用 Node（不需要 `npm install`）；只有部署才需要 Wrangler。端口被佔用時用 `PORT=4322 npm run dev`。

## 部署

首次建立 Pages 專案（只做一次，之後不要再跑）：

```sh
npx wrangler pages project create homeplay --production-branch main
```

之後每次發布：

```sh
npm install        # 第一次，裝 wrangler
npx wrangler login # 第一次，身份由本機 Wrangler OAuth 管理，倉庫不存任何憑證
npm run deploy     # build、check，再把 dist/ 上傳到 homeplay 專案的 main 分支
```

自訂網域在 Cloudflare 的 Pages 專案裡綁定（預設 `https://homeplay.aaronlau.me`）。換網域時用環境變數傳入公開 origin 再建置與檢查，canonical、hreflang、og:image、sitemap、robots 都跟著變：

```sh
SITE_ORIGIN=https://example.com npm run build && SITE_ORIGIN=https://example.com npm run check
```

## 檔案在哪

- `scripts/content.mjs`：所有文案，`zh-Hant`、`zh-Hans`、`en` 三份同一個形狀，`LANGS` 定義網址與語言切換；站點 origin、GitHub 與 NOTICE 連結常數也在這裡。改字只動這個檔。寫法：說人話，先說它做了什麼，再說怎麼做到；人文那一段（`essay`）的年份與人名都要可查。
- `scripts/build.mjs`：頁面模板、SEO 與分享（canonical、三語 hreflang + x-default、OG、Twitter、JSON-LD：WebSite／SoftwareSourceCode／FAQPage）、微信等 IM 用的隱藏方圖（`share-square.jpg`，頁面第一張圖）、404、`_headers`（嚴格 CSP、`/media/*` 快取一天）、`_redirects`。所有 `/media/` 網址自動加內容雜湊 `?v=`，換圖不會被邊緣快取卡住。
- `style.css`、`app.js`：樣式與互動。沒有行內樣式、行內處理器或行內腳本（CSP 不允許）；各語言的表情名稱與外觀說明放在頁面的 `<script type="application/json" id="i18n">`，那不是可執行腳本。
- `scripts/history.mjs`、`history.css`、`history.js`、`exhibits/`：互動長文〈小工具往事〉（`/history/`、`/zh-hans/history/`、`/en/history/`）。正文與出處只在 `history.mjs`；每章一件展品是 `exhibits/<id>.{js,css,strings.json}`（三語文案在 strings.json），建置時接到 `history.js`／`history.css` 後面，共用 `history.js` 裡的 `HX` 執行環境（快捲到才掛上、離開畫面就停、`say()` 寫進朗讀狀態列）。展品全部自己畫：沒有截圖、原廠圖示、字型、角色或標誌。`docs/plans/widgets-history.md` 是全文稿。這三頁的出處是外連，`check.mjs` 只對它們、只對 `<a href>` 放行出處清單裡的主機。`npm run dev` 也送出正式站的 CSP，展品用了行內樣式或外部資源，在本機就會被擋。
- `scripts/check.mjs`：發布前檢查，見下。
- `public/media/`：全部發布素材，原樣複製進 `dist/`。
- 2.0 Preview 頁（`/2.0/`、`/zh-hans/2.0/`、`/en/2.0/`）：文案在 `scripts/preview.mjs`，版面在 `scripts/preview-page.mjs`，樣式與互動在 `preview.css`、`preview.js`（小工具往事頁也用同一套：建置時 `preview.css` 併進 `history.css`）。素材 `public/media/2.0/<語言>/` 由 `scripts/render-preview.sh <暫存資料夾>`（`homeplay-pet --demo-official` 現拍，示範資料）加 `python3 -I scripts/encode-preview.py <暫存資料夾>` 產生（AVIF＋WebP 兩種寬度、雨景 MP4）；兩頁的分享卡片 `og-preview-*.jpg`、`og-history-*.jpg` 用 `python3 -I scripts/make-og-pages.py`。八項逐輪對照紀錄在上層 `docs/plans/site-2.0-passes.md`。
- `npm run dev` 的本機預覽送出和線上相同的 CSP，文字檔照 Pages 壓縮（br／gzip），Lighthouse 量到的傳輸量才接近線上。

`npm run check` 會擋下：引用到不存在的本地檔案、缺 title／description／canonical／og:image／hreflang、分享圖不是 1200 × 630 JPEG、可見文字出現破折號（U+2014、U+2013）、src／href 指向本站與 github.com 以外的主機、行內處理器或行內腳本、圖片缺 width／height。

## 素材與重拍

`public/media/renders/` 裡每一張圖都是 `homeplay-pet --snapshot` 現拍，沒有手繪或假截圖。重拍：先在上層專案 `swift build -c release`，再

```sh
python3 scripts/render-media.py                 # 繁中全拍（用 scripts/shoot.sh）；加 faces 之類的組名只拍一組
python3 scripts/render-media.py --lang en       # 英文屏幕 → renders/en/；簡中用 --lang zh-Hans → renders/zh-Hans/
python3 -I scripts/make-og.py       # 重做分享圖與圖示
```

`make-og.py` 產生三張分享卡片 `og-v3.jpg`、`og-zh-hans-v3.jpg`、`og-en-v3.jpg`（1200 × 630，冷白底、右邊是該語言屏幕的 `face-curious.webp`、左邊是 `ogTitle`，用 macOS 系統字），以及 512 × 512 的 `share-square.jpg`。

首屏第一張表情圖（`face-idle.webp`）直接寫在 HTML 裡並帶 `fetchpriority="high"`；其餘表情與外觀圖由 `app.js` 在頁面載入後或捲近時才建立，視角與三格場景用 `loading="lazy"`。所有圖都有 width／height，避免版面位移。

錶面一覽（`styles` 組）是六款錶面各一張正面圖，同一個時間 10:09，共用裁切框。README 的拼圖由上層 `tooling/make-readme-media.py` 從同一套渲染組出來。

動畫素材也是現拍：`spin` 組是轉一圈的 36 張（每 10°，螢幕朝前的 10 張在同一分鐘拍完，轉回原點時鐘不跳），`hello-seq` 組是開機寫 hello 的 16 幀（寫完就停，跟語言無關，放 `renders/hello/`）。拍照視窗放在螢幕外，錶面固定島錶面，不受本機偏好影響；另一個 session 正在改桌寵時，用 `HOMEPLAY_PET=<固定版執行檔>` 指定一份已提交版本建出來的執行檔再拍。

圖示由上層 `tooling/make-icon.py --final B` 輸出（`icon-192.png`、`icon-512.png`、`apple-touch-icon.png`），`make-og.py` 只做三張分享卡片與 `share-square.jpg`。

## 動畫

每個動畫都有理由，「減少動態效果」下全部變成靜止或直接切換；只動 transform／opacity，不監聽 scroll，用 IntersectionObserver 只在區塊可見時跑 rAF。

- 首屏：機身彈起進場、慢慢呼吸；表情照 App 的行為表回應游標。
- 為什麼是眼睛：一雙跟著游標看的眼睛，會眨眼，停下來就閉上（「知道什麼時候別看」）；時間軸逐段浮現。
- CarPlay：光點沿著資料路徑走，一顆往回走代表點按傳回 iPhone。
- 轉一圈：canvas 逐張換 36 張實拍，拖動有慣性，沒拖時跟著捲動轉；「拆開看看」切到拆件圖。
- hello：進入畫面時逐幀寫一次，可以再寫一次。
- 亮點：四張卡各一個小動畫（線拔掉換成 Wi-Fi、眼睛眨一下、按住 F5 時聲波起伏、F8 被按下），只在卡片捲進畫面後才跑。
- 錶面一覽：六張依序浮上來；開發者的話：👀 左右看一眼。

## 規則

- 不放追蹤、分析腳本、遠端字型或任何第三方資源；媒體全部本地載入。
- 不寫沒有核實的數字（使用者量、效能、媒體背書）。文案只寫程式真的做得到的事。
- 下載按鈕指向公開倉庫的 `releases/latest/download/HomePlay-macOS-arm64.zip`；安裝包不提交進倉庫。
- 身份材料（配件身份）只說「自己準備」，不給來源、不提供、不暗示取得方式。
- 可見文字不用破折號；句子靠標點與句式，不靠長橫線。

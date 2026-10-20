// 公開倉庫（github.com/surfine/HomePlay）可以放什麼。
//
// 公開倉庫不是這個倉庫的鏡像，而是從已提交的 main 壓成一個提交的精選快照，歷史和私有倉庫斷開。
// 規則照 AI System 6 的 tooling/public-snapshot-manifest.mjs：白名單、兩個方向都 fail-closed——
// 每個被追蹤的檔案都必須被 include 或 exclude 其中之一明確歸類，沒歸類就擋下，
// 新檔案不會「順便」被公開。推上公開倉庫無法收回（會被 clone、fork、快取），所以沉默是最危險的預設。

/** 可以公開的頂層檔案與目錄前綴。 */
export const includePaths = [
  ".gitignore",
  "LICENSE",
  "NOTICE",
  "Package.swift",
  "Sources/",
  "assets/",
  "docs/homeview-study.md",
  "docs/performance.md",
  "docs/carplay-best-practices.md",
  "docs/wireless.md",
  "docs/room-light.md",
  "docs/design-drafts/",
  "docs/evidence/",
  "site/",
  "tooling/",
];

/** include 範圍內外要排除的東西。每一條都寫原因：沒有原因的排除，是下一次編輯最先刪掉的。 */
export const excludePaths = [
  { path: "identity/", reason: "MFi 配件身份（含私鑰）。只留在私有倉庫；公開版要求使用者用 --identity-dir 自備" },
  { path: "Sources/homeplay-pet/Resources/apple-homeview.usdz", reason: "Apple 的 HomeView USDZ，僅隨 App 發佈，不進公開原始碼倉庫" },
  { path: "README.md", reason: "私有版 README 描述自帶身份與自用約定；公開版用 tooling/public-overlay/README.md 代替" },
  { path: "docs/plan.md", reason: "內部計畫與授權決定紀錄，含本機路徑與身份相關定案" },
  { path: "docs/publishing.md", reason: "發布流程與私有倉庫的內容說明，屬內部營運文件" },
  { path: "docs/handoff-audio.md", reason: "內部交接文件（音訊攻堅紀錄）" },
  { path: "docs/history-2026-10-17.md", reason: "內部開發日誌，含身份取得過程與本機環境" },
  { path: "site/dist/", reason: "建置產物" },
  { path: "site/.wrangler/", reason: "wrangler 本地快取（wrangler-account.json 含帳號信箱，曾誤提交過一次）" },
  { path: "site/node_modules/", reason: "依賴" },
  { path: "site/deployment.json", reason: "部署收據，含 Pages 預覽網址" },
  { path: "tooling/public-overlay/", reason: "覆蓋檔本身不以原路徑出現，內容改放到快照根目錄" },
];

/** 快照裡用覆蓋檔取代或新增的檔案：快照路徑 → 倉庫裡的來源。 */
export const overlays = {
  "README.md": "tooling/public-overlay/README.md",
};

/** 公開倉庫。 */
export const publicRepo = "https://github.com/surfine/HomePlay.git";
export const publicBranch = "main";
export const commitAuthor = "Aaron <12213433+surfine@users.noreply.github.com>";

/** 洩漏閘門：路徑層。就算 manifest 被改錯，這些也進不了快照。 */
export const forbiddenPathPatterns = [
  /(^|\/)identity\//,
  /\.(pk8|p7b|p12|pem|key|mobileprovision|cer)$/i,
  /(^|\/)wireless\.json$/,
  /(^|\/)\.env(\..*)?$/,
  /(^|\/)\.(claude|jspace|codex)\//,
  /(^|\/)deployment\.json$/,
];

/** 洩漏閘門：內容層（只掃文字檔）。命中即擋，印出時遮住命中的值。 */
export const forbiddenContentPatterns = [
  { name: "私鑰", re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/ },
  { name: "GitHub token", re: /\bgh[pousr]_[A-Za-z0-9]{30,}/ },
  { name: "OpenAI/Anthropic 風格金鑰", re: /\bsk-[A-Za-z0-9_-]{20,}/ },
  { name: "AWS key", re: /\bAKIA[0-9A-Z]{16}\b/ },
  { name: "Cloudflare token 變數", re: /CLOUDFLARE_API_TOKEN\s*[=:]\s*\S{8,}/ },
  { name: "本機家目錄", re: /\/Users\/[a-z][a-z0-9_-]+\//i },
  { name: "個人信箱", re: /[A-Za-z0-9._%+-]+@(gmail|icloud|me|outlook|hotmail|qq|163)\.com/i },
];

/** 單檔大小上限（位元組）。超過的多半是誤收的影片或建置產物。 */
export const maxFileBytes = 5 * 1024 * 1024;

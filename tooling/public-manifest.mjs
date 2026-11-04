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
  "docs/first-pair-flow.md",
  "docs/first-pair-test.md",
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
  { path: "docs/reference/", reason: "Apple 原始 PDF（CarPlay 開發者指南、開發者計畫協議）供內部查證引用；版權屬 Apple，不進公開倉庫，單檔也超過公開單檔上限" },
  { path: "docs/homeview-day-one-developers.md", reason: "內部查證筆記，引用 docs/reference/ 的 Apple 原文與內部快照規則；公開版研究筆記另見 docs/homeview-study.md" },
  { path: "docs/homeview-third-party-and-design-notes.md", reason: "內部研發判讀：引用 v2 檔案行號、合規矩陣缺口與未公開的下一步排序" },
  { path: "docs/iphone-continuity-feasibility.md", reason: "私有 API 可行性研究與本機取證，含 Apple 未公開的類名與 Mach service 名" },
  { path: "docs/homeview-platform.md", reason: "HomeView 研究統合版：引用 docs/reference/ 的 Apple 原文、私有 API 與接收器協定細節、v1／v2 檔案行號與本機實測" },
  { path: "docs/history-2026-10-17.md", reason: "內部開發日誌，含身份取得過程與本機環境" },
  { path: "docs/branch-archive-2026-11-02.md", reason: "分支清理的內部存檔：引用本機 .git 備份索引與未落地的 WIP 設計，屬內部研發紀錄" },
  { path: "docs/first-pair-flow.md", reason: "首次配對流程的內部筆記，含配對狀態機與除錯步驟" },
  { path: "docs/first-pair-test.md", reason: "首次配對的測試紀錄，含實機與時序觀察" },
  { path: "Helpers/HomeBridge/", reason: "HomeKit 小幫手：靠開發者簽章（team DQ45KFVHJ8）與描述檔才能執行，本來就無法包進公開的公證版 App；原始碼暫不進公開快照" },
  { path: "docs/hellogithub-submission.md", reason: "對外投稿的文案與策略，含審核風險判讀與身份段落的取捨，不隨原始碼公開" },
  { path: "docs/plans/", reason: "內部規劃與合規矩陣（CarPlay Ultra 規劃、2.0 逐句合規、HPDS 設計系統），含未公開的下一步排序" },
  { path: "promo/", reason: "宣傳片 Remotion 工程與素材（企劃見 docs/promo/ 同屬內部）；渲染產物可再生，不入公開倉庫" },
  { path: "site/dist/", reason: "建置產物" },
  { path: "site/.wrangler/", reason: "wrangler 本地快取（wrangler-account.json 含帳號信箱，曾誤提交過一次）" },
  { path: "site/node_modules/", reason: "依賴" },
  { path: "site/deployment.json", reason: "部署收據，含 Pages 預覽網址" },
  { path: "docs/promo/", reason: "宣傳片的內部企劃、稽核與修訂紀錄，不公開" },
  { path: "site/public/media/film/homeplay-44s.mp4", reason: "44 秒演示影片 8.8 MB，超過公開快照單檔上限；官網從本機部署、GitHub README 連到 B 站" },
  { path: "Helpers/HomeBridge/", reason: "HomeKit 小幫手：只能開發簽名、不隨公開版發布（1.0 也不列家庭模組），等 2.0 定案再決定是否公開" },
  { path: "docs/prompt-f5-pinch-handoff.md", reason: "給 agent 的內部交接提示" },
  { path: "docs/prompt-homeplay-handoff-2026-10-21.md", reason: "給 agent 的內部交接提示" },
  { path: "docs/prompt-macplay-lessons.md", reason: "給 agent 的內部交接提示" },
  { path: "docs/prompt-polish-handoff.md", reason: "給 agent 的內部交接提示" },
  { path: "tooling/public-overlay/", reason: "覆蓋檔本身不以原路徑出現，內容改放到快照根目錄" },
];

/** 快照裡用覆蓋檔取代或新增的檔案：快照路徑 → 倉庫裡的來源。 */
export const overlays = {
  "README.md": "tooling/public-overlay/README.md",
  "README.en.md": "tooling/public-overlay/README.en.md",
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

/** 單檔大小上限（位元組）。超過的多半是誤收的影片或建置產物；10MB 放行官網的 44s 演示片（8.4MB，f013cfc）。 */
export const maxFileBytes = 10 * 1024 * 1024;

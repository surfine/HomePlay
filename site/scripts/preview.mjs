// HomePlay 2.0 Preview 頁的文案：三種語言同一個形狀；版面在 preview-page.mjs。
// 數字對過 Sources/homeplay-pet：錶面 = FaceStyle.lineup（12 款），App = AppRegistry.all（21 個），即時動態最多三個，ClioTalk 每月上限預設 5 美元。
// 要權限、要小幫手、預設關閉的照實寫在限制與註腳。畫面都是 homeplay-pet --demo-official 現拍的示範資料（scripts/render-preview.sh → encode-preview.py）。
// 寫法：句子短，先說它做什麼。不用破折號，不用「不僅……更……」，不加評價詞。
export const PREVIEW_SLUG = '2.0/';

// 錶面牆的順序 = FaceStyle.lineup（換錶面時的順序）
export const FACES = ['island', 'photos', 'modular', 'analog', 'flow', 'weather', 'world', 'calendar', 'growth', 'black', 'system6', 'cluster'];

const zhHant = {
  title: 'HomePlay 2.0 Preview：整套 HomeView，放上你的 Mac',
  description: 'HomePlay 2.0 Preview 在 Mac 桌寵上加了主畫面、小工具、十二款錶面、二十一個 App、語音助手 ClioTalk，也能認出家人。現在可以下載 beta 8 試用。',
  ogTitle: 'HomePlay 2.0 Preview',
  ogAlt: 'HomePlay 桌寵的螢幕，眼睛 👀 在膠囊裡',
  keywords: 'HomePlay 2.0, HomeView, Liquid Glass, Mac 桌寵, ClioTalk, 即時動態, 開源',
  navLabel: '2.0 的段落',
  navHome: '首頁',
  nav: [['home', '主畫面'], ['faces', '錶面'], ['apps', 'App'], ['cliotalk', 'ClioTalk'], ['family', '家人'], ['preview', '限制']],
  homeNav: '2.0 Preview',
  navHistory: '小工具往事',
  historyCta: { label: '下一篇', eyebrow: '從歷史回到現在', title: 'HomePlay 2.0 Preview', body: '最後一章講到 HomeView。HomePlay 2.0 把它的介面搬到 Mac 上：主畫面、即時動態、ClioTalk，還能認出家人。', link: '看 2.0 Preview' },
  kicker: 'HomePlay 2.0 Preview',
  h1: '<span class="l">整套 HomeView，</span> <span class="l">放上你的 Mac。</span>',
  lede: 'HomePlay 是 Mac 上的桌寵，有一雙會看著你的眼睛。2.0 加上主畫面、小工具、十二款錶面、二十一個 App 和語音助手 ClioTalk。',
  ctaBeta: '下載 2.0 beta 8',
  stable: '想要穩定的版本，<a href="{href}">下載 1.0.6</a>。',
  heroNote: 'beta 8 是測試版，可能有錯。需要 macOS 14 以上和 Apple 晶片。頁面上的畫面都是 App 用示範資料拍的。',
  heroAlt: { face: 'HomePlay 機身，螢幕是島錶面：10:09 與裝著 👀 的膠囊', home: 'HomePlay 機身，螢幕是 Liquid Glass 主畫面：App 圖示與照片小工具' },
  home: {
    title: '主畫面照 iPhone 的規則。',
    lede: '長按半秒，圖示開始抖動。把一個圖示拖到另一個上面，就變成資料夾。小工具有四種大小，同樣大小的可以疊成一疊。',
    switchLabel: '主畫面外觀',
    looks: [['light', '淺色', '淺色主畫面，圖示是白底'], ['dark', '深色', '深色主畫面，圖示是深底'], ['clear', '透明', '透明主畫面，圖示像一片片玻璃'], ['tinted', '著色', '著色主畫面，圖示染成同一個色調']],
    shots: [
      ['widget-gallery', '小工具有十二種內容，例如照片、天氣和行事曆。', '小工具庫：智慧型堆疊、照片、天氣、行事曆、提醒事項、音樂等'],
      ['home-edit', '圖示抖動時，按「−」移除，按「+」加小工具。', '編輯中的主畫面：每個圖示左上角有減號'],
      ['home-library', '最後一頁是 App 資料庫，可以搜尋。', 'App 資料庫：上方搜尋列，下面是依類別排好的 App 圖示'],
    ],
  },
  system: {
    title: '正在進行的事，顯示在眼睛旁邊。',
    lede: '計時器、音樂和通話的進度，顯示在 👀 膠囊兩側。同時最多三個。',
    shots: [
      ['la-compact', '計時器在膠囊右邊倒數。', '錶面下方的膠囊：左邊是 👀，右邊是計時器'],
      ['la-expanded', '點一下展開，看完會自己收回。', '主畫面上方展開的音樂即時動態，有播放控制'],
      ['cc', '從右上角往下滑，打開控制中心。', '控制中心：正在播放、音量與亮度滑桿、專注、訪客模式、CarPlay 等按鈕'],
    ],
  },
  faces: {
    title: '十二款錶面，眼睛一直是那雙 👀。',
    lede: '長按螢幕就能換錶面。島錶面還能選 1988、2002 或 2026 年的樣子。',
    names: { island: '島', photos: '照片', modular: '模組', analog: 'Typograph', flow: 'Flow', weather: '天氣', world: '世界', calendar: '行事曆', growth: '陪伴的痕跡', black: '黑色', system6: 'System 6', cluster: '儀表' },
    altPrefix: '錶面：',
  },
  apps: {
    title: '二十一個內建 App。',
    lede: '天氣、計時器、音樂、訊息、家庭、Safari 和烹飪等，都照 HomeView 的版面重畫。字很大，站在房間另一頭也看得清楚。',
    shots: [
      ['app-weather-rain', '天氣。資料用概略位置向 Open-Meteo 查詢。', '天氣 App：台北市 22 度，下雨'],
      ['app-timers', '計時器。可以同時跑好幾個。', '計時器 App：義大利麵，還剩 4:31'],
      ['app-music', '音樂。有同步歌詞，歌詞向 LRCLIB 查詢。', '音樂 App：正在播放的歌曲與播放控制'],
      ['app-messages-confirm', '訊息。用說的回覆，送出前先唸給你聽。<sup><a href="#fn-1" aria-label="註 1">1</a></sup>', '訊息 App：要傳給朋友 B 嗎？下方有取消與傳送'],
      ['app-recipe-step', '烹飪。把食譜網頁拖進來，變成一步一步的大字。', '烹飪 App 的一個步驟，下方有計時按鈕'],
      ['app-home', '家庭。用 HomeKit 控制燈和門鎖。<sup><a href="#fn-2" aria-label="註 2">2</a></sup>', '家庭 App：燈、場景與門鎖的按鈕'],
      ['app-facetime', 'FaceTime。在桌寵上選人，由 Mac 撥出。', 'FaceTime App：最近通話與聯絡人列表'],
      ['app-intercom', '對講。按住說話，最長 30 秒。', '對講 App：黃色麥克風按鈕，按住說話'],
    ],
  },
  clio: {
    title: 'ClioTalk：開口問，它先問過你才做事。',
    lede: '從螢幕上緣中間往下滑，或按住 F5，就可以說話。語音在 Mac 上轉成文字，只有文字會送到 AI 模型。',
    shots: [
      ['clio-listen', '它在聽。聲音只留在記憶體，不存檔。', 'ClioTalk 正在聽，上方是 👀'],
      ['clio-answer', '它回答。你按「留下」，回答才會保存。', 'ClioTalk 的回答：行事曆上接下來的生日'],
      ['clio-confirm', '要加提醒或傳訊息時，它先唸一次。你說「好」，它才做。', 'ClioTalk 問：要加這個提醒嗎？下方有「好」與「取消」'],
    ],
    points: [
      '雲端模型用你自己的 Anthropic 或 DeepSeek 金鑰，金鑰存在鑰匙圈。',
      '也可以用 LM Studio 在本機跑模型，或在 macOS 26 以上用 Apple Intelligence。',
      '每月花費有上限，預設 5 美元。到上限就停。',
    ],
  },
  family: {
    title: '認得家人，也收好私人內容。',
    lede: 'HomePlay 用 Mac 的相機和 Apple Vision 認出家人，跟你說早安，換成你的主畫面。這個功能預設關閉。',
    alt: '錶面上方的問候卡：早安，Erica，認出你了',
    points: [
      '辨識在 Mac 上完成。只存臉部特徵的數字，不存照片。',
      '認不出的人和訪客模式只看到預設主畫面。',
      '訊息、照片和行事曆只給 Mac 的主人看。',
    ],
  },
  more: {
    title: '其他',
    items: [
      ['iPhone 與 iPad', '閒置的 iPhone 或 iPad 可以用 Safari 打開另一個 HomeView 畫面。只走家裡的區域網路。這個功能預設關閉。'],
      ['CarPlay', '1.0 的 CarPlay 接收器還在，現在是主畫面上的一個 App。'],
      ['三種語言', '繁體中文、簡體中文和英文。'],
      ['開源', '授權是 GPL-3.0-or-later，原始碼在 GitHub。'],
    ],
    history: '想知道小工具從哪裡來？',
    historyLink: '讀小工具往事',
  },
  preview: {
    title: '目前的限制',
    limits: [
      '需要 macOS 14 以上和 Apple 晶片。Liquid Glass、裝置端語音和模型，要 macOS 26 以上才完整。',
      '雲端的 ClioTalk 需要你自己的金鑰。',
      'FaceTime 和「尋找」交給 Mac 上的 App。對講不是 HomePod 對講。',
      '人臉辨識不是生物辨識等級的安全機制。',
      'iPhone 和 iPad 顯示的是網頁，不是 App。Mac 要保持喚醒。',
    ],
    ctaTitle: '試試 2.0 beta 8',
    ctaBody: '遇到問題，請到 GitHub 回報。兩個版本都有 Developer ID 簽名，並通過 Apple 公證。',
    footnotesLabel: '註腳',
    footnotes: [
      '訊息需要給 HomePlay「完全取用磁碟」權限才能讀取。送出用 AppleScript。沒有確認送達時，它會告訴你，不會自動重送。',
      '家庭需要另外安裝「HomePlay Home」小幫手。公開版還沒附這個小幫手。沒安裝時，它會說明原因，並打開 Mac 的「家庭」App。',
    ],
    trademark: 'HomeView、CarPlay、Siri、Apple Intelligence、FaceTime 與 Apple 是 Apple Inc. 的商標。HomePlay 是獨立的開源專案，與 Apple 無關，也未經 Apple 授權或認可。',
  },
};

const zhHans = {
  title: 'HomePlay 2.0 Preview：整套 HomeView，放上你的 Mac',
  description: 'HomePlay 2.0 Preview 在 Mac 桌宠上加了主屏幕、小组件、十二款表盘、二十一个 App、语音助手 ClioTalk，也能认出家人。现在可以下载 beta 8 试用。',
  ogTitle: 'HomePlay 2.0 Preview',
  ogAlt: 'HomePlay 桌宠的屏幕，眼睛 👀 在胶囊里',
  keywords: 'HomePlay 2.0, HomeView, Liquid Glass, Mac 桌宠, ClioTalk, 实时活动, 开源',
  navLabel: '2.0 的段落',
  navHome: '首页',
  nav: [['home', '主屏幕'], ['faces', '表盘'], ['apps', 'App'], ['cliotalk', 'ClioTalk'], ['family', '家人'], ['preview', '限制']],
  homeNav: '2.0 Preview',
  navHistory: '小工具往事',
  historyCta: { label: '下一篇', eyebrow: '从历史回到现在', title: 'HomePlay 2.0 Preview', body: '最后一章讲到 HomeView。HomePlay 2.0 把它的界面搬到 Mac 上：主屏幕、实时活动、ClioTalk，还能认出家人。', link: '看 2.0 Preview' },
  kicker: 'HomePlay 2.0 Preview',
  h1: '<span class="l">整套 HomeView，</span> <span class="l">放上你的 Mac。</span>',
  lede: 'HomePlay 是 Mac 上的桌宠，有一双会看着你的眼睛。2.0 加上主屏幕、小组件、十二款表盘、二十一个 App 和语音助手 ClioTalk。',
  ctaBeta: '下载 2.0 beta 8',
  stable: '想要稳定的版本，<a href="{href}">下载 1.0.6</a>。',
  heroNote: 'beta 8 是测试版，可能有错。需要 macOS 14 及以上和 Apple 芯片。页面上的画面都是 App 用示例数据拍的。',
  heroAlt: { face: 'HomePlay 机身，屏幕是岛表盘：10:09 与装着 👀 的胶囊', home: 'HomePlay 机身，屏幕是 Liquid Glass 主屏幕：App 图标与照片小组件' },
  home: {
    title: '主屏幕按 iPhone 的规则来。',
    lede: '长按半秒，图标开始抖动。把一个图标拖到另一个上面，就变成文件夹。小组件有四种尺寸，同样尺寸的可以叠成一叠。',
    switchLabel: '主屏幕外观',
    looks: [['light', '浅色', '浅色主屏幕，图标是白底'], ['dark', '深色', '深色主屏幕，图标是深底'], ['clear', '透明', '透明主屏幕，图标像一片片玻璃'], ['tinted', '着色', '着色主屏幕，图标染成同一个色调']],
    shots: [
      ['widget-gallery', '小组件有十二种内容，比如照片、天气和日历。', '小组件库：智能叠放、照片、天气、日历、提醒事项、音乐等'],
      ['home-edit', '图标抖动时，点“−”移除，点“+”加小组件。', '编辑中的主屏幕：每个图标左上角有减号'],
      ['home-library', '最后一页是 App 资源库，可以搜索。', 'App 资源库：上方搜索栏，下面是按类别排好的 App 图标'],
    ],
  },
  system: {
    title: '正在进行的事，显示在眼睛旁边。',
    lede: '计时器、音乐和通话的进度，显示在 👀 胶囊两侧。同时最多三个。',
    shots: [
      ['la-compact', '计时器在胶囊右边倒计时。', '表盘下方的胶囊：左边是 👀，右边是计时器'],
      ['la-expanded', '点一下展开，看完会自己收回。', '主屏幕上方展开的音乐实时活动，有播放控制'],
      ['cc', '从右上角往下滑，打开控制中心。', '控制中心：正在播放、音量与亮度滑块、专注、访客模式、CarPlay 等按钮'],
    ],
  },
  faces: {
    title: '十二款表盘，眼睛一直是那双 👀。',
    lede: '长按屏幕就能换表盘。岛表盘还能选 1988、2002 或 2026 年的样子。',
    names: { island: '岛', photos: '照片', modular: '模块', analog: 'Typograph', flow: 'Flow', weather: '天气', world: '世界', calendar: '日历', growth: '陪伴的痕迹', black: '黑色', system6: 'System 6', cluster: '仪表' },
    altPrefix: '表盘：',
  },
  apps: {
    title: '二十一个内置 App。',
    lede: '天气、计时器、音乐、信息、家庭、Safari 和烹饪等，都按 HomeView 的版式重画。字很大，站在房间另一头也看得清。',
    shots: [
      ['app-weather-rain', '天气。数据用大致位置向 Open-Meteo 查询。', '天气 App：台北市 22 度，下雨'],
      ['app-timers', '计时器。可以同时跑好几个。', '计时器 App：意大利面，还剩 4:31'],
      ['app-music', '音乐。有同步歌词，歌词向 LRCLIB 查询。', '音乐 App：正在播放的歌曲与播放控制'],
      ['app-messages-confirm', '信息。用说的回复，发送前先念给你听。<sup><a href="#fn-1" aria-label="注 1">1</a></sup>', '信息 App：要发给朋友 B 吗？下方有取消与发送'],
      ['app-recipe-step', '烹饪。把菜谱网页拖进来，变成一步一步的大字。', '烹饪 App 的一个步骤，下方有计时按钮'],
      ['app-home', '家庭。用 HomeKit 控制灯和门锁。<sup><a href="#fn-2" aria-label="注 2">2</a></sup>', '家庭 App：灯、场景与门锁的按钮'],
      ['app-facetime', 'FaceTime。在桌宠上选人，由 Mac 拨出。', 'FaceTime App：最近通话与联系人列表'],
      ['app-intercom', '对讲。按住说话，最长 30 秒。', '对讲 App：黄色麦克风按钮，按住说话'],
    ],
  },
  clio: {
    title: 'ClioTalk：开口问，它先问过你才做事。',
    lede: '从屏幕上沿中间往下滑，或按住 F5，就可以说话。语音在 Mac 上转成文字，只有文字会发给 AI 模型。',
    shots: [
      ['clio-listen', '它在听。声音只留在内存，不存文件。', 'ClioTalk 正在听，上方是 👀'],
      ['clio-answer', '它回答。你点“留下”，回答才会保存。', 'ClioTalk 的回答：日历上接下来的生日'],
      ['clio-confirm', '要加提醒或发信息时，它先念一遍。你说“好”，它才做。', 'ClioTalk 问：要添加这个提醒吗？下方有“好”与“取消”'],
    ],
    points: [
      '云端模型用你自己的 Anthropic 或 DeepSeek 密钥，密钥存在钥匙串。',
      '也可以用 LM Studio 在本机跑模型，或在 macOS 26 及以上用 Apple 智能。',
      '每月花费有上限，默认 5 美元。到上限就停。',
    ],
  },
  family: {
    title: '认得家人，也收好私人内容。',
    lede: 'HomePlay 用 Mac 的摄像头和 Apple Vision 认出家人，跟你说早上好，换成你的主屏幕。这个功能默认关闭。',
    alt: '表盘上方的问候卡：早安，Erica，认出你了',
    points: [
      '识别在 Mac 上完成。只存面部特征的数字，不存照片。',
      '认不出的人和访客模式只看到默认主屏幕。',
      '信息、照片和日历只给 Mac 的主人看。',
    ],
  },
  more: {
    title: '其他',
    items: [
      ['iPhone 与 iPad', '闲置的 iPhone 或 iPad 可以用 Safari 打开另一个 HomeView 画面。只走家里的局域网。这个功能默认关闭。'],
      ['CarPlay', '1.0 的 CarPlay 接收器还在，现在是主屏幕上的一个 App。'],
      ['三种语言', '繁体中文、简体中文和英文。'],
      ['开源', '许可证是 GPL-3.0-or-later，源代码在 GitHub。'],
    ],
    history: '想知道小工具从哪里来？',
    historyLink: '读小工具往事',
  },
  preview: {
    title: '目前的限制',
    limits: [
      '需要 macOS 14 及以上和 Apple 芯片。Liquid Glass、设备端语音和模型，要 macOS 26 及以上才完整。',
      '云端的 ClioTalk 需要你自己的密钥。',
      'FaceTime 和“查找”交给 Mac 上的 App。对讲不是 HomePod 对讲。',
      '人脸识别不是生物识别级别的安全机制。',
      'iPhone 和 iPad 显示的是网页，不是 App。Mac 要保持唤醒。',
    ],
    ctaTitle: '试试 2.0 beta 8',
    ctaBody: '遇到问题，请到 GitHub 反馈。两个版本都有 Developer ID 签名，并通过 Apple 公证。',
    footnotesLabel: '脚注',
    footnotes: [
      '信息需要给 HomePlay“完全磁盘访问权限”才能读取。发送用 AppleScript。没有确认送达时，它会告诉你，不会自动重发。',
      '家庭需要另外安装“HomePlay Home”小助手。公开版还没附这个小助手。没安装时，它会说明原因，并打开 Mac 的“家庭”App。',
    ],
    trademark: 'HomeView、CarPlay、Siri、Apple 智能、FaceTime 与 Apple 是 Apple Inc. 的商标。HomePlay 是独立的开源项目，与 Apple 无关，也未经 Apple 授权或认可。',
  },
};

const en = {
  title: 'HomePlay 2.0 Preview: all of HomeView, on your Mac',
  description: 'HomePlay 2.0 Preview adds a Home Screen, widgets, twelve faces, twenty-one apps, the ClioTalk voice assistant and family recognition to the Mac desk pet. Beta 8 is ready to try.',
  ogTitle: 'HomePlay 2.0 Preview',
  ogAlt: 'The HomePlay screen, with the 👀 eyes in their capsule',
  keywords: 'HomePlay 2.0, HomeView, Liquid Glass, Mac desk pet, ClioTalk, Live Activities, open source',
  navLabel: 'Sections of 2.0',
  navHome: 'Home',
  nav: [['home', 'Home Screen'], ['faces', 'Faces'], ['apps', 'Apps'], ['cliotalk', 'ClioTalk'], ['family', 'Family'], ['preview', 'Limits']],
  homeNav: '2.0 Preview',
  navHistory: 'Widget history',
  historyCta: { label: 'Next', eyebrow: 'From history to today', title: 'HomePlay 2.0 Preview', body: 'The last chapter ends with HomeView. HomePlay 2.0 brings its interface to the Mac: a Home Screen, Live Activities, ClioTalk, and family recognition.', link: 'See 2.0 Preview' },
  kicker: 'HomePlay 2.0 Preview',
  h1: '<span class="l">All of HomeView.</span> <span class="l">On your Mac.</span>',
  lede: 'HomePlay is a desk pet for the Mac, with a pair of eyes that watch you. 2.0 adds a Home Screen, widgets, twelve faces, twenty-one apps and the ClioTalk voice assistant.',
  ctaBeta: 'Download 2.0 beta 8',
  stable: 'For a stable version, <a href="{href}">download 1.0.6</a>.',
  heroNote: 'Beta 8 is a test version and may have bugs. It needs macOS 14 or later on Apple silicon. The app captured every screen on this page with demo data.',
  heroAlt: { face: 'The HomePlay device showing the Island face: 10:09 and the capsule holding 👀', home: 'The HomePlay device showing the Liquid Glass Home Screen: app icons and a Photos widget' },
  home: {
    title: 'A Home Screen with the iPhone’s rules.',
    lede: 'Hold for half a second and the icons jiggle. Drop one icon on another to make a folder. Widgets come in four sizes, and widgets of the same size can stack.',
    switchLabel: 'Home Screen appearance',
    looks: [['light', 'Light', 'Light Home Screen with white icons'], ['dark', 'Dark', 'Dark Home Screen with dark icons'], ['clear', 'Clear', 'Clear Home Screen with glass icons'], ['tinted', 'Tinted', 'Tinted Home Screen with icons in one tone']],
    shots: [
      ['widget-gallery', 'Widgets show twelve kinds of content, such as Photos, Weather and Calendar.', 'The widget gallery: Smart Stack, Photos, Weather, Calendar, Reminders, Music and more'],
      ['home-edit', 'While the icons jiggle, tap − to remove and + to add a widget.', 'The Home Screen in edit mode, a minus badge on each icon'],
      ['home-library', 'The last page is the App Library. You can search it.', 'App Library: a search field above apps grouped by category'],
    ],
  },
  system: {
    title: 'What is happening now shows next to the eyes.',
    lede: 'Timers, music and calls show their progress on each side of the 👀 capsule. Up to three show at once.',
    shots: [
      ['la-compact', 'A timer counts down on the right of the capsule.', 'The capsule under the face: 👀 on the left, a timer on the right'],
      ['la-expanded', 'Tap to expand. It closes on its own.', 'An expanded music Live Activity at the top of the Home Screen, with playback controls'],
      ['cc', 'Swipe down from the top right to open Control Center.', 'Control Center: Now Playing, volume and brightness sliders, Focus, Guest mode, CarPlay and more'],
    ],
  },
  faces: {
    title: 'Twelve faces, and the same 👀 on every one.',
    lede: 'Touch and hold the screen to change the face. The Island face can also look like 1988, 2002 or 2026.',
    names: { island: 'Island', photos: 'Photos', modular: 'Modular', analog: 'Typograph', flow: 'Flow', weather: 'Weather', world: 'World', calendar: 'Calendar', growth: 'Days Together', black: 'Black', system6: 'System 6', cluster: 'Gauges' },
    altPrefix: 'Face: ',
  },
  apps: {
    title: 'Twenty-one built-in apps.',
    lede: 'Weather, Timers, Music, Messages, Home, Safari, Now Cooking and more all use HomeView’s layouts. The type is big, so you can read it from across the room.',
    shots: [
      ['app-weather-rain', 'Weather. Forecasts come from Open-Meteo, using your approximate location.', 'Weather app: Taipei, 22 degrees and rain'],
      ['app-timers', 'Timers. You can run several at once.', 'Timers app: Pasta, 4:31 left'],
      ['app-music', 'Music. It shows synced lyrics from LRCLIB.', 'Music app: the song that is playing, with playback controls'],
      ['app-messages-confirm', 'Messages. Reply by voice. It reads the message to you before it sends.<sup><a href="#fn-1" aria-label="Note 1">1</a></sup>', 'Messages app: send this to Friend B? With Cancel and Send buttons'],
      ['app-recipe-step', 'Now Cooking. Drag in a recipe page and get big, step-by-step text.', 'A step in the Now Cooking app, with a timer button'],
      ['app-home', 'Home. Control lights and locks through HomeKit.<sup><a href="#fn-2" aria-label="Note 2">2</a></sup>', 'Home app: buttons for lights, scenes and a door lock'],
      ['app-facetime', 'FaceTime. Pick a person on the pet. Your Mac places the call.', 'FaceTime app: recent calls and contacts'],
      ['app-intercom', 'Intercom. Hold to talk, for up to 30 seconds.', 'Intercom app: a yellow microphone button, hold to talk'],
    ],
  },
  clio: {
    title: 'ClioTalk: ask out loud. It checks with you before it acts.',
    lede: 'Swipe down from the top centre of the screen, or hold F5, and talk. The Mac turns your speech into text. Only the text goes to the AI model.',
    shots: [
      ['clio-listen', 'It listens. The audio stays in memory and is never saved.', 'ClioTalk listening, with 👀 at the top'],
      ['clio-answer', 'It answers. The answer stays only if you tap Keep.', 'ClioTalk answering with the next birthdays on the calendar'],
      ['clio-confirm', 'Before it adds a reminder or sends a message, it reads it aloud. It acts after you say OK.', 'ClioTalk asking: add this reminder? With OK and Cancel buttons'],
    ],
    points: [
      'Cloud models use your own Anthropic or DeepSeek key. The key stays in the Keychain.',
      'You can also run a model on your Mac with LM Studio, or use Apple Intelligence on macOS 26 or later.',
      'Spending has a monthly limit. The default is five US dollars. At the limit, it stops.',
    ],
  },
  family: {
    title: 'It knows your family, and keeps private things private.',
    lede: 'HomePlay uses the Mac’s camera and Apple Vision to recognise your family, say good morning and switch to your Home Screen. This is off by default.',
    alt: 'A greeting card above the face: Good morning, Erica. Recognized you.',
    points: [
      'Recognition runs on the Mac. It stores only numbers that describe a face, not photos.',
      'People it does not recognise, and Guest mode, see only the default Home Screen.',
      'Messages, photos and calendars are for the Mac’s owner only.',
    ],
  },
  more: {
    title: 'Also in 2.0',
    items: [
      ['iPhone and iPad', 'A spare iPhone or iPad can open another HomeView screen in Safari. It stays on your home network. This is off by default.'],
      ['CarPlay', 'The CarPlay receiver from 1.0 is still here. It is now an app on the Home Screen.'],
      ['Three languages', 'Traditional Chinese, Simplified Chinese and English.'],
      ['Open source', 'The licence is GPL-3.0-or-later. The source code is on GitHub.'],
    ],
    history: 'Where did widgets come from?',
    historyLink: 'Read the history',
  },
  preview: {
    title: 'Limits today',
    limits: [
      'It needs macOS 14 or later on Apple silicon. Liquid Glass, on-device speech and on-device models are complete only on macOS 26 or later.',
      'ClioTalk with a cloud model needs your own key.',
      'The apps on your Mac handle FaceTime and Find My. Intercom is not HomePod Intercom.',
      'Face recognition is not biometric-grade security.',
      'iPhone and iPad show a web page, not an app. The Mac must stay awake.',
    ],
    ctaTitle: 'Try 2.0 beta 8',
    ctaBody: 'If you find a bug, tell us on GitHub. Both versions are signed with Developer ID and notarised by Apple.',
    footnotesLabel: 'Footnotes',
    footnotes: [
      'Messages needs Full Disk Access for HomePlay before it can read your conversations. Sending uses AppleScript. If it cannot confirm delivery, it tells you. It never resends on its own.',
      'Home needs the separate HomePlay Home helper. The public build does not include it yet. Without it, the app explains why and opens Home on your Mac.',
    ],
    trademark: 'HomeView, CarPlay, Siri, Apple Intelligence, FaceTime and Apple are trademarks of Apple Inc. HomePlay is an independent open source project, not affiliated with, authorised or endorsed by Apple.',
  },
};

export const preview = { 'zh-Hant': zhHant, 'zh-Hans': zhHans, en };

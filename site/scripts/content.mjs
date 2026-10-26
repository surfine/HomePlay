// 所有文案都在這裡，三種語言同一個形狀；版面在 build.mjs。
// 字串裡只允許極少的行內標記（<code>、<span>、<b>），build 不再跳脫。
// 寫法：說人話（奧卡姆剃刀、ASD-STE100、ELI5）。先說它做了什麼、你會看到什麼；
// 一句一件事、主動語態、短句；不用「不只…而是…」、三連排比、反問和破折號；不寫沒驗證過的數字。
// 人文那一段（essay）的年份與人名都可查：Macintosh 1984 年發表會上自己說 hello；
// Mark Weiser 與 John Seely Brown 在 Xerox PARC 寫〈Designing Calm Technology〉（1995）。
export const origin = process.env.SITE_ORIGIN || 'https://homeplay.aaronlau.me';
export const github = 'https://github.com/surfine/HomePlay';
export const notice = `${github}/blob/main/NOTICE`;
// 固定檔名 + releases/latest/download：以後出新版，官網的下載按鈕不用跟著改。
export const releaseDownload = `${github}/releases/latest/download/HomePlay-macOS-arm64.zip`;
// 2.0 測試版：pre-release 不算 latest，所以寫明 tag 與檔名；出 beta 2 時改這一行
export const betaDownload = `${github}/releases/download/v2.0.0-beta.2/HomePlay-2.0-beta2-macOS-arm64.zip`;

const FACES = ['idle', 'happy', 'love', 'wink', 'thinking', 'annoyed', 'surprised', 'worried', 'sleepy', 'asleep'];
const FINISHES = ['g4', 'silver', 'starlight', 'rose', 'gray'];
export { FACES, FINISHES };

/** 站點的三種語言。code 同時是 hreflang；path 是網址；label 是語言切換上顯示的名字（用該語言自己的寫法）。 */
export const LANGS = [
  { key: 'zh-Hant', code: 'zh-Hant', path: '/', label: '繁體中文', locale: 'zh_TW' },
  { key: 'zh-Hans', code: 'zh-Hans', path: '/zh-hans/', label: '简体中文', locale: 'zh_CN' },
  { key: 'en', code: 'en', path: '/en/', label: 'English', locale: 'en_US' },
];

export const copy = {
  "zh-Hant": {
    lang: "zh-Hant",
    htmlLang: "zh-Hant-TW",
    locale: "zh_TW",
    path: "/",
    renders: "/media/renders/",
    og: "/media/og-v4.jpg",
    siteName: "HomePlay",
    title: "HomePlay：它會看著你，也能變成 CarPlay",
    ogTitle: "它會看著你，也能變成 CarPlay。",
    description: "Mac 上的開源桌寵，長得像 HomeView：一雙會看你的眼睛、十種表情、10 款錶面；用力按一下螢幕，就是 iPhone 的 CarPlay。",
    ogAlt: "HomePlay 桌寵：白色機身，螢幕上是時間和一雙眼睛",
    keywords: "HomePlay, Mac 桌寵, 桌面寵物, HomeView, CarPlay, macOS, 開源",
    skip: "跳到內容",
    navLabel: "主選單",
    langLabel: "語言",
    nav: [
      [
        "highlights",
        "它能做什麼"
      ],
      [
        "faces",
        "表情"
      ],
      [
        "styles",
        "錶面"
      ],
      [
        "carplay",
        "CarPlay"
      ],
      [
        "run",
        "下載"
      ]
    ],
    heroNew: {
      badge: "新",
      text: "2.0 Preview 出來了：整套 HomeView 介面，加上會等你開口的助手 ClioTalk"
    },
    h1: "<span class=\"l\">它會看著你，</span><span class=\"l glow\">也能變成 CarPlay。</span>",
    lede: "HomePlay 是 Mac 上的開源桌寵，長得像 HomeView。平常，它用一雙眼睛看著你；用力按一下螢幕，它就變成 iPhone 的 CarPlay。",
    viewSource: "看原始碼",
    download: "下載 App",
    downloadNote: "v1.0.2，macOS 14 以上，Apple 晶片。有 Developer ID 簽名、通過 Apple 公證，解壓就能打開。",
    heroNote: "v1.0.2 · macOS 14+ · Apple 晶片 · 已公證",
    heroLabel: "HomePlay 桌寵，目前的表情：{face}",
    faceNames: {
      idle: "平常",
      happy: "笑眼",
      love: "愛心",
      wink: "眨眼",
      thinking: "在想",
      annoyed: "不耐煩",
      surprised: "嚇一跳",
      worried: "擔心",
      sleepy: "睏",
      asleep: "睡著"
    },
    secEyebrow: {
      highlights: "它能做什麼",
      film: "44 秒",
      why: "設計",
      faces: "十種表情",
      styles: "錶面",
      carplay: "iPhone",
      spin: "機身",
      run: "開始",
      more: "接下來"
    },
    highlightsTitle: "四件事。",
    highlightsLede: "平常陪著你；需要它的時候，它就是 CarPlay。",
    highlights: [
      [
        "faces",
        "它會看著你",
        "一雙 👀，十種表情。",
        "你靠近，它看過來；游標停在它身上，它瞇眼笑；深夜放著不管，它打瞌睡。眼睛住在一顆膠囊裡，材質跟著錶面的年代換：純黑、黑透或 Liquid Glass。"
      ],
      [
        "tiles",
        "10 款錶面",
        "照 HomeView 的版式做。",
        "島、照片、模組、Typograph、Flow、天氣、行事曆、陪伴的痕跡、黑，還有 System 6。大時間是系統的 Liquid Glass；字體和顏色可以自己調，像 iOS 27 的鎖定畫面。"
      ],
      [
        "cable",
        "用力按，就是 CarPlay",
        "第一次插線，之後無線。",
        "iPhone 把真正的 CarPlay 畫面和聲音傳到這台小螢幕，點它就像在車上點。按住 F5，直接跟 iPhone 的 Siri 說話。"
      ],
      [
        "keys",
        "順手的小工具",
        "番茄鐘、正在播放、電量、下一個行程。",
        "F7 到 F9 直接切歌；視窗可以置頂，當 iPhone 曲庫的迷你播放器。"
      ]
    ],
    stylesTitle: "10 款，換個心情。",
    stylesLede: "滾動或按 ← → 換錶面；長按螢幕看全部。字體、顏色和膠囊在「設定 › 外觀」。",
    styles: [
      [
        "island",
        "島"
      ],
      [
        "flow",
        "Flow"
      ],
      [
        "modular",
        "模組"
      ],
      [
        "analog",
        "Typograph"
      ],
      [
        "weather",
        "天氣"
      ],
      [
        "calendar",
        "行事曆"
      ],
      [
        "growth",
        "陪伴的痕跡"
      ],
      [
        "system6",
        "System 6"
      ]
    ],
    devTitle: "開發者的話",
    dev: [
      "「👀」是我很喜歡的一個 emoji：興奮和期待都在裡面。唐老鴨也是我最愛的卡通角色，一雙靈動的大眼睛，呆萌呆萌的。",
      "在 AI 時代，我更想守住好奇心、想像力和判斷力。希望這隻桌寵帶給你一點樂趣。"
    ],
    devSign: "HomePlay 開發者",
    essayTitle: "為什麼是一雙眼睛？",
    essayLede: "因為一雙眼睛剛好夠說「我在」，又不必你回應。",
    essayClose: "大多數螢幕都在搶你的注意力。HomePlay 不一樣：它多半只是看著你；你靠近，它才亮起來；夜深了，它比你先睡。",
    eyesHint: "移動游標，它會看你；停一會兒，它就閉上眼睛。",
    eyesLabel: "一雙會跟著游標看的眼睛",
    facesTitle: "你做什麼，它都看在眼裡。",
    facesLede: "十種表情都來自眼睛的形狀。游標移到任一行，看它的反應。",
    facesLabel: "桌寵目前的表情：{face}",
    rows: [
      [
        "idle",
        "游標靠近",
        "眼珠跟著游標轉"
      ],
      [
        "happy",
        "停在它身上",
        "一秒多就笑瞇瞇"
      ],
      [
        "love",
        "一直停著",
        "四秒後冒出愛心"
      ],
      [
        "surprised",
        "抓起來轉",
        "嚇一跳，放手才笑"
      ],
      [
        "annoyed",
        "連點五下",
        "不耐煩，還會搖頭"
      ],
      [
        "thinking",
        "等 CarPlay 連線",
        "眼珠往上飄，在想"
      ],
      [
        "worried",
        "CarPlay 斷線",
        "擔心；連回來先笑一下"
      ],
      [
        "wink",
        "整點",
        "眨一下眼"
      ],
      [
        "sleepy",
        "深夜放著不管",
        "三分鐘後開始打瞌睡"
      ],
      [
        "asleep",
        "再過五分鐘",
        "睡著了，螢幕變暗、省電"
      ]
    ],
    carplayTitle: "用力按一下，就是 CarPlay。",
    carplayLede: "不是錄影，也不是假介面。iPhone 把真正的 CarPlay 畫面和聲音傳過來；你在這裡點一下，就像在車上點一下。聲音從 Mac 的喇叭出來。",
    pathLabel: "畫面怎麼傳過來",
    flow: [
      [
        "iPhone",
        "送出 CarPlay"
      ],
      [
        "HomePlay",
        "在 Mac 上接收"
      ],
      [
        "小螢幕",
        "顯示畫面、播放聲音"
      ]
    ],
    spinTitle: "拖著它，轉一圈。",
    spinLede: "照真機比例做：鐘形底座、不鏽鋼鉸鏈、往後仰 16° 的薄螢幕。拖一拖它，或拆開看看。",
    spinLabel: "HomePlay 機身，可以左右拖動旋轉",
    spinHint: "左右拖動它，或繼續往下捲",
    apart: "拆開看看",
    together: "組回去",
    apartAlt: "拆開成九個零件的 HomePlay",
    apartNote: "照 HomeView 的構造，由外往內九層；位置依 Apple 公布的規格。",
    apartParts: [
      "蓋板玻璃",
      "顯示面板",
      "電子框架 · A18",
      "顯示托盤",
      "不鏽鋼鉸鏈",
      "被動輻射器",
      "底座揚聲器模組",
      "低音單體",
      "底腳"
    ],
    runTitle: "下載。",
    runLede: "下載就能用。想自己編譯也可以。",
    firstStepsTitle: "第一次用，三步",
    firstSteps: [
      "下載、解壓，把 HomePlay 拖進「應用程式」，打開。",
      "用傳輸線把 iPhone 接上一次，在 iPhone 上點「信任」。",
      "用力按桌寵的螢幕，就是 CarPlay。之後拔線會自動轉無線；第一次沒轉過去，把 iPhone 的 Wi-Fi 關了再開一次。"
    ],
    buildTitle: "自己編譯（進階）",
    runList: [
      "macOS 14 以上的 Mac（下載版不用 Xcode）",
      "自己編譯要 Xcode 或 Swift 6",
      "只看桌寵：什麼都不用接",
      "要 CarPlay：一支 iPhone；第一次用線配對，無線要同一個 Wi-Fi"
    ],
    code: [
      [
        "c",
        "# 編譯"
      ],
      [
        "",
        "swift build -c release"
      ],
      [
        "",
        "B=.build/release"
      ],
      [
        "",
        ""
      ],
      [
        "c",
        "# 只開桌寵"
      ],
      [
        "",
        "$B/homeplay-pet"
      ],
      [
        "",
        ""
      ],
      [
        "c",
        "# 接 CarPlay：插著線走有線，沒插走無線"
      ],
      [
        "",
        "$B/homeplay-receiver --source auto --ssid '<Wi-Fi 名稱>' --port 8788"
      ],
      [
        "",
        "$B/homeplay-pet --endpoint ws://127.0.0.1:8788"
      ]
    ],
    copyCode: "複製",
    copied: "已複製",
    faqTitle: "常見問題",
    faq: [
      [
        "這是 Apple 的產品嗎？",
        "不是。HomePlay 是個人的實驗專案，跟 Apple 沒有關係，也沒有認證。CarPlay 和 HomeView 是 Apple Inc. 的商標，只用來說明它做什麼。"
      ],
      [
        "會吵我、吃資源嗎？",
        "不會。全螢幕 App 在前面時它會躲起來；沒人看時，秒針收起來，畫面幾乎不重畫。它自己不出聲，只有 CarPlay 播放時有聲音。"
      ],
      [
        "接 CarPlay 要準備什麼？",
        "一支 iPhone，和一條線（只有第一次要用）。App 帶公開的實驗配件身份，開箱即用，風險自負。目前只在 iOS 15 的 iPhone SE（第一代）和 iOS 27 的 iPhone 18 Pro 上測過。"
      ],
      [
        "天氣和行事曆會用我的資料嗎？",
        "天氣第一次出現時，問一次概略位置（Open-Meteo 查當地天氣）；行事曆要你在「設定」打開才讀，只顯示下一個行程。兩者都不會上傳。"
      ],
      [
        "下載的 App 安全嗎？",
        "有開發者的 Developer ID 簽名，通過 Apple 公證，Gatekeeper 認得。原始碼全公開，也可以自己編譯。"
      ],
      [
        "支援哪些語言？",
        "English、簡體中文、繁體中文。預設跟系統，「設定」裡可以換。"
      ],
      [
        "用什麼授權？",
        "GPL-3.0-or-later。CarPlay 連線參考 MacPlay 與 LIVI 的做法，用 Swift 重寫，致謝在 NOTICE。"
      ]
    ],
    footer: "HomePlay，GPL-3.0-or-later 開源。與 Apple Inc. 無關。",
    footerLinks: {
      github: "GitHub",
      notice: "NOTICE"
    },
    notFound: {
      title: "HomePlay：找不到這一頁",
      h1: "這一頁不在這裡。",
      body: "網址可能打錯了，或是這一頁已經搬走。",
      home: "回到首頁",
      homeHref: "/"
    },
    filmTitle: "看它怎麼陪你。",
    filmLede: "看著你、眨眼、夜裡睡著；用力按一下，變成真的 CarPlay。影片拍在 1.0 之前，有幾款錶面現在長得不一樣。",
    filmLabel: "HomePlay 44 秒演示影片",
    filmBili: "在 B 站看這支影片",
    moreTitle: "還有更多。",
    more20Eyebrow: "2.0 Preview",
    more20Title: "整套 HomeView，放上你的 Mac。",
    more20Body: "主畫面和小工具、十款錶面、十六個 App，還有會等你開口的助手 ClioTalk，也能認出家裡每個人。現在是 beta 1，免費下載。",
    more20Link: "看 2.0 Preview",
    more20Beta: "下載 2.0 beta 1",
    moreHistEyebrow: "長文",
    moreHistTitle: "小工具往事。",
    moreHistBody: "從 1984 年蘋果選單裡的計算機，講到今天的即時動態。六章，每章一件可以動手玩的展品；每個事實都有出處。",
    moreHistLink: "讀小工具往事"
  },
  "zh-Hans": {
    lang: "zh-Hans",
    htmlLang: "zh-Hans-CN",
    locale: "zh_CN",
    path: "/zh-hans/",
    renders: "/media/renders/zh-Hans/",
    og: "/media/og-zh-hans-v4.jpg",
    siteName: "HomePlay",
    title: "HomePlay：它会看着你，也能变成 CarPlay",
    ogTitle: "它会看着你，也能变成 CarPlay。",
    description: "Mac 上的开源桌宠，长得像 HomeView：一双会看你的眼睛、十种表情、10 款表盘；用力按一下屏幕，就是 iPhone 的 CarPlay。",
    ogAlt: "HomePlay 桌宠：白色机身，屏幕上是时间和一双眼睛",
    keywords: "HomePlay, Mac 桌宠, 桌面宠物, HomeView, CarPlay, macOS, 开源",
    skip: "跳到内容",
    navLabel: "主导航",
    langLabel: "语言",
    nav: [
      [
        "highlights",
        "它能做什么"
      ],
      [
        "faces",
        "表情"
      ],
      [
        "styles",
        "表盘"
      ],
      [
        "carplay",
        "CarPlay"
      ],
      [
        "run",
        "下载"
      ]
    ],
    heroNew: {
      badge: "新",
      text: "2.0 Preview 出来了：整套 HomeView 界面，加上会等你开口的助手 ClioTalk"
    },
    h1: "<span class=\"l\">它会看着你，</span><span class=\"l glow\">也能变成 CarPlay。</span>",
    lede: "HomePlay 是 Mac 上的开源桌宠，长得像 HomeView。平时，它用一双眼睛看着你；用力按一下屏幕，它就变成 iPhone 的 CarPlay。",
    viewSource: "看源代码",
    download: "下载 App",
    downloadNote: "v1.0.2，macOS 14 及以上，Apple 芯片。有 Developer ID 签名、通过 Apple 公证，解压就能打开。",
    heroNote: "v1.0.2 · macOS 14+ · Apple 芯片 · 已公证",
    heroLabel: "HomePlay 桌宠，当前的表情：{face}",
    faceNames: {
      idle: "平常",
      happy: "笑眼",
      love: "爱心",
      wink: "眨眼",
      thinking: "在想",
      annoyed: "不耐烦",
      surprised: "吓一跳",
      worried: "担心",
      sleepy: "困",
      asleep: "睡着"
    },
    secEyebrow: {
      highlights: "它能做什么",
      film: "44 秒",
      why: "设计",
      faces: "十种表情",
      styles: "表盘",
      carplay: "iPhone",
      spin: "机身",
      run: "开始",
      more: "接下来"
    },
    highlightsTitle: "四件事。",
    highlightsLede: "平时陪着你；需要它的时候，它就是 CarPlay。",
    highlights: [
      [
        "faces",
        "它会看着你",
        "一双 👀，十种表情。",
        "你靠近，它看过来；指针停在它身上，它眯眼笑；深夜放着不管，它打瞌睡。眼睛住在一颗胶囊里，材质跟着表盘的年代换：纯黑、黑透或 Liquid Glass。"
      ],
      [
        "tiles",
        "10 款表盘",
        "照 HomeView 的版式做。",
        "岛、照片、模块、Typograph、Flow、天气、日历、陪伴的痕迹、黑，还有 System 6。大时间是系统的 Liquid Glass；字体和颜色可以自己调，像 iOS 27 的锁定屏幕。"
      ],
      [
        "cable",
        "用力按，就是 CarPlay",
        "第一次插线，之后无线。",
        "iPhone 把真正的 CarPlay 画面和声音传到这台小屏幕，点它就像在车上点。按住 F5，直接和 iPhone 的 Siri 说话。"
      ],
      [
        "keys",
        "顺手的小工具",
        "番茄钟、正在播放、电量、下一个日程。",
        "F7 到 F9 直接切歌；窗口可以置顶，当 iPhone 曲库的迷你播放器。"
      ]
    ],
    stylesTitle: "10 款，换个心情。",
    stylesLede: "滚动或按 ← → 换表盘；长按屏幕看全部。字体、颜色和胶囊在「设置 › 外观」。",
    styles: [
      [
        "island",
        "岛"
      ],
      [
        "flow",
        "Flow"
      ],
      [
        "modular",
        "模块"
      ],
      [
        "analog",
        "Typograph"
      ],
      [
        "weather",
        "天气"
      ],
      [
        "calendar",
        "日历"
      ],
      [
        "growth",
        "陪伴的痕迹"
      ],
      [
        "system6",
        "System 6"
      ]
    ],
    devTitle: "开发者的话",
    dev: [
      "“👀”是我很喜欢的一个 emoji：兴奋和期待都在里面。唐老鸭也是我最爱的卡通角色，一双灵动的大眼睛，呆萌呆萌的。",
      "在 AI 时代，我更想守住好奇心、想象力和判断力。希望这只桌宠带给你一点乐趣。"
    ],
    devSign: "HomePlay 开发者",
    essayTitle: "为什么是一双眼睛？",
    essayLede: "因为一双眼睛刚好够说「我在」，又不需要你回应。",
    essayClose: "大多数屏幕都在抢你的注意力。HomePlay 不一样：它多半只是看着你；你靠近，它才亮起来；夜深了，它比你先睡。",
    eyesHint: "移动指针，它会看你；停一会儿，它就闭上眼睛。",
    eyesLabel: "一双会跟着指针看的眼睛",
    facesTitle: "你做什么，它都看在眼里。",
    facesLede: "十种表情都来自眼睛的形状。指针移到任意一行，看它的反应。",
    facesLabel: "桌宠当前的表情：{face}",
    rows: [
      [
        "idle",
        "指针靠近",
        "眼珠跟着指针转"
      ],
      [
        "happy",
        "停在它身上",
        "一秒多就笑眯眯"
      ],
      [
        "love",
        "一直停着",
        "四秒后冒出爱心"
      ],
      [
        "surprised",
        "抓起来转",
        "吓一跳，放手才笑"
      ],
      [
        "annoyed",
        "连点五下",
        "不耐烦，还会摇头"
      ],
      [
        "thinking",
        "等 CarPlay 连接",
        "眼珠往上飘，在想"
      ],
      [
        "worried",
        "CarPlay 断开",
        "担心；连回来先笑一下"
      ],
      [
        "wink",
        "整点",
        "眨一下眼"
      ],
      [
        "sleepy",
        "深夜放着不管",
        "三分钟后开始打瞌睡"
      ],
      [
        "asleep",
        "再过五分钟",
        "睡着了，屏幕变暗、省电"
      ]
    ],
    carplayTitle: "用力按一下，就是 CarPlay。",
    carplayLede: "不是录屏，也不是假界面。iPhone 把真正的 CarPlay 画面和声音传过来；你在这里点一下，就像在车上点一下。声音从 Mac 的扬声器出来。",
    pathLabel: "画面怎么传过来",
    flow: [
      [
        "iPhone",
        "发送 CarPlay"
      ],
      [
        "HomePlay",
        "在 Mac 上接收"
      ],
      [
        "小屏幕",
        "显示画面、播放声音"
      ]
    ],
    spinTitle: "拖着它，转一圈。",
    spinLede: "照真机比例做：钟形底座、不锈钢铰链、向后仰 16° 的薄屏幕。拖一拖它，或者拆开看看。",
    spinLabel: "HomePlay 机身，可以左右拖动旋转",
    spinHint: "左右拖动它，或继续往下滚动",
    apart: "拆开看看",
    together: "装回去",
    apartAlt: "拆成九个零件的 HomePlay",
    apartNote: "照 HomeView 的构造，由外向内九层；位置依照 Apple 公布的规格。",
    apartParts: [
      "盖板玻璃",
      "显示面板",
      "电子框架 · A18",
      "显示托盘",
      "不锈钢铰链",
      "被动辐射器",
      "底座扬声器模组",
      "低音单元",
      "底脚"
    ],
    runTitle: "下载。",
    runLede: "下载就能用。想自己编译也可以。",
    firstStepsTitle: "第一次用，三步",
    firstSteps: [
      "下载、解压，把 HomePlay 拖进「应用程序」，打开。",
      "用数据线把 iPhone 接上一次，在 iPhone 上点「信任」。",
      "用力按桌宠的屏幕，就是 CarPlay。之后拔线会自动转无线；第一次没转过去，把 iPhone 的 Wi-Fi 关了再开一次。"
    ],
    buildTitle: "自己编译（进阶）",
    runList: [
      "macOS 14 以上的 Mac（下载版不用 Xcode）",
      "自己编译要 Xcode 或 Swift 6",
      "只看桌宠：什么都不用接",
      "要 CarPlay：一部 iPhone；第一次用线配对，无线要同一个 Wi-Fi"
    ],
    code: [
      [
        "c",
        "# 编译"
      ],
      [
        "",
        "swift build -c release"
      ],
      [
        "",
        "B=.build/release"
      ],
      [
        "",
        ""
      ],
      [
        "c",
        "# 只开桌宠"
      ],
      [
        "",
        "$B/homeplay-pet"
      ],
      [
        "",
        ""
      ],
      [
        "c",
        "# 接 CarPlay：插着线走有线，没插走无线"
      ],
      [
        "",
        "$B/homeplay-receiver --source auto --ssid '<Wi-Fi 名称>' --port 8788"
      ],
      [
        "",
        "$B/homeplay-pet --endpoint ws://127.0.0.1:8788"
      ]
    ],
    copyCode: "复制",
    copied: "已复制",
    faqTitle: "常见问题",
    faq: [
      [
        "这是 Apple 的产品吗？",
        "不是。HomePlay 是个人的实验项目，和 Apple 没有关系，也没有认证。CarPlay 和 HomeView 是 Apple Inc. 的商标，只用来说明它做什么。"
      ],
      [
        "会打扰我、占资源吗？",
        "不会。全屏 App 在前面时它会躲起来；没人看时，秒针收起来，画面几乎不重绘。它自己不出声，只有 CarPlay 播放时有声音。"
      ],
      [
        "连 CarPlay 要准备什么？",
        "一部 iPhone，和一根线（只有第一次要用）。App 带公开的实验配件身份，开箱即用，风险自负。目前只在 iOS 15 的 iPhone SE（第 1 代）和 iOS 27 的 iPhone 18 Pro 上测过。"
      ],
      [
        "天气和日历会用我的数据吗？",
        "天气第一次出现时，问一次大致位置（Open-Meteo 查当地天气）；日历要你在「设置」打开才会读，只显示下一个日程。两者都不会上传。"
      ],
      [
        "下载的 App 安全吗？",
        "有开发者的 Developer ID 签名，通过 Apple 公证，Gatekeeper 认得。源代码全公开，也可以自己编译。"
      ],
      [
        "支持哪些语言？",
        "English、简体中文、繁體中文。默认跟系统，「设置」里可以换。"
      ],
      [
        "用什么许可证？",
        "GPL-3.0-or-later。CarPlay 连接参考 MacPlay 与 LIVI 的做法，用 Swift 重写，致谢在 NOTICE。"
      ]
    ],
    footer: "HomePlay，GPL-3.0-or-later 开源。与 Apple Inc. 无关。",
    footerLinks: {
      github: "GitHub",
      notice: "NOTICE"
    },
    notFound: {
      title: "HomePlay：找不到这一页",
      h1: "这一页不在这里。",
      body: "网址可能打错了，或者这一页已经搬走。",
      home: "回到首页",
      homeHref: "/zh-hans/"
    },
    filmTitle: "看它怎么陪你。",
    filmLede: "看着你、眨眼、夜里睡着；用力按一下，变成真的 CarPlay。视频拍在 1.0 之前，有几款表盘现在长得不一样。",
    filmLabel: "HomePlay 44 秒演示视频",
    filmBili: "在 B 站看这支视频",
    moreTitle: "还有更多。",
    more20Eyebrow: "2.0 Preview",
    more20Title: "整套 HomeView，放上你的 Mac。",
    more20Body: "主屏幕和小组件、十款表盘、十六个 App，还有会等你开口的助手 ClioTalk，也能认出家里每个人。现在是 beta 1，免费下载。",
    more20Link: "看 2.0 Preview",
    more20Beta: "下载 2.0 beta 1",
    moreHistEyebrow: "长文",
    moreHistTitle: "小工具往事。",
    moreHistBody: "从 1984 年苹果菜单里的计算机，讲到今天的实时活动。六章，每章一件可以动手玩的展品；每个事实都有出处。",
    moreHistLink: "读小工具往事"
  },
  en: {
    lang: "en",
    htmlLang: "en",
    locale: "en_US",
    path: "/en/",
    renders: "/media/renders/en/",
    og: "/media/og-en-v4.jpg",
    siteName: "HomePlay",
    title: "HomePlay: it watches you, and it becomes CarPlay",
    ogTitle: "It watches you, and it becomes CarPlay.",
    description: "An open-source desk pet for the Mac that looks like HomeView: a pair of eyes that watch you, ten expressions and 10 faces. One firm press, and it is your iPhone’s CarPlay.",
    ogAlt: "HomePlay desk pet: a white body with the time and a pair of eyes on the screen",
    keywords: "HomePlay, Mac desk pet, desktop pet, HomeView, CarPlay, macOS, open source",
    skip: "Skip to content",
    navLabel: "Main",
    langLabel: "Language",
    nav: [
      [
        "highlights",
        "What it does"
      ],
      [
        "faces",
        "Expressions"
      ],
      [
        "styles",
        "Faces"
      ],
      [
        "carplay",
        "CarPlay"
      ],
      [
        "run",
        "Download"
      ]
    ],
    heroNew: {
      badge: "New",
      text: "2.0 Preview is out: the full HomeView interface, plus ClioTalk, an assistant that waits for you to ask"
    },
    h1: "<span class=\"l\">It watches you.</span> <span class=\"l glow\">Press for CarPlay.</span>",
    lede: "HomePlay is an open-source desk pet for the Mac that looks like HomeView. Most of the time it watches you with a pair of eyes. Press the screen firmly, and it becomes your iPhone’s CarPlay.",
    viewSource: "View source",
    download: "Download the app",
    downloadNote: "v1.0.2, macOS 14 or later, Apple silicon. Signed with a Developer ID and notarized by Apple, so you can unzip it and open it.",
    heroNote: "v1.0.2 · macOS 14+ · Apple silicon · Notarized",
    heroLabel: "HomePlay desk pet, current expression: {face}",
    faceNames: {
      idle: "Idle",
      happy: "Happy",
      love: "Love",
      wink: "Wink",
      thinking: "Thinking",
      annoyed: "Annoyed",
      surprised: "Surprised",
      worried: "Worried",
      sleepy: "Sleepy",
      asleep: "Asleep"
    },
    secEyebrow: {
      highlights: "What it does",
      film: "44 seconds",
      why: "Design",
      faces: "Ten expressions",
      styles: "Faces",
      carplay: "iPhone",
      spin: "The body",
      run: "Get started",
      more: "What’s next"
    },
    highlightsTitle: "Four things.",
    highlightsLede: "Company most of the time; CarPlay when you need it.",
    highlights: [
      [
        "faces",
        "It watches you",
        "One pair of 👀, ten expressions.",
        "Come closer and it looks over. Rest your pointer on it and it smiles. Leave it alone late at night and it dozes off. The eyes live in a capsule that matches the face’s era: solid black, smoked, or Liquid Glass."
      ],
      [
        "tiles",
        "10 faces",
        "Laid out like Apple’s HomeView faces.",
        "Island, Photos, Modular, Typograph, Flow, Weather, Calendar, Days Together, Black, and System 6. The big time is the system’s own Liquid Glass, and you pick its font and color the way you do on the iOS 27 Lock Screen."
      ],
      [
        "cable",
        "Press firmly for CarPlay",
        "Plug in once, then it’s wireless.",
        "Your iPhone sends real CarPlay video and sound to the little screen, and tapping it works like tapping in a car. Hold F5 to talk to your iPhone’s Siri."
      ],
      [
        "keys",
        "Handy extras",
        "Focus timer, Now Playing, battery, next event.",
        "F7 to F9 skip tracks, and the window can float on top like a mini player for your iPhone’s library."
      ]
    ],
    stylesTitle: "10 of them, one for every mood.",
    stylesLede: "Scroll or press ← → to change faces; press and hold the screen to see them all. Font, color and the capsule are in Settings › Appearance.",
    styles: [
      [
        "island",
        "Island"
      ],
      [
        "flow",
        "Flow"
      ],
      [
        "modular",
        "Modular"
      ],
      [
        "analog",
        "Typograph"
      ],
      [
        "weather",
        "Weather"
      ],
      [
        "calendar",
        "Calendar"
      ],
      [
        "growth",
        "Days Together"
      ],
      [
        "system6",
        "System 6"
      ]
    ],
    devTitle: "From the developer",
    dev: [
      "👀 is one of my favorite emoji: excitement and anticipation, all in one. Donald Duck is one of my favorite cartoon characters too, big lively eyes, a bit goofy.",
      "In the age of AI I want to hold on to curiosity, imagination and judgment. I hope this little pet brings you some fun."
    ],
    devSign: "The HomePlay developer",
    essayTitle: "Why a pair of eyes?",
    essayLede: "Because a pair of eyes is just enough to say “I’m here” without asking you for anything.",
    essayClose: "Most screens compete for your attention. HomePlay does not: mostly it just watches you. It lights up when you come near, and it falls asleep before you do.",
    eyesHint: "Move your pointer and it looks at you. Stop for a moment and it closes its eyes.",
    eyesLabel: "A pair of eyes that follow your pointer",
    facesTitle: "It notices what you do.",
    facesLede: "All ten expressions come from the shape of the eyes. Hover over a row to see how it reacts.",
    facesLabel: "Desk pet, current expression: {face}",
    rows: [
      [
        "idle",
        "Your pointer comes near",
        "Its eyes follow the pointer"
      ],
      [
        "happy",
        "You rest on it",
        "A smile after a second or so"
      ],
      [
        "love",
        "You stay a while",
        "Hearts after four seconds"
      ],
      [
        "surprised",
        "You grab it and spin",
        "A start, then a smile when you let go"
      ],
      [
        "annoyed",
        "You click five times",
        "Annoyed, with a shake of the head"
      ],
      [
        "thinking",
        "CarPlay is connecting",
        "Eyes drift up while it thinks"
      ],
      [
        "worried",
        "CarPlay drops",
        "Worried; a smile when it’s back"
      ],
      [
        "wink",
        "On the hour",
        "A quick wink"
      ],
      [
        "sleepy",
        "Left alone late at night",
        "Dozes off after three minutes"
      ],
      [
        "asleep",
        "Five minutes more",
        "Asleep: the screen dims to save power"
      ]
    ],
    carplayTitle: "One firm press, and it’s CarPlay.",
    carplayLede: "Not a recording, and not a mock-up. Your iPhone sends real CarPlay video and sound over; a tap here is a tap in the car. Sound comes out of your Mac’s speakers.",
    pathLabel: "How the picture gets here",
    flow: [
      [
        "iPhone",
        "Sends CarPlay"
      ],
      [
        "HomePlay",
        "Receives it on your Mac"
      ],
      [
        "Little screen",
        "Shows the picture, plays the sound"
      ]
    ],
    spinTitle: "Give it a spin.",
    spinLede: "Built to the real proportions: a bell-shaped base, a stainless steel hinge, and a thin screen tilted back 16°. Drag it around, or take it apart.",
    spinLabel: "HomePlay body; drag left or right to turn it",
    spinHint: "Drag it left or right, or keep scrolling",
    apart: "Take It Apart",
    together: "Put It Back",
    apartAlt: "HomePlay taken apart into nine pieces",
    apartNote: "Nine layers from the outside in, following HomeView’s construction and Apple’s published specs.",
    apartParts: [
      "Cover glass",
      "Display panel",
      "Electronics frame · A18",
      "Display tray",
      "Stainless steel hinge",
      "Passive radiators",
      "Base speaker module",
      "Woofer",
      "Foot"
    ],
    runTitle: "Download.",
    runLede: "Download it and you’re set. Building it yourself works too.",
    firstStepsTitle: "First time: three steps",
    firstSteps: [
      "Download, unzip, drag HomePlay into Applications and open it.",
      "Connect your iPhone with a cable once, then tap Trust on the iPhone.",
      "Press firmly on the pet’s screen to enter CarPlay. After that it reconnects wirelessly on its own. If it doesn’t the first time, turn the iPhone’s Wi-Fi off and on once."
    ],
    buildTitle: "Build from source (advanced)",
    runList: [
      "A Mac on macOS 14 or later (the download needs no Xcode)",
      "Building from source: Xcode or the Swift 6 toolchain",
      "Just the pet: nothing else",
      "For CarPlay: an iPhone; pair once over USB, and wireless needs the same Wi-Fi"
    ],
    code: [
      [
        "c",
        "# Build"
      ],
      [
        "",
        "swift build -c release"
      ],
      [
        "",
        "B=.build/release"
      ],
      [
        "",
        ""
      ],
      [
        "c",
        "# Just the pet"
      ],
      [
        "",
        "$B/homeplay-pet"
      ],
      [
        "",
        ""
      ],
      [
        "c",
        "# CarPlay: wired if plugged in, wireless if not"
      ],
      [
        "",
        "$B/homeplay-receiver --source auto --ssid '<Wi-Fi name>' --port 8788"
      ],
      [
        "",
        "$B/homeplay-pet --endpoint ws://127.0.0.1:8788"
      ]
    ],
    copyCode: "Copy",
    copied: "Copied",
    faqTitle: "Questions",
    faq: [
      [
        "Is this an Apple product?",
        "No. HomePlay is a personal experiment with no connection to or certification from Apple. CarPlay and HomeView are trademarks of Apple Inc., used here only to describe what it does."
      ],
      [
        "Will it bother me or slow my Mac down?",
        "No. It hides when a full-screen app is in front. When nobody is looking, the second hands go away and the screen barely redraws. The pet itself makes no sound; you only hear CarPlay when it plays."
      ],
      [
        "What do I need for CarPlay?",
        "An iPhone, and a cable for the first time only. The app ships with a public, experimental accessory identity, so it works out of the box, at your own risk. So far it has been tested on an iPhone SE (1st generation) on iOS 15 and an iPhone 18 Pro on iOS 27."
      ],
      [
        "Do Weather and Calendar use my data?",
        "The first time the Weather face appears, it asks once for your approximate location (Open-Meteo). Calendar is read only after you turn it on in Settings, and the next event stays on this Mac. Neither is sent anywhere."
      ],
      [
        "Is the downloaded app safe?",
        "It’s signed with the developer’s Developer ID and notarized by Apple, so Gatekeeper recognizes it. The source is public, and you can build it yourself."
      ],
      [
        "Which languages does it speak?",
        "English, 简体中文 and 繁體中文. It follows the system by default; you can switch in Settings."
      ],
      [
        "What’s the license?",
        "GPL-3.0-or-later. The CarPlay connection follows the approach of MacPlay and LIVI, rewritten in Swift; credits are in NOTICE."
      ]
    ],
    footer: "HomePlay, open source under GPL-3.0-or-later. Not affiliated with Apple Inc.",
    footerLinks: {
      github: "GitHub",
      notice: "NOTICE"
    },
    notFound: {
      title: "HomePlay: page not found",
      h1: "This page is not here.",
      body: "The address may be mistyped, or the page has moved.",
      home: "Back to the home page",
      homeHref: "/en/"
    },
    filmTitle: "See how it keeps you company.",
    filmLede: "It watches you, blinks and falls asleep at night; press firmly and it becomes real CarPlay. Filmed before 1.0, so a few faces look different now.",
    filmLabel: "HomePlay 44-second demo film",
    filmBili: "Watch it on Bilibili",
    moreTitle: "There’s more.",
    more20Eyebrow: "2.0 Preview",
    more20Title: "The whole HomeView, on your Mac.",
    more20Body: "A home screen with widgets, ten faces, sixteen apps, and ClioTalk, an assistant that waits for you to ask. It recognizes each person in the house too. Now in beta 1, free to download.",
    more20Link: "See the 2.0 Preview",
    more20Beta: "Download 2.0 beta 1",
    moreHistEyebrow: "Long read",
    moreHistTitle: "A history of widgets.",
    moreHistBody: "From the Calculator in the 1984 Apple menu to today’s Live Activities. Six chapters, one playable exhibit each, and a source for every fact.",
    moreHistLink: "Read the history"
  }
};

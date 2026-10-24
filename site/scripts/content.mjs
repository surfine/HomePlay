// 所有文案都在這裡，三種語言同一個形狀；版面在 build.mjs。
// 字串裡只允許極少的行內標記（<code>、<span>），build 不再跳脫。
// 寫法：說人話。先說它做了什麼、你會看到什麼，再說怎麼做到；不寫沒驗證過的數字。
// 人文那一段（essay）的年份與人名都可查：Macintosh 1984 年發表會上自己說 hello；
// Mark Weiser 與 John Seely Brown 在 Xerox PARC 寫〈Designing Calm Technology〉（1995）。
export const origin = process.env.SITE_ORIGIN || 'https://homeplay.aaronlau.me';
export const github = 'https://github.com/surfine/HomePlay';
export const notice = `${github}/blob/main/NOTICE`;
// 固定檔名 + releases/latest/download：以後出新版，官網的下載按鈕不用跟著改。
export const releaseDownload = `${github}/releases/latest/download/HomePlay-macOS-arm64.zip`;

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
    title: "HomePlay：它會看著你，並將 CarPlay 帶到 Mac 上",
    ogTitle: "它會看著你，並將 CarPlay 帶到 Mac 上。",
    description: "HomePlay 是 Mac 上的開源桌寵，長得像 HomeView：一雙會看你的眼睛、十種表情、10 款錶面；用力按一下螢幕，就是 iPhone 的 CarPlay。",
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
        "spin",
        "轉一圈"
      ],
      [
        "run",
        "下載"
      ]
    ],
    githubLabel: "GitHub",
    h1: "<span>它會看著你，</span><span>並將 CarPlay</span><span>帶到 Mac 上。</span>",
    lede: "一台放在 Mac 桌面上的 HomeView。它有一雙會看你的眼睛；用力按一下，它就變成 iPhone 的 CarPlay。",
    viewSource: "看原始碼",
    download: "下載 App",
    downloadNote: "v1.0.1，macOS 14 以上，Apple 晶片。有 Developer ID 簽名並通過 Apple 公證，解壓後直接打開。",
    heroNote: "v1.0.1 · macOS 14+ · Apple 晶片 · 已公證",
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
    highlightsTitle: "它能做什麼。",
    highlightsLede: "平常陪著你，需要的時候就是 CarPlay。",
    highlights: [
      [
        "faces",
        "它會看著你",
        "一雙 👀，十種表情。",
        "你靠近，它好奇地看過來；游標停在它身上，它笑瞇瞇；深夜放著不管，它會打瞌睡。眼睛住在一顆膠囊裡，膠囊跟著錶面的年代換材質：純黑、黑透或 Liquid Glass。"
      ],
      [
        "tiles",
        "10 款錶面",
        "照 HomeView 官方的版式做。",
        "島、照片、模組、Typograph（可換浮雕）、Flow、天氣、行事曆、陪伴的痕跡、黑，還有 System 6（三種版式）。大時間是系統的 Liquid Glass，字體和顏色可以像 iOS 27 鎖定畫面那樣自己調。"
      ],
      [
        "cable",
        "用力按，就是 CarPlay",
        "第一次插線，之後無線。",
        "iPhone 把真正的 CarPlay 畫面和聲音傳到這台小螢幕，你在上面點，就像在車上點。按住 F5，直接跟 iPhone 的 Siri 說話。"
      ],
      [
        "keys",
        "順手的小工具",
        "番茄鐘、正在播放、電量、下一個行程。",
        "F7 到 F9 媒體鍵直接切歌；視窗可以置頂，當成 iPhone 曲庫的迷你播放器。"
      ]
    ],
    stylesTitle: "10 款錶面，換個心情。",
    stylesLede: "滾動滑鼠滾輪或按 ← →，就能換錶面；長按螢幕可以看全部。字體、顏色和膠囊在「設定 › 外觀」裡。",
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
      "「👀」是我很喜歡的一個 emoji，可以用來表達興奮和期待。唐老鴨也是我最喜愛的卡通角色之一，一雙靈動的大眼睛，呆萌呆萌的，可愛極了。",
      "我覺得在 AI 時代，保有好奇心、釋放想像力、發揮創造力、保持判斷力，以及練習與人協作，都非常重要。希望 HomePlay 這隻桌寵，能帶給大家一點樂趣。"
    ],
    devSign: "HomePlay 開發者",
    essayTitle: "為什麼是一雙眼睛？",
    essayLede: "因為一雙眼睛剛好夠說「我在」，又不必要你回應。",
    essayClose: "大多數螢幕都在搶你的注意力。HomePlay 反過來：它大部分時間只是看著你，不出聲；你靠近，它才亮起來；你專心工作，它不吵；夜深了，它比你先睡。",
    eyesHint: "移動游標，它會看你；停一會兒，它就閉上眼睛。",
    eyesLabel: "一雙會跟著游標看的眼睛",
    facesTitle: "你做什麼，它都看在眼裡。",
    facesLede: "十種表情全靠眼睛的形狀。把游標移到下面任一行，看看它的反應。",
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
    carplayTitle: "用力按一下，它就變成 CarPlay。",
    carplayLede: "不是錄影，也不是畫一個假介面。iPhone 把真正的 CarPlay 畫面和聲音傳到這台小螢幕；你在上面點一下，就像在車上點一下。聲音從 Mac 的喇叭出來。",
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
    spinLede: "照真機的比例做：鐘形底座、不鏽鋼鉸鏈、往後仰 16° 的薄螢幕。拖一拖它，或拆開看看裡面。",
    spinLabel: "HomePlay 機身，可以左右拖動旋轉",
    spinHint: "左右拖動它，或繼續往下捲",
    apart: "拆開看看",
    together: "組回去",
    apartAlt: "拆開成九個零件的 HomePlay",
    apartNote: "照 HomeView 真正的構造，由外往內拆成九層；位置依 Apple 公布的規格。",
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
    runLede: "下載 App 就能用。想自己編譯也可以。",
    firstStepsTitle: "第一次用，三步",
    firstSteps: [
      "下載、解壓，把 HomePlay 拖進「應用程式」，打開。",
      "用傳輸線把 iPhone 接到 Mac 一次，在 iPhone 上點「信任」和「配對」。",
      "用力按桌寵的螢幕，進入 CarPlay。之後拔掉線，它會自己用無線連；第一次沒轉過去的話，在 iPhone 的控制中心把 Wi-Fi 關掉再打開一次。"
    ],
    buildTitle: "自己編譯（進階）",
    runList: [
      "一台 macOS 14 以上的 Mac（下載版不需要 Xcode）",
      "自己編譯：Xcode 或 Swift 6 工具鏈",
      "只看桌寵：什麼都不用接",
      "要用 CarPlay：一支 iPhone；第一次用 USB 線配對一次，無線還要同一個 Wi-Fi"
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
        "不是。HomePlay 是個人實驗專案，跟 Apple 沒有關係，也沒有任何認證。CarPlay 與 HomeView 是 Apple Inc. 的商標，這裡只用來說明它做的是什麼。"
      ],
      [
        "會吵我、吃資源嗎？",
        "不會。全螢幕 App 在前面時它會躲起來；沒人看的時候，秒針收起來，畫面幾乎不重畫。桌寵本身不出聲，只有 CarPlay 播放時才有聲音。"
      ],
      [
        "接 CarPlay 需要什麼？",
        "一支 iPhone，和一條傳輸線（只在第一次）。App 自帶公開的實驗性配件身份，開箱即用，使用風險自負。目前只在 iOS 15 的 iPhone SE（第 1 代）和 iOS 27 的 iPhone 18 Pro 上測過。第一次拔線後如果沒有轉成無線，在 iPhone 的控制中心把 Wi-Fi 關開一次就好，之後不用再做。"
      ],
      [
        "天氣和行事曆會用到我的資料嗎？",
        "天氣錶面第一次出現時，會問你概略位置，用來查當地天氣（Open-Meteo）。行事曆要你在「設定」裡打開才會讀，只在這台 Mac 上顯示下一個行程。兩者都不會上傳到別的地方。"
      ],
      [
        "下載的 App 安全嗎？",
        "它用開發者的 Developer ID 簽名，並通過 Apple 公證，Gatekeeper 認得這個簽名。原始碼全部公開，也可以自己編譯。"
      ],
      [
        "支援哪些語言？",
        "English、简体中文、繁體中文。預設跟著系統，也可以在「設定」裡換。"
      ],
      [
        "用什麼授權？",
        "GPL-3.0-or-later。CarPlay 連線的部分參考 MacPlay 與 LIVI 的做法，用 Swift 重新寫過，致謝寫在 NOTICE。"
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
    filmTitle: "44 秒，看它怎麼陪你。",
    filmLede: "看著你、眨眼、夜裡睡著；用力按一下，變成真的 CarPlay。影片拍在 1.0 之前，有幾款錶面現在長得不一樣。",
    filmLabel: "HomePlay 44 秒演示影片",
    filmBili: "在 B 站看這支影片"
  },
  "zh-Hans": {
    lang: "zh-Hans",
    htmlLang: "zh-Hans-CN",
    locale: "zh_CN",
    path: "/zh-hans/",
    renders: "/media/renders/zh-Hans/",
    og: "/media/og-zh-hans-v4.jpg",
    siteName: "HomePlay",
    title: "HomePlay：它会看着你，并将 CarPlay 带到 Mac 上",
    ogTitle: "它会看着你，并将 CarPlay 带到 Mac 上。",
    description: "HomePlay 是 Mac 上的开源桌宠，长得像 HomeView：一双会看你的眼睛、十种表情、10 款表盘；用力按一下屏幕，就是 iPhone 的 CarPlay。",
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
        "spin",
        "转一圈"
      ],
      [
        "run",
        "下载"
      ]
    ],
    githubLabel: "GitHub",
    h1: "<span>它会看着你，</span><span>并将 CarPlay</span><span>带到 Mac 上。</span>",
    lede: "一台放在 Mac 桌面上的 HomeView。它有一双会看你的眼睛；用力按一下，它就变成 iPhone 的 CarPlay。",
    viewSource: "看源代码",
    download: "下载 App",
    downloadNote: "v1.0.1，macOS 14 及以上，Apple 芯片。有 Developer ID 签名并通过 Apple 公证，解压后直接打开。",
    heroNote: "v1.0.1 · macOS 14+ · Apple 芯片 · 已公证",
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
    highlightsTitle: "它能做什么。",
    highlightsLede: "平时陪着你，需要的时候就是 CarPlay。",
    highlights: [
      [
        "faces",
        "它会看着你",
        "一双 👀，十种表情。",
        "你靠近，它好奇地看过来；指针停在它身上，它笑眯眯；深夜放着不管，它会打瞌睡。眼睛住在一颗胶囊里，胶囊跟着表盘的年代换材质：纯黑、黑透或 Liquid Glass。"
      ],
      [
        "tiles",
        "10 款表盘",
        "照 HomeView 官方的版式做。",
        "岛、照片、模块、Typograph（可换浮雕）、Flow、天气、日历、陪伴的痕迹、黑色，还有 System 6（三种版式）。大时间是系统的 Liquid Glass，字体和颜色可以像 iOS 27 锁定屏幕那样自己调。"
      ],
      [
        "cable",
        "用力按，就是 CarPlay",
        "第一次插线，之后无线。",
        "iPhone 把真正的 CarPlay 画面和声音传到这台小屏幕，你在上面点，就像在车上点。按住 F5，直接和 iPhone 的 Siri 说话。"
      ],
      [
        "keys",
        "顺手的小工具",
        "番茄钟、正在播放、电量、下一个日程。",
        "F7 到 F9 媒体键直接切歌；窗口可以置顶，当成 iPhone 曲库的迷你播放器。"
      ]
    ],
    stylesTitle: "10 款表盘，换个心情。",
    stylesLede: "滚动鼠标滚轮或按 ← →，就能换表盘；长按屏幕可以看全部。字体、颜色和胶囊在「设置 › 外观」里。",
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
      "“👀”是我很喜欢的一个 emoji，可以用来表达兴奋和期待。唐老鸭也是我最喜爱的卡通角色之一，一双灵动的大眼睛，呆萌呆萌的，可爱极了。",
      "私以为在 AI 时代，拥有好奇心、释放想象力、发挥创造力、保持判断力和锻炼协同能力是至关重要的。希望 HomePlay 这只桌宠能带给大家一些乐趣。"
    ],
    devSign: "HomePlay 开发者",
    essayTitle: "为什么是一双眼睛？",
    essayLede: "因为一双眼睛刚好够说「我在」，又不需要你回应。",
    essayClose: "大多数屏幕都在抢你的注意力。HomePlay 反过来：它大部分时间只是看着你，不出声；你靠近，它才亮起来；你专心工作，它不打扰；夜深了，它比你先睡。",
    eyesHint: "移动指针，它会看你；停一会儿，它就闭上眼睛。",
    eyesLabel: "一双会跟着指针看的眼睛",
    facesTitle: "你做什么，它都看在眼里。",
    facesLede: "十种表情全靠眼睛的形状。把指针移到下面任意一行，看看它的反应。",
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
    carplayTitle: "用力按一下，它就变成 CarPlay。",
    carplayLede: "不是录屏，也不是画一个假界面。iPhone 把真正的 CarPlay 画面和声音传到这台小屏幕；你在上面点一下，就像在车上点一下。声音从 Mac 的扬声器出来。",
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
    spinLede: "照真机的比例做：钟形底座、不锈钢铰链、向后仰 16° 的薄屏幕。拖一拖它，或者拆开看看里面。",
    spinLabel: "HomePlay 机身，可以左右拖动旋转",
    spinHint: "左右拖动它，或继续往下滚动",
    apart: "拆开看看",
    together: "装回去",
    apartAlt: "拆成九个零件的 HomePlay",
    apartNote: "照 HomeView 真实的构造，由外向内拆成九层；位置依照 Apple 公布的规格。",
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
    runLede: "下载 App 就能用。想自己编译也可以。",
    firstStepsTitle: "第一次用，三步",
    firstSteps: [
      "下载、解压，把 HomePlay 拖进「应用程序」，打开。",
      "用数据线把 iPhone 连到 Mac 一次，在 iPhone 上点「信任」和「配对」。",
      "用力按桌宠的屏幕，进入 CarPlay。之后拔掉线，它会自己用无线连接；第一次没切过去的话，在 iPhone 的控制中心把 Wi-Fi 关掉再打开一次。"
    ],
    buildTitle: "自己编译（进阶）",
    runList: [
      "一台 macOS 14 以上的 Mac（下载版不需要 Xcode）",
      "自己编译：Xcode 或 Swift 6 工具链",
      "只看桌宠：什么都不用接",
      "要用 CarPlay：一部 iPhone；第一次用 USB 线配对一次，无线还要同一个 Wi-Fi"
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
        "不是。HomePlay 是个人实验项目，和 Apple 没有关系，也没有任何认证。CarPlay 与 HomeView 是 Apple Inc. 的商标，这里只用来说明它做的是什么。"
      ],
      [
        "会打扰我、占资源吗？",
        "不会。全屏 App 在前面时它会躲起来；没人看的时候，秒针收起来，画面几乎不重绘。桌宠本身不出声，只有 CarPlay 播放时才有声音。"
      ],
      [
        "连 CarPlay 需要什么？",
        "一部 iPhone，和一根数据线（只在第一次）。App 自带公开的实验性配件身份，开箱即用，使用风险自负。目前只在 iOS 15 的 iPhone SE（第 1 代）和 iOS 27 的 iPhone 18 Pro 上测过。第一次拔线后如果没有切到无线，在 iPhone 的控制中心把 Wi-Fi 关开一次就好，之后不用再做。"
      ],
      [
        "天气和日历会用到我的数据吗？",
        "天气表盘第一次出现时，会问你大致位置，用来查当地天气（Open-Meteo）。日历要你在「设置」里打开才会读取，只在这台 Mac 上显示下一个日程。两者都不会上传到别处。"
      ],
      [
        "下载的 App 安全吗？",
        "它用开发者的 Developer ID 签名，并通过 Apple 公证，Gatekeeper 认得这个签名。源代码全部公开，也可以自己编译。"
      ],
      [
        "支持哪些语言？",
        "English、简体中文、繁體中文。默认跟随系统，也可以在「设置」里切换。"
      ],
      [
        "用什么许可证？",
        "GPL-3.0-or-later。CarPlay 连接的部分参考了 MacPlay 与 LIVI 的做法，用 Swift 重新写过，致谢写在 NOTICE。"
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
    filmTitle: "44 秒，看它怎么陪你。",
    filmLede: "看着你、眨眼、夜里睡着；用力按一下，变成真的 CarPlay。视频拍在 1.0 之前，有几款表盘现在长得不一样。",
    filmLabel: "HomePlay 44 秒演示视频",
    filmBili: "在 B 站看这支视频"
  },
  en: {
    lang: "en",
    htmlLang: "en",
    locale: "en_US",
    path: "/en/",
    renders: "/media/renders/en/",
    og: "/media/og-en-v4.jpg",
    siteName: "HomePlay",
    title: "HomePlay: it watches you, and brings CarPlay to your Mac",
    ogTitle: "It watches you, and brings CarPlay to your Mac.",
    description: "HomePlay is an open-source desk pet for the Mac that looks like HomeView: a pair of eyes that watch you, ten expressions and 10 faces. Force Click the screen and it becomes your iPhone’s CarPlay.",
    ogAlt: "HomePlay desk pet: a white body with the time and a pair of eyes on the screen",
    keywords: "HomePlay, Mac desk pet, desktop pet, HomeView, CarPlay, macOS, open source",
    skip: "Skip to content",
    navLabel: "Main",
    langLabel: "Language",
    nav: [
      [
        "highlights",
        "What It Does"
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
        "spin",
        "Spin It"
      ],
      [
        "run",
        "Download"
      ]
    ],
    githubLabel: "GitHub",
    h1: "<span>It watches you,</span> <span>and brings CarPlay to your Mac.</span>",
    lede: "A HomeView that lives on your Mac’s desktop. It has a pair of eyes that watch you, and one firm press turns it into your iPhone’s CarPlay.",
    viewSource: "View source",
    download: "Download the app",
    downloadNote: "v1.0.1, macOS 14 or later, Apple silicon. Signed with a Developer ID and notarized by Apple, so you can unzip it and open it.",
    heroNote: "v1.0.1 · macOS 14+ · Apple silicon · Notarized",
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
    highlightsTitle: "What it does.",
    highlightsLede: "Keeps you company most of the time; becomes CarPlay when you need it.",
    highlights: [
      [
        "faces",
        "It watches you",
        "One pair of 👀, ten expressions.",
        "Come closer and it looks over, curious. Rest your pointer on it and it smiles. Leave it alone late at night and it dozes off. The eyes live in a capsule that matches the face’s era: solid black, smoked, or Liquid Glass."
      ],
      [
        "tiles",
        "10 faces",
        "Laid out like Apple’s HomeView faces.",
        "Island, Photos, Modular, Typograph (with an Embossed option), Flow, Weather, Calendar, Days Together, Black, and System 6 (three layouts). The big time is the system’s own Liquid Glass, and you can pick its font and color the way you do on the iOS 27 Lock Screen."
      ],
      [
        "cable",
        "Press firmly for CarPlay",
        "Plug in once, then it’s wireless.",
        "Your iPhone sends real CarPlay video and sound to the little screen, and tapping it works like tapping the screen in a car. Hold F5 to talk to your iPhone’s Siri."
      ],
      [
        "keys",
        "Handy extras",
        "Focus timer, Now Playing, battery, next event.",
        "F7 to F9 skip tracks, and the window can float on top like a mini player for your iPhone’s library."
      ]
    ],
    stylesTitle: "10 faces, one for every mood.",
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
      "👀 is one of my favorite emoji, for excitement and anticipation. Donald Duck is one of my favorite cartoon characters too: big lively eyes, a bit goofy, adorable.",
      "I believe that in the age of AI, staying curious, freeing your imagination, being creative, keeping your judgment and learning to work together matter more than ever. I hope this little desk pet brings you some fun."
    ],
    devSign: "The HomePlay developer",
    essayTitle: "Why a pair of eyes?",
    essayLede: "Because a pair of eyes is just enough to say “I’m here” without asking you for anything.",
    essayClose: "Most screens compete for your attention. HomePlay does the opposite: most of the time it just watches, quietly. It lights up when you come near, stays out of the way while you work, and falls asleep before you do.",
    eyesHint: "Move your pointer and it looks at you. Stop for a moment and it closes its eyes.",
    eyesLabel: "A pair of eyes that follow your pointer",
    facesTitle: "It notices what you do.",
    facesLede: "All ten expressions come from the shape of the eyes. Hover over a row below to see how it reacts.",
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
    carplayTitle: "Press firmly, and it becomes CarPlay.",
    carplayLede: "Not a recording, and not a mock-up. Your iPhone sends real CarPlay video and sound to this little screen; a tap here is a tap in the car. Sound comes out of your Mac’s speakers.",
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
    apartNote: "Nine layers from the outside in, following HomeView's real construction and Apple's published specs.",
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
    runLede: "Download the app and you’re set. Building it yourself works too.",
    firstStepsTitle: "First time: three steps",
    firstSteps: [
      "Download, unzip, drag HomePlay into Applications and open it.",
      "Connect your iPhone to the Mac with a cable once, then tap Trust and Pair on the iPhone.",
      "Press firmly on the pet’s screen to enter CarPlay. After that you can unplug, and it reconnects wirelessly on its own. If it doesn’t the first time, turn Wi-Fi off and on once in the iPhone’s Control Center."
    ],
    buildTitle: "Build from source (advanced)",
    runList: [
      "A Mac on macOS 14 or later (the download needs no Xcode)",
      "Building from source: Xcode or the Swift 6 toolchain",
      "Just the pet: nothing else",
      "For CarPlay: an iPhone; pair once over USB, and wireless also needs the same Wi-Fi"
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
        "An iPhone, and a cable for the first time only. The app ships with a public, experimental accessory identity, so it works out of the box. Use it at your own risk. So far it has only been tested on an iPhone SE (1st generation) on iOS 15 and an iPhone 18 Pro on iOS 27. If it doesn’t switch to wireless the first time you unplug, turn Wi-Fi off and on once in the iPhone’s Control Center; you won’t need to again."
      ],
      [
        "Do Weather and Calendar use my data?",
        "The first time the Weather face appears, it asks for your approximate location to look up local weather (Open-Meteo). Calendar is only read after you turn it on in Settings, and the next event is shown on this Mac only. Neither is sent anywhere else."
      ],
      [
        "Is the downloaded app safe?",
        "It’s signed with the developer’s Developer ID and notarized by Apple, so Gatekeeper recognizes it. The source is fully public, and you can build it yourself."
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
    filmTitle: "See it in 44 seconds.",
    filmLede: "It watches you, blinks and falls asleep at night; press firmly and it becomes real CarPlay. Filmed before 1.0, so a few faces look different now.",
    filmLabel: "HomePlay 44-second demo film",
    filmBili: "Watch it on Bilibili"
  }
};

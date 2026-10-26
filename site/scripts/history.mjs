// 小工具往事：一篇有出處的長文，三種語言同一個形狀；版面在 build.mjs 的 historyPage()。
// 六章：1984 桌面附件、1997 網頁與助手、2003 Dashboard 與側邊欄、2012 收回、手機與手錶、HomeView 與 HomePlay。
// 寫法：每章先講那一年發生了什麼，再講它留下了什麼。年份、人名、數字都要能在 sources 裡找到；
// 只有一個二手來源的，正文寫「據……」或放進 unsure。可見文字不用破折號（check.mjs 會擋）。
// 舊界面一律不放第三方截圖、原廠圖示、字型或角色；每章的展品在 exhibits/<id>.{js,css,strings.json}，自己畫、自己寫。
export const HISTORY_SLUG = 'history/';
const CHECKED = '2026-10-25';

// 出處共用一份：[種類, 標題, 網址, 用在哪裡]。種類與註記三種語言各寫一次，標題與網址照原文。
const S = {
  folkOrn: ['Folklore.org · Andy Hertzfeld', 'Desk Ornaments', 'https://www.folklore.org/Desk_Ornaments.html'],
  folkCalc: ['Folklore.org · Andy Hertzfeld', 'Calculator Construction Set', 'https://www.folklore.org/Calculator_Construction_Set.html'],
  folkPuzzle: ['Folklore.org · Andy Hertzfeld', 'Puzzle', 'https://www.folklore.org/Puzzle.html'],
  infiniteMac: ['Infinite Mac · Mihai Parparita', 'System 1.0 on Infinite Mac', 'https://infinitemac.org/1984/System%201.0'],
  imDevices: ['Apple developer archive', 'Inside Macintosh: Devices · Desk Accessories', 'https://developer.apple.com/library/archive/documentation/mac/Devices/Devices-16.html'],
  ie4: ['Microsoft press release', 'Microsoft Internet Explorer 4.0 Now Available · 1997-10-01', 'https://news.microsoft.com/source/1997/10/01/microsoft-internet-explorer-4-0-now-available-delivers-the-web-the-way-you-want-it-to-users-worldwide'],
  office97: ['Microsoft press release', 'Microsoft Office 97 Released to Manufacturing · 1996-11-19', 'https://news.microsoft.com/source/1996/11/19/microsoft-office-97-released-to-manufacturing/'],
  lumiere: ['Microsoft Research · UAI 1998', 'The Lumière Project: Bayesian User Modeling for Inferring the Goals and Needs of Software Users', 'https://www.microsoft.com/en-us/research/publication/lumiere-project-bayesian-user-modeling-inferring-goals-needs-software-users/'],
  officexp: ['internetnews.com · 2001-04-11', 'Microsoft Promoting Office XP’s Usability with Web Campaign', 'https://internetnews.com/marketing/microsoft-promoting-office-xps-usability-with-web-campaign'],
  office2007: ['Microsoft developer archive', 'Overview of the Office Assistant (2007 Office system)', 'https://learn.microsoft.com/en-us/previous-versions/office/developer/office-2007/aa433257(v=office.12)'],
  agent1: ['Microsoft press release', 'Microsoft Agent Released to the Web for Free Download · 1997-09-08', 'https://news.microsoft.com/source/1997/09/08/microsoft-agent-released-to-the-web-for-free-download/'],
  agent2: ['Microsoft press release', 'Microsoft Agent 2.0 Adds a More Human Touch to Computing · 1998-10-12', 'https://news.microsoft.com/source/1998/10/12/microsoft-agent-2-0-adds-a-more-human-touch-to-computing/'],
  agentDoc: ['Microsoft Learn', 'Microsoft Agent', 'https://learn.microsoft.com/en-us/windows/win32/lwef/microsoft-agent'],
  konfab: ['MacTech · 2005-07-25', 'Yahoo! Acquires Konfabulator', 'https://www.mactech.com/2005/07/25/yahoo-acquires-konfabulator'],
  gruber: ['Daring Fireball · John Gruber · 2004-06-30', 'Dashboard vs. Konfabulator', 'https://daringfireball.net/2004/06/dashboard_vs_konfabulator'],
  tiger04: ['Apple press release', 'Apple Previews Mac OS X “Tiger” · 2004-06-28', 'https://www.apple.com/newsroom/2004/06/28Apple-Previews-Mac-OS-X-Tiger/'],
  tiger05: ['Apple press release', 'Apple to Ship Mac OS X Tiger on April 29 · 2005-04-12', 'https://www.apple.com/newsroom/2005/04/12Apple-to-Ship-Mac-OS-X-Tiger-on-April-29/'],
  vista: ['Microsoft press release', 'Windows Vista and 2007 Office system launch · 2007-01-23', 'https://news.microsoft.com/?p=2620'],
  sideshowBlog: ['Microsoft SideShow team blog · 2005-10-03', 'What is Windows SideShow?', 'https://learn.microsoft.com/en-us/archive/blogs/sideshow/what-is-windows-sideshow'],
  sideshowMsdn: ['MSDN Magazine · Jeffrey Richter · 2007-01', 'Writing Gadgets For Windows SideShow Devices', 'https://learn.microsoft.com/en-us/archive/msdn-magazine/2007/january/windows-vista-writing-gadgets-for-windows-sideshow-devices'],
  sideshowCw: ['Computerworld · Eric Lai · 2007-05-21', 'Why Vista SideShow is still on the sidelines', 'https://www.computerworld.com/article/1642345/why-vista-sideshow-is-still-on-the-sidelines.html'],
  win7: ['Microsoft press release', 'Microsoft Releases Windows 7 and Windows Server 2008 R2 · 2009-07-22', 'https://news.microsoft.com/source/2009/07/22/microsoft-releases-windows-7-and-windows-server-2008-r2/'],
  advisory: ['Microsoft Security Advisory 2719662 · 2012-07-10', 'Vulnerabilities in Gadgets Could Allow Remote Code Execution', 'https://learn.microsoft.com/en-us/security-updates/SecurityAdvisories/2013/2719662'],
  gadgetsGone: ['Microsoft Learn', 'Desktop gadgets removed (Windows 8 compatibility)', 'https://learn.microsoft.com/en-us/windows/compatibility/desktop-gadgets-removed'],
  widgetkitBudget: ['Apple Developer documentation', 'Keeping a widget up to date', 'https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date'],
  konfabCopycat: ['MacTech · 2004-06-29', 'Mac OS X Tiger is a copycat, claims developer', 'https://www.mactech.com/2004/06/29/mac-os-x-tiger-is-a-copycat-claims-developer'],
  android15: ['Android Developers Blog · 2009-04-20', 'Introducing home screen widgets and the AppWidget framework', 'https://android-developers.googleblog.com/2009/04/introducing-home-screen-widgets-and.html'],
  ios7: ['Apple press release', 'Apple Unveils iOS 7 · 2013-06-10', 'https://www.apple.com/newsroom/2013/06/10Apple-Unveils-iOS-7/'],
  ios8: ['Apple press release', 'iOS 8 Available September 17 · 2014-09-09', 'https://www.apple.com/newsroom/2014/09/09Apple-Announces-iOS-8-Available-September-17/'],
  ios14: ['Apple press release', 'Apple reimagines the iPhone experience with iOS 14 · 2020-06-22', 'https://www.apple.com/newsroom/2020/06/apple-reimagines-the-iphone-experience-with-ios-14/'],
  wwdc20: ['Apple Developer · WWDC20', 'Meet WidgetKit', 'https://developer.apple.com/videos/play/wwdc2020/10028/'],
  sonoma: ['Apple press release', 'macOS Sonoma brings new capabilities · 2023-06-05', 'https://www.apple.com/newsroom/2023/06/macos-sonoma-brings-new-capabilities-for-elevating-productivity-and-creativity/'],
  watch15: ['Apple press release', 'Apple Watch Available in Nine Countries on April 24 · 2015-03-09', 'https://www.apple.com/newsroom/2015/03/09Apple-Watch-Available-in-Nine-Countries-on-April-24/'],
  watchos2: ['Apple press release', 'Apple Introduces watchOS 2 · 2015-09-09', 'https://www.apple.com/newsroom/2015/09/09Apple-Introduces-watchOS-2-with-Native-Apps-and-New-Gold-Rose-Gold-Aluminum-Apple-Watch-Sport-Models/'],
  ios16: ['Apple press release', 'Apple unveils new ways to share and communicate in iOS 16 · 2022-06-06', 'https://www.apple.com/newsroom/2022/06/apple-unveils-new-ways-to-share-and-communicate-in-ios-16/'],
  iphone14pro: ['Apple press release', 'Apple debuts iPhone 14 Pro and iPhone 14 Pro Max · 2022-09-07', 'https://www.apple.com/newsroom/2022/09/apple-debuts-iphone-14-pro-and-iphone-14-pro-max/'],
  ios161: ['Apple Support', 'About iOS 16 Updates', 'https://support.apple.com/en-us/101566'],
  ios17: ['Apple press release', 'iOS 17 makes iPhone more personal and intuitive · 2023-06-05', 'https://www.apple.com/newsroom/2023/06/ios-17-makes-iphone-more-personal-and-intuitive/'],
  higLive: ['Apple Human Interface Guidelines', 'Live Activities', 'https://developer.apple.com/design/human-interface-guidelines/live-activities'],
  higWidgets: ['Apple Human Interface Guidelines', 'Widgets', 'https://developer.apple.com/design/human-interface-guidelines/widgets'],
  homeviewTw: ['Apple 台灣新聞稿 · 2026-10-13', 'Meet Apple HomeView（台灣中文版）', 'https://www.apple.com/tw/newsroom/2026/10/meet-apple-homeview-a-new-way-to-enjoy-entertainment-and-manage-the-home/'],
  homeview: ['Apple Newsroom · 2026-10-13', 'Meet Apple HomeView', 'https://www.apple.com/newsroom/2026/10/meet-apple-homeview-a-new-way-to-enjoy-entertainment-and-manage-the-home/'],
  homeviewPage: ['Apple', 'HomeView', 'https://www.apple.com/homeview/'],
  homeplaySrc: ['HomePlay source', 'surfine / HomePlay', 'https://github.com/surfine/HomePlay'],
};

// 出處的「種類」在中文頁翻成中文；沒列在這裡的（期刊名、網站名）照原文。
const KIND = {
  'zh-Hant': [['Apple press release', 'Apple 新聞稿'], ['Microsoft press release', 'Microsoft 新聞稿'], ['Apple Newsroom', 'Apple 新聞稿'], ['Apple Developer documentation', 'Apple 開發者文件'], ['Apple developer archive', 'Apple 開發者文件封存'], ['Microsoft developer archive', 'Microsoft 開發者文件封存'], ['Apple Human Interface Guidelines', 'Apple 人機介面準則'], ['Apple Support', 'Apple 支援'], ['HomePlay source', 'HomePlay 原始碼'], ['Microsoft SideShow team blog', 'Microsoft SideShow 團隊部落格']],
  'zh-Hans': [['Apple press release', 'Apple 新闻稿'], ['Microsoft press release', 'Microsoft 新闻稿'], ['Apple Newsroom', 'Apple 新闻稿'], ['Apple Developer documentation', 'Apple 开发者文档'], ['Apple developer archive', 'Apple 开发者文档存档'], ['Microsoft developer archive', 'Microsoft 开发者文档存档'], ['Apple Human Interface Guidelines', 'Apple 人机界面指南'], ['Apple Support', 'Apple 支持'], ['HomePlay source', 'HomePlay 源代码'], ['Microsoft SideShow team blog', 'Microsoft SideShow 团队博客']],
  en: [],
};
const kindIn = (lang, k) => KIND[lang].reduce((s, [a, b]) => s.replace(a, b), k);

// 文案：三種語言同一個形狀。chapters[].links 與 sources[][0] 是 S 的鍵。
// 六章的 id 就是保留的展品 id：desk、clippy、dashboard、removed、pocket、homeplay。
const DATA = {
 "zh-Hant": {
  "navLink": "小工具往事",
  "title": "小工具往事：從桌面附件到即時動態｜HomePlay",
  "ogTitle": "小工具往事：瞥一眼就夠的小工具，是這樣來的",
  "description": "從 1984 年 Mac 的桌面附件，經過 Active Desktop、Office 小幫手、Dashboard 與 Vista 側邊欄，講到今天的小工具、複雜功能、即時動態和 HomeView。每段附出處。",
  "ogAlt": "HomePlay 桌寵：白色機身，螢幕上是時間和一雙眼睛",
  "keywords": "小工具, widgets, 桌面附件, Desk Accessory, Active Desktop, Clippy, Microsoft Agent, Konfabulator, Dashboard, Windows 側邊欄, SideShow, 複雜功能, 即時動態, HomeView, HomePlay",
  "kicker": "HomePlay 札記 01 · 一塊小螢幕的來歷",
  "h1": "<span class=\"l\">瞥一眼就夠的小工具，</span><span class=\"l\">是這樣來的。</span>",
  "lede": "小工具是一眼就能看懂的小程式，像時鐘、天氣和計時器。這篇從 1984 年蘋果選單裡的計算機講起，經過會主動開口的網頁與小幫手、Dashboard 和 Vista 側邊欄，講到今天的小工具、複雜功能和即時動態。四十年來大家想做的都是同一件事：不打斷你，又讓你一眼看到需要的資訊。",
  "meta": "查證於 2026 年 10 月 25 日。每章一件展品，由 HomePlay 用自己的程式碼重畫：不是當年截圖，也不用原廠圖示、字型或角色。出處附在每章後面；只有二手來源的列在文末。",
  "stripLabel": "年代",
  "tocLabel": "目錄",
  "home": "回到 HomePlay",
  "lessonLabel": "這一代留下的",
  "chapters": [
   {
    "id": "desk",
    "year": "1984",
    "short": "桌面附件",
    "era": "1984 · Macintosh",
    "title": "一次只能開一個程式，桌上還是要有計算機。",
    "body": [
     "1981 年秋天，Macintosh 團隊決定一次只跑一個程式：記憶體和螢幕都太小。Bud Tribble 提議另做一種小程式，在主程式旁邊開個小視窗、只做一件事，叫「桌面擺飾」。1982 年秋天，文件組覺得「擺飾」太花俏，改名「桌面附件」。",
     "Andy Hertzfeld 和同事做出計算機、鬧鐘、記事本、剪貼簿、Key Caps、控制面板，還有一個數字拼圖。計算機的外觀是 Steve Jobs 用 Chris Espinosa 做的「計算機組合工具」親手調的。拼圖用 Pascal 寫超過 6 KB，一度不打算出貨；Hertzfeld 花一個週末用組合語言重寫成約 600 位元組，它才跟著第一台 Mac 出貨。",
     "這些附件都收在蘋果選單裡：要用時打開，用完關掉，手上的文件一直都在。Apple 在 Inside Macintosh 裡解釋：桌面附件是做得像驅動程式的小程式，讓 Mac 有限地同時做幾件事。"
    ],
    "links": [
     "folkOrn",
     "folkCalc",
     "folkPuzzle",
     "infiniteMac",
     "imDevices"
    ],
    "lesson": "小工具從一開始就是為了讓你不必離開手上的事：要用時拿得到，用完就收。"
   },
   {
    "id": "clippy",
    "year": "1997",
    "short": "網頁與小幫手",
    "era": "1997 → 2009 · 網頁與助手",
    "title": "「看起來你在寫信。」",
    "body": [
     "1997 年 10 月 1 日，Internet Explorer 4.0 把網頁放上 Windows 桌面：「Active Desktop」直接顯示網頁內容，「Active Channel」把 500 多個網站做成自動推送的頻道。這個想法要把桌面變成一扇一直開著的資訊窗。但當時大家用撥接上網：一直更新的桌布佔電話線和記憶體，也一直在你眼角動。後來的 Windows 把這裡給了別的設計。",
     "1996 年 11 月 19 日 Office 97 送廠，隔年初上市，裡面有一位「Office 小幫手」，待在視窗角落提供建議和說明；最出名的造型是迴紋針 Clippy。它背後是認真的研究：Microsoft Research 的 Lumière 計畫用貝氏網路（用機率推理的數學模型）推測你在做什麼、卡在哪裡，1998 年的論文寫明小幫手部分元件以此為基礎。可是猜得到你要做什麼，不代表該在那時開口。大家記得最清楚的就是那句「看起來你在寫信」：你沒有問，它就在你打字時跳出來，擋住正在寫的字。Office XP（2001）把它預設關閉，Microsoft 還為此辦了一波網路宣傳，產品經理說 Office XP 好用到不再需要 Clippy；2007 年版把它淘汰。",
     "會動的角色也成了元件。1997 年 9 月 8 日 Microsoft Agent 免費開放下載，1998 年 10 月 12 日的 2.0 版加入鸚鵡 Peedy，和精靈 Genie、魔法師 Merlin、機器人 Robby 是最常見的四個角色。幾行指令就能叫角色走位、做動作、開口說話，還能加上文字轉語音和語音辨識，所以角色到處都是，也常在不對的時候出現。Windows 7 起 Microsoft 將它淘汰。"
    ],
    "links": [
     "ie4",
     "office97",
     "lumiere",
     "officexp",
     "office2007",
     "agent1",
     "agent2",
     "agentDoc"
    ],
    "lesson": "主動開口是這一代共同的問題。誰能開口、什麼時候開口，應該由你決定。"
   },
   {
    "id": "dashboard",
    "year": "2003 → 2009",
    "short": "Dashboard 與側邊欄",
    "era": "2003 → 2009 · Dashboard · SideShow",
    "title": "小工具有了名字，也有了自己的一層。",
    "body": [
     "2003 年，Arlo Rose 和 Perry Clarke 在 Mac OS X 上推出 Konfabulator，讓人做浮在桌面上的小程式；2005 年 7 月 Yahoo! 買下它，把 20 美元的軟體改成免費，後來改名 Yahoo! Widgets。2004 年 6 月 28 日 Apple 在 WWDC 預覽 Tiger，裡面的 Dashboard 把這類小程式定名「widgets」；2005 年 4 月 29 日上市，內附 14 個，用 HTML 和 JavaScript 這些網頁技術寫成，按一個鍵全部浮上來，再按一次收起。Rose 說 Apple 抄了他的點子，John Gruber 寫文章反駁，把源頭追回 1984 年的桌面附件。兩種說法都還在；沒有爭議的是，Dashboard 讓小工具有了自己的一層：叫得出來，也收得回去。",
     "2007 年 1 月 30 日 Windows Vista 上市，小工具（gadgets）可以放進桌面側邊的側邊欄；Windows 7（2009 年 10 月 22 日）起直接放桌面。Microsoft 同期還做了 SideShow：小工具在電腦上跑，畫面送到筆電外蓋那樣的另一塊小螢幕，原型 220 × 176、開著約 4 毫瓦（整台電腦約 75 瓦），電腦睡著時還能顯示上次同步的內容。但它沒有普及：2007 年 5 月，Computerworld 指出買得到的 SideShow 筆電只有華碩一款；WeatherBug 的 SideShow 版下載不到一萬次，桌面版超過六十萬次。小螢幕上只是快照，要看新內容就得叫醒電腦，評測也抱怨它為了更新常把整台電腦從待機吵醒。"
    ],
    "links": [
     "konfab",
     "konfabCopycat",
     "gruber",
     "tiger04",
     "tiger05",
     "vista",
     "win7",
     "sideshowBlog",
     "sideshowMsdn",
     "sideshowCw"
    ],
    "lesson": "要能瞥一眼，螢幕得一直在身邊、內容得一直是新的，更新時還不能吵醒整台電腦。SideShow 一次只做到其中一件。"
   },
   {
    "id": "removed",
    "year": "2012",
    "short": "收回",
    "era": "2012 · Security Advisory 2719662",
    "title": "小工具被收回，因為它能做的事情太多了。",
    "body": [
     "2012 年 7 月 10 日，Microsoft 發布安全公告 2719662：側邊欄和小工具的漏洞可能讓人遠端執行程式碼。正常的小工具可能有漏洞，攻擊者也能騙你裝上惡意的；兩種情況都用你的權限跑任何程式。Microsoft 給的辦法是一個工具，把側邊欄和小工具整個關掉。到了 Windows 8，小工具直接從系統裡移除，換成動態磚和 App：就連無害的小工具也可能被利用。"
    ],
    "links": [
     "advisory",
     "gadgetsGone"
    ],
    "lesson": "桌面上的小工具看起來很小，跑的卻是完整的程式。能執行任何程式碼的東西，就能被拿來攻擊你。"
   },
   {
    "id": "pocket",
    "year": "2009 → 2023",
    "short": "手機與手錶",
    "era": "2009 → 2023 · Android · iOS · Watch",
    "title": "小工具進了口袋，也學會不一直執行。",
    "body": [
     "手機把小工具帶了回來：2009 年 4 月 Android 1.5 開放主畫面小工具；2013 年 iOS 7 在通知中心加「今天」，一眼看完今天的事，隔年 iOS 8 開放第三方。2020 年 iOS 14 讓小工具上主畫面、還能疊成「智慧型堆疊」，開發者改用 WidgetKit。這次記取了教訓：小工具不是一直在跑的程式。App 先交出一條時間軸，寫好每個時間該顯示的畫面，系統到點就換下一格；Apple 的文件寫，常被查看的小工具一天約有 40 到 70 次更新額度，大約每 15 到 60 分鐘一次。2023 年 macOS Sonoma 讓小工具回到 Mac 桌面，iPhone 的也能透過接續互通出現：從 Dashboard 的那一層到直接擺上桌面，中間換了一整套更省電、更安全的做法。",
     "手錶把瞥一眼縮到最短：抬手、看、放下，只有幾秒。錶盤上報時以外的功能，鐘錶業本來就叫 complication，例如日期、月相和計時；2015 年 4 月 24 日開賣的 Apple Watch 沿用這個詞，中文叫「複雜功能」，同年 9 月的 watchOS 2 開放第三方用 ClockKit 做。一小格只放得下此刻最需要的那一件事；2022 年 iOS 16 的鎖定畫面小工具，Apple 說靈感就來自這裡。",
     "2022 年 9 月 7 日，iPhone 14 Pro 帶來螢幕頂端的「動態島」，iOS 16.1 開放第三方用「即時動態」：外送到哪裡、比數多少、計時剩幾分，留在鎖定畫面和島上。準則限用於有明確開始和結束的事，建議不超過八小時，事情一結束就要馬上結束。2023 年 iOS 17 的「待機模式」讓橫放充電的 iPhone 變成遠處也看得清的時鐘和小工具：這是 iPhone 第一次被當成一塊放在桌上的螢幕。"
    ],
    "links": [
     "android15",
     "ios7",
     "ios8",
     "ios14",
     "wwdc20",
     "widgetkitBudget",
     "sonoma",
     "watch15",
     "watchos2",
     "ios16",
     "iphone14pro",
     "ios161",
     "higLive",
     "ios17"
    ],
    "lesson": "不一直執行，按時間軸換畫面；進行中才出現，結束就消失。"
   },
   {
    "id": "homeplay",
    "year": "2026",
    "short": "HomeView 與 HomePlay",
    "era": "2026 · HomeView · HomePlay",
    "title": "一塊共用的螢幕，一個等你開口的助手。",
    "body": [
     "2026 年 10 月 13 日，Apple 發表 HomeView：7 吋 Liquid Retina 的家用顯示器，有桌上型和壁掛型，畫面有 Photos、Flow、Snoopy、Home Modular、Home Camera 等可切換（Apple 台灣把這些畫面稱為「桌面」）。每位登記的家人有自己的主畫面和小工具；播放中的歌、計時器、從別的房間傳來的對講，都用即時動態顯示。",
     "前面每一章學到的事，在這裡都看得到：桌面附件的隨手可得，Dashboard 的叫得出也收得回，SideShow 想要的另一塊螢幕，WidgetKit 的時間軸，手錶上選對的一格，還有即時動態的有始有終。",
     "HomePlay 是 Mac 上的開源桌寵，長得像 HomeView，頂端膠囊裡有一雙 👀。它大部分時間只是看著你，不出聲；你靠近，它才亮起來；你專心工作時，它不吵你。它的助手 ClioTalk 把從 Clippy 學到的事寫成規則：不自己跳出來，按住 F5 或點它才開始聽；回答是暫時的，你說要留下才會存；凡是用你的名義做的事，像傳訊息、打電話、加行程、解開門鎖，都先唸給你聽，等你說好；替你寫訊息時，用你自己說的話，不改成它的口氣。",
     "這些規則不保證它永遠猜對，只保證猜錯時不會替你做你沒答應的事。四十年前蘋果選單裡的計算機，要用時才出來，用完就收；我們希望 HomePlay 也是這樣。"
    ],
    "links": [
     "homeview",
     "homeviewTw",
     "higWidgets",
     "homeplaySrc"
    ],
    "lesson": ""
   }
  ],
  "timelineTitle": "年表",
  "timelineLede": "照時間排一次；右欄是每一步留下的。",
  "timelineHead": [
   "時間",
   "發生了什麼",
   "留下的"
  ],
  "timeline": [
   [
    "1981 秋",
    "Bud Tribble 提出「桌面擺飾」，1982 年改名桌面附件",
    "陪在主程式旁邊"
   ],
   [
    "1984",
    "第一台 Mac 選單裡的附件",
    "隨手可得，用完就收"
   ],
   [
    "1996-11-19",
    "Office 97 送廠，附 Office 小幫手",
    "猜到不代表該開口"
   ],
   [
    "1997-10-01",
    "Internet Explorer 4.0 與 Active Desktop",
    "一直更新有代價"
   ],
   [
    "2001",
    "Office XP 預設關閉小幫手",
    "開始在意打擾"
   ],
   [
    "2003",
    "Konfabulator 推出",
    "成了一種軟體類別"
   ],
   [
    "2005-04-29",
    "Tiger 上市，Dashboard 內附 14 個小工具",
    "叫得出，也收得回"
   ],
   [
    "2007-01-30",
    "Windows Vista：側邊欄與 SideShow",
    "第二塊螢幕"
   ],
   [
    "2009-04",
    "Android 1.5 開放主畫面小工具",
    "進了口袋"
   ],
   [
    "2012-07-10",
    "安全公告 2719662，Windows 8 移除小工具",
    "能跑就有風險"
   ],
   [
    "2015-04-24",
    "Apple Watch 開賣，帶複雜功能",
    "空間越小越要選對"
   ],
   [
    "2020",
    "iOS 14 主畫面小工具與 WidgetKit",
    "按時間軸換畫面"
   ],
   [
    "2022",
    "鎖定畫面小工具、動態島與即時動態",
    "有始有終"
   ],
   [
    "2023",
    "iOS 17 待機模式；macOS Sonoma 桌面小工具",
    "回到 Mac 桌面"
   ],
   [
    "2026-10-13",
    "Apple 發表 HomeView",
    "大家共用的螢幕"
   ],
   [
    "2026",
    "HomePlay：在 Mac 上，ClioTalk 等你開口",
    "助手先等，再做"
   ]
  ],
  "unsureTitle": "還不確定的地方",
  "unsureLede": "下面這些只找到二手來源，或來源之間說法不一。正文已經避開，或寫成「據……」。",
  "unsure": [
   "第一台 Mac 附了哪些附件：完整清單只有維基百科；Chooser 不算在 1984 年。",
   "IE 4.0 的日期：新聞稿是 1997 年 10 月 1 日全球上市，也有來源寫 9 月 22 日。",
   "Active Desktop 在 Vista 被側邊欄取代：只有維基百科與論壇說法。",
   "「看起來你在寫信」的觸發條件與 Atteberry 的草稿數：只有二手報導。",
   "Konfabulator 的發表日與兩位共同作者的角色：只有維基百科。",
   "Windows 7 拿掉側邊欄的細節：只有維基百科與業界媒體。",
   "HomeView 的 faces：台灣新聞稿譯作「桌面」，和「錶面」不同；HomePlay 一律叫錶面。"
  ],
  "sourcesTitle": "出處",
  "sourcesLede": "文中的年份、數字和引述都能在下面找到；我們優先列一手資料：當年的新聞稿、官方文件、親歷者的回憶。",
  "notice": "HomePlay 是獨立的開源專案，與 Apple、Microsoft、Google、Yahoo 無關；名稱屬於各自權利人，展品只是示意。查證於 2026 年 10 月 25 日，發現錯誤請在 GitHub 告訴我們。",
  "sources": [
   [
    "folkOrn",
    "附件的由來。"
   ],
   [
    "folkCalc",
    "計算機的外觀。"
   ],
   [
    "folkPuzzle",
    "拼圖的重寫。"
   ],
   [
    "imDevices",
    "Apple 的定義。"
   ],
   [
    "infiniteMac",
    "瀏覽器裡的 System 1.0；點了才載入。"
   ],
   [
    "ie4",
    "Active Desktop 與頻道。"
   ],
   [
    "office97",
    "Office 97 與小幫手。"
   ],
   [
    "lumiere",
    "Lumière 與小幫手。"
   ],
   [
    "officexp",
    "XP 預設關閉。"
   ],
   [
    "office2007",
    "2007 年淘汰。"
   ],
   [
    "agent1",
    "Agent 免費下載。"
   ],
   [
    "agent2",
    "2.0 版與 Peedy。"
   ],
   [
    "agentDoc",
    "Windows 7 起淘汰。"
   ],
   [
    "konfab",
    "收購與免費。"
   ],
   [
    "konfabCopycat",
    "Rose 的回應。"
   ],
   [
    "gruber",
    "源頭追回附件。"
   ],
   [
    "tiger04",
    "Tiger 預覽。"
   ],
   [
    "tiger05",
    "上市與 14 個小工具。"
   ],
   [
    "vista",
    "Vista 與側邊欄。"
   ],
   [
    "win7",
    "Windows 7 上市。"
   ],
   [
    "sideshowBlog",
    "團隊說明。"
   ],
   [
    "sideshowMsdn",
    "原型螢幕與耗電。"
   ],
   [
    "sideshowCw",
    "為何沒普及。"
   ],
   [
    "advisory",
    "安全公告。"
   ],
   [
    "gadgetsGone",
    "Windows 8 移除。"
   ],
   [
    "android15",
    "Android 1.5 框架。"
   ],
   [
    "ios7",
    "iOS 7「今天」。"
   ],
   [
    "ios8",
    "開放第三方。"
   ],
   [
    "ios14",
    "主畫面小工具。"
   ],
   [
    "wwdc20",
    "WidgetKit 介紹。"
   ],
   [
    "widgetkitBudget",
    "時間軸與額度。"
   ],
   [
    "sonoma",
    "桌面小工具。"
   ],
   [
    "watch15",
    "開賣與複雜功能。"
   ],
   [
    "watchos2",
    "watchOS 2。"
   ],
   [
    "ios16",
    "靈感來自複雜功能。"
   ],
   [
    "iphone14pro",
    "動態島。"
   ],
   [
    "ios161",
    "開放即時動態。"
   ],
   [
    "higLive",
    "即時動態準則。"
   ],
   [
    "ios17",
    "待機模式。"
   ],
   [
    "higWidgets",
    "準則與 HomeView。"
   ],
   [
    "homeview",
    "發表與規格。"
   ],
   [
    "homeviewTw",
    "台灣用詞。"
   ],
   [
    "homeplaySrc",
    "規則寫在程式裡。"
   ]
  ],
  "reset": "重來",
  "exUi": {
   "loading": "展品載入中",
   "reduced": "已減少動態效果：動畫改成直接切換。"
  }
 },
 "zh-Hans": {
  "navLink": "小工具往事",
  "title": "小工具往事：从桌面附件到实时活动｜HomePlay",
  "ogTitle": "小组件往事：瞥一眼就够的小组件，是这样来的",
  "description": "从 1984 年 Mac 的桌面附件，经过 Active Desktop、Office 助手、Dashboard 与 Vista 侧边栏，讲到今天的小组件、复杂功能、实时活动和 HomeView。每段附出处。",
  "ogAlt": "HomePlay 桌宠：白色机身，屏幕上是时间和一双眼睛",
  "keywords": "小工具, widgets, 桌面附件, Desk Accessory, Active Desktop, Clippy, Microsoft Agent, Konfabulator, Dashboard, Windows 侧边栏, SideShow, 复杂功能, 实时活动, HomeView, HomePlay",
  "kicker": "HomePlay 札记 01 · 一块小屏幕的来历",
  "h1": "<span class=\"l\">瞥一眼就够的小组件，</span><span class=\"l\">是这样来的。</span>",
  "lede": "小组件是一眼就能看懂的小程序，像时钟、天气和计时器。这篇从 1984 年苹果菜单里的计算机讲起，经过会主动开口的网页与小助手、Dashboard 和 Vista 侧边栏，讲到今天的小组件、复杂功能和实时活动。四十年来大家想做的都是同一件事：不打断你，又让你一眼看到需要的信息。",
  "meta": "查证于 2026 年 10 月 25 日。每章一件展品，由 HomePlay 用自己的代码重画：不是当年截图，也不用原厂图标、字体或角色。出处附在每章后面；只有二手来源的列在文末。",
  "stripLabel": "年代",
  "tocLabel": "目录",
  "home": "回到 HomePlay",
  "lessonLabel": "这一代留下的",
  "chapters": [
   {
    "id": "desk",
    "year": "1984",
    "short": "桌面附件",
    "era": "1984 · Macintosh",
    "title": "一次只能开一个程序，桌上还是要有计算机。",
    "body": [
     "1981 年秋天，Macintosh 团队决定一次只跑一个程序：内存和屏幕都太小。Bud Tribble 提议另做一种小程序，在主程序旁边开个小窗口、只做一件事，叫「桌面摆饰」。1982 年秋天，文档组觉得「摆饰」太花哨，改名「桌面附件」。",
     "Andy Hertzfeld 和同事做出计算机、闹钟、记事本、剪贴板、Key Caps、控制面板，还有一个数字拼图。计算机的外观是 Steve Jobs 用 Chris Espinosa 做的「计算机组合工具」亲手调的。拼图用 Pascal 写超过 6 KB，一度不打算出货；Hertzfeld 花一个周末用汇编语言重写成约 600 字节，它才跟着第一台 Mac 出货。",
     "这些附件都收在苹果菜单里：要用时打开，用完关掉，手上的文档一直都在。Apple 在 Inside Macintosh 里解释：桌面附件是做得像驱动程序的小程序，让 Mac 有限地同时做几件事。"
    ],
    "links": [
     "folkOrn",
     "folkCalc",
     "folkPuzzle",
     "infiniteMac",
     "imDevices"
    ],
    "lesson": "小组件从一开始就是为了让你不必离开手上的事：要用时拿得到，用完就收。"
   },
   {
    "id": "clippy",
    "year": "1997",
    "short": "网页与助手",
    "era": "1997 → 2009 · 网页与助手",
    "title": "「看起来你在写信。」",
    "body": [
     "1997 年 10 月 1 日，Internet Explorer 4.0 把网页放上 Windows 桌面：「Active Desktop」直接显示网页内容，「Active Channel」把 500 多个网站做成自动推送的频道。这个想法要把桌面变成一扇一直开着的信息窗。但当时大家用拨号上网：一直更新的壁纸占电话线和内存，也一直在你眼角动。后来的 Windows 把这里给了别的设计。",
     "1996 年 11 月 19 日 Office 97 交付生产，隔年初上市，里面有一位「Office 助手」，待在窗口角落提供建议和说明；最出名的造型是回形针 Clippy。它背后是认真的研究：Microsoft Research 的 Lumière 计划用贝叶斯网络（用概率推理的数学模型）推测你在做什么、卡在哪里，1998 年的论文写明助手部分组件以此为基础。可是猜得到你要做什么，不代表该在那时开口。大家记得最清楚的就是那句「看起来你在写信」：你没有问，它就在打字时跳出来，挡住正在写的字。Office XP（2001）把它默认关闭，Microsoft 还为此办了一波网络宣传，产品经理说 Office XP 好用到不再需要 Clippy；2007 年版把它淘汰。",
     "会动的角色也成了组件。1997 年 9 月 8 日 Microsoft Agent 免费开放下载，1998 年 10 月 12 日的 2.0 版加入鹦鹉 Peedy，和精灵 Genie、魔法师 Merlin、机器人 Robby 是最常见的四个角色。几行指令就能叫角色走位、做动作、开口说话，还能加上文字转语音和语音识别，所以角色到处都是，也常在不对的时候出现。Windows 7 起 Microsoft 将它淘汰。"
    ],
    "links": [
     "ie4",
     "office97",
     "lumiere",
     "officexp",
     "office2007",
     "agent1",
     "agent2",
     "agentDoc"
    ],
    "lesson": "主动开口是这一代共同的问题。谁能开口、什么时候开口，应该由你决定。"
   },
   {
    "id": "dashboard",
    "year": "2003 → 2009",
    "short": "Dashboard 与侧边栏",
    "era": "2003 → 2009 · Dashboard · SideShow",
    "title": "小组件有了名字，也有了自己的一层。",
    "body": [
     "2003 年，Arlo Rose 和 Perry Clarke 在 Mac OS X 上推出 Konfabulator，让人做浮在桌面上的小程序；2005 年 7 月 Yahoo! 买下它，把 20 美元的软件改成免费，后来改名 Yahoo! Widgets。2004 年 6 月 28 日 Apple 在 WWDC 预览 Tiger，里面的 Dashboard 把这类小程序定名「widgets」；2005 年 4 月 29 日上市，内附 14 个，用 HTML 和 JavaScript 这些网页技术写成，按一个键全部浮上来，再按一次收起。Rose 说 Apple 抄了他的点子，John Gruber 写文章反驳，把源头追回 1984 年的桌面附件。两种说法都还在；没有争议的是，Dashboard 让小组件有了自己的一层：叫得出来，也收得回去。",
     "2007 年 1 月 30 日 Windows Vista 上市，小工具（gadgets）可以放进桌面侧边的侧边栏；Windows 7（2009 年 10 月 22 日）起直接放桌面。Microsoft 同期还做了 SideShow：小工具在电脑上跑，画面送到笔记本外盖那样的另一块小屏幕，原型 220 × 176、开着约 4 毫瓦（整台电脑约 75 瓦），电脑睡着时还能显示上次同步的内容。但它没有普及：2007 年 5 月，Computerworld 指出买得到的 SideShow 笔记本只有华硕一款；WeatherBug 的 SideShow 版下载不到一万次，桌面版超过六十万次。小屏幕上只是快照，要看新内容就得唤醒电脑，评测也抱怨它为了更新常把整台电脑从待机吵醒。"
    ],
    "links": [
     "konfab",
     "konfabCopycat",
     "gruber",
     "tiger04",
     "tiger05",
     "vista",
     "win7",
     "sideshowBlog",
     "sideshowMsdn",
     "sideshowCw"
    ],
    "lesson": "要能瞥一眼，屏幕得一直在身边、内容得一直是新的，更新时还不能唤醒整台电脑。SideShow 一次只做到其中一件。"
   },
   {
    "id": "removed",
    "year": "2012",
    "short": "收回",
    "era": "2012 · Security Advisory 2719662",
    "title": "小工具被收回，因为它能做的事情太多了。",
    "body": [
     "2012 年 7 月 10 日，Microsoft 发布安全公告 2719662：侧边栏和小工具的漏洞可能让人远程运行代码。正常的小工具可能有漏洞，攻击者也能骗你装上恶意的；两种情况都用你的权限跑任何程序。Microsoft 给的办法是一个工具，把侧边栏和小工具整个关掉。到了 Windows 8，小工具直接从系统里移除，换成动态磁贴和 App：就连无害的小工具也可能被利用。"
    ],
    "links": [
     "advisory",
     "gadgetsGone"
    ],
    "lesson": "桌面上的小工具看起来很小，跑的却是完整的程序。能运行任何代码的东西，就能被拿来攻击你。"
   },
   {
    "id": "pocket",
    "year": "2009 → 2023",
    "short": "手机与手表",
    "era": "2009 → 2023 · Android · iOS · Watch",
    "title": "小组件进了口袋，也学会不一直运行。",
    "body": [
     "手机把小组件带了回来：2009 年 4 月 Android 1.5 开放主屏幕小组件；2013 年 iOS 7 在通知中心加「今天」，一眼看完今天的事，隔年 iOS 8 开放第三方。2020 年 iOS 14 让小组件上主屏幕、还能叠成「智能叠放」，开发者改用 WidgetKit。这次吸取了教训：小组件不是一直在跑的程序。App 先交出一条时间轴，写好每个时间该显示的画面，系统到点就换下一格；Apple 的文档写，常被查看的小组件一天约有 40 到 70 次更新额度，大约每 15 到 60 分钟一次。2023 年 macOS Sonoma 让小组件回到 Mac 桌面，iPhone 的也能通过连续互通出现：从 Dashboard 的那一层到直接摆上桌面，中间换了一整套更省电、更安全的做法。",
     "手表把瞥一眼缩到最短：抬手、看、放下，只有几秒。表盘上报时以外的功能，钟表业本来就叫 complication，例如日期、月相和计时；2015 年 4 月 24 日发售的 Apple Watch 沿用这个词，中文叫「复杂功能」，同年 9 月的 watchOS 2 开放第三方用 ClockKit 做。一小格只放得下此刻最需要的那一件事；2022 年 iOS 16 的锁定屏幕小组件，Apple 说灵感就来自这里。",
     "2022 年 9 月 7 日，iPhone 14 Pro 带来屏幕顶端的「灵动岛」，iOS 16.1 开放第三方用「实时活动」：外卖到哪里、比分多少、计时剩几分，留在锁定屏幕和岛上。准则只用于有明确开始和结束的事，建议不超过八小时，事情一结束就要马上结束。2023 年 iOS 17 的「待机显示」让横放充电的 iPhone 变成远处也看得清的时钟和小组件：这是 iPhone 第一次被当成一块放在桌上的屏幕。"
    ],
    "links": [
     "android15",
     "ios7",
     "ios8",
     "ios14",
     "wwdc20",
     "widgetkitBudget",
     "sonoma",
     "watch15",
     "watchos2",
     "ios16",
     "iphone14pro",
     "ios161",
     "higLive",
     "ios17"
    ],
    "lesson": "不一直运行，按时间轴换画面；进行中才出现，结束就消失。"
   },
   {
    "id": "homeplay",
    "year": "2026",
    "short": "HomeView 与 HomePlay",
    "era": "2026 · HomeView · HomePlay",
    "title": "一块共用的屏幕，一个等你开口的助手。",
    "body": [
     "2026 年 10 月 13 日，Apple 发布 HomeView：7 英寸 Liquid Retina 的家用显示器，有桌面款和壁挂款，画面有 Photos、Flow、Snoopy、Home Modular、Home Camera 等可切换（Apple 台湾把这些画面称为「桌面」）。每位登记的家人有自己的主屏幕和小组件；播放中的歌、计时器、从别的房间传来的对讲，都用实时活动显示。",
     "前面每一章学到的事，在这里都看得到：桌面附件的随手可得，Dashboard 的叫得出也收得回，SideShow 想要的另一块屏幕，WidgetKit 的时间轴，手表上选对的一格，还有实时活动的有始有终。",
     "HomePlay 是 Mac 上的开源桌宠，长得像 HomeView，顶端胶囊里有一双 👀。它大部分时间只是看着你，不出声；你靠近，它才亮起来；你专心工作时，它不吵你。它的助手 ClioTalk 把从 Clippy 学到的事写成规则：不自己跳出来，按住 F5 或点它才开始听；回答是暂时的，你说要留下才会存；凡是用你的名义做的事，像发消息、打电话、加日程、解开门锁，都先念给你听，等你说好；替你写消息时，用你自己说的话，不改成它的口气。",
     "这些规则不保证它永远猜对，只保证猜错时不会替你做没答应的事。四十年前苹果菜单里的计算机，要用时才出来，用完就收；我们希望 HomePlay 也是这样。"
    ],
    "links": [
     "homeview",
     "homeviewTw",
     "higWidgets",
     "homeplaySrc"
    ],
    "lesson": ""
   }
  ],
  "timelineTitle": "年表",
  "timelineLede": "照时间排一次；右栏是每一步留下的。",
  "timelineHead": [
   "时间",
   "发生了什么",
   "留下的"
  ],
  "timeline": [
   [
    "1981 秋",
    "Bud Tribble 提出「桌面摆饰」，1982 年改名桌面附件",
    "陪在主程序旁边"
   ],
   [
    "1984",
    "第一台 Mac 菜单里的附件",
    "随手可得，用完就收"
   ],
   [
    "1996-11-19",
    "Office 97 交付生产，附 Office 助手",
    "猜到不代表该开口"
   ],
   [
    "1997-10-01",
    "Internet Explorer 4.0 与 Active Desktop",
    "一直更新有代价"
   ],
   [
    "2001",
    "Office XP 默认关闭助手",
    "开始在意打扰"
   ],
   [
    "2003",
    "Konfabulator 推出",
    "成了一种软件类别"
   ],
   [
    "2005-04-29",
    "Tiger 上市，Dashboard 内附 14 个小组件",
    "叫得出，也收得回"
   ],
   [
    "2007-01-30",
    "Windows Vista：侧边栏与 SideShow",
    "第二块屏幕"
   ],
   [
    "2009-04",
    "Android 1.5 开放主屏幕小组件",
    "进了口袋"
   ],
   [
    "2012-07-10",
    "安全公告 2719662，Windows 8 移除小工具",
    "能跑就有风险"
   ],
   [
    "2015-04-24",
    "Apple Watch 发售，带复杂功能",
    "空间越小越要选对"
   ],
   [
    "2020",
    "iOS 14 主屏幕小组件与 WidgetKit",
    "按时间轴换画面"
   ],
   [
    "2022",
    "锁定屏幕小组件、灵动岛与实时活动",
    "有始有终"
   ],
   [
    "2023",
    "iOS 17 待机显示；macOS Sonoma 桌面小组件",
    "回到 Mac 桌面"
   ],
   [
    "2026-10-13",
    "Apple 发布 HomeView",
    "大家共用的屏幕"
   ],
   [
    "2026",
    "HomePlay：在 Mac 上，ClioTalk 等你开口",
    "助手先等，再做"
   ]
  ],
  "unsureTitle": "还不确定的地方",
  "unsureLede": "下面这些只找到二手来源，或来源之间说法不一。正文已经避开，或写成「据……」。",
  "unsure": [
   "第一台 Mac 附了哪些附件：完整清单只有维基百科；Chooser 不算在 1984 年。",
   "IE 4.0 的日期：新闻稿是 1997 年 10 月 1 日全球上市，也有来源写 9 月 22 日。",
   "Active Desktop 在 Vista 被侧边栏取代：只有维基百科与论坛说法。",
   "「看起来你在写信」的触发条件与 Atteberry 的草稿数：只有二手报道。",
   "Konfabulator 的发布日与两位共同作者的角色：只有维基百科。",
   "Windows 7 拿掉侧边栏的细节：只有维基百科与业界媒体。",
   "HomeView 的 faces：台湾新闻稿译作「桌面」，和「表盘」不同；HomePlay 一律叫表盘。"
  ],
  "sourcesTitle": "出处",
  "sourcesLede": "文中的年份、数字和引述都能在下面找到；我们优先列一手资料：当年的新闻稿、官方文档、亲历者的回忆。",
  "notice": "HomePlay 是独立的开源项目，与 Apple、Microsoft、Google、Yahoo 无关；名称属于各自权利人，展品只是示意。查证于 2026 年 10 月 25 日，发现错误请在 GitHub 告诉我们。",
  "sources": [
   [
    "folkOrn",
    "附件的由来。"
   ],
   [
    "folkCalc",
    "计算机的外观。"
   ],
   [
    "folkPuzzle",
    "拼图的重写。"
   ],
   [
    "imDevices",
    "Apple 的定义。"
   ],
   [
    "infiniteMac",
    "浏览器里的 System 1.0；点了才载入。"
   ],
   [
    "ie4",
    "Active Desktop 与频道。"
   ],
   [
    "office97",
    "Office 97 与助手。"
   ],
   [
    "lumiere",
    "Lumière 与助手。"
   ],
   [
    "officexp",
    "XP 默认关闭。"
   ],
   [
    "office2007",
    "2007 年淘汰。"
   ],
   [
    "agent1",
    "Agent 免费下载。"
   ],
   [
    "agent2",
    "2.0 版与 Peedy。"
   ],
   [
    "agentDoc",
    "Windows 7 起淘汰。"
   ],
   [
    "konfab",
    "收购与免费。"
   ],
   [
    "konfabCopycat",
    "Rose 的回应。"
   ],
   [
    "gruber",
    "源头追回附件。"
   ],
   [
    "tiger04",
    "Tiger 预览。"
   ],
   [
    "tiger05",
    "上市与 14 个小组件。"
   ],
   [
    "vista",
    "Vista 与侧边栏。"
   ],
   [
    "win7",
    "Windows 7 上市。"
   ],
   [
    "sideshowBlog",
    "团队说明。"
   ],
   [
    "sideshowMsdn",
    "原型屏幕与耗电。"
   ],
   [
    "sideshowCw",
    "为何没普及。"
   ],
   [
    "advisory",
    "安全公告。"
   ],
   [
    "gadgetsGone",
    "Windows 8 移除。"
   ],
   [
    "android15",
    "Android 1.5 框架。"
   ],
   [
    "ios7",
    "iOS 7「今天」。"
   ],
   [
    "ios8",
    "开放第三方。"
   ],
   [
    "ios14",
    "主屏幕小组件。"
   ],
   [
    "wwdc20",
    "WidgetKit 介绍。"
   ],
   [
    "widgetkitBudget",
    "时间轴与额度。"
   ],
   [
    "sonoma",
    "桌面小组件。"
   ],
   [
    "watch15",
    "发售与复杂功能。"
   ],
   [
    "watchos2",
    "watchOS 2。"
   ],
   [
    "ios16",
    "灵感来自复杂功能。"
   ],
   [
    "iphone14pro",
    "灵动岛。"
   ],
   [
    "ios161",
    "开放实时活动。"
   ],
   [
    "higLive",
    "实时活动准则。"
   ],
   [
    "ios17",
    "待机显示。"
   ],
   [
    "higWidgets",
    "准则与 HomeView。"
   ],
   [
    "homeview",
    "发布与规格。"
   ],
   [
    "homeviewTw",
    "台湾用词。"
   ],
   [
    "homeplaySrc",
    "规则写在程序里。"
   ]
  ],
  "reset": "重来",
  "exUi": {
   "loading": "展品载入中",
   "reduced": "已减少动态效果：动画改成直接切换。"
  }
 },
 "en": {
  "navLink": "A history of widgets",
  "title": "A history of widgets: from desk accessories to Live Activities | HomePlay",
  "ogTitle": "A history of widgets, from 1984 to today",
  "description": "From the Mac's 1984 desk accessories through Active Desktop, the Office Assistant, Dashboard and the Vista Sidebar to today's widgets, complications, Live Activities and HomeView. Every chapter lists its sources.",
  "ogAlt": "HomePlay desk pet: a white body with the time and a pair of eyes on screen",
  "keywords": "widgets, history, desk accessories, Active Desktop, Clippy, Office Assistant, Microsoft Agent, Konfabulator, Dashboard, Windows Sidebar, SideShow, complications, Live Activities, HomeView, HomePlay",
  "kicker": "HomePlay Notes 01 · Where a small screen came from",
  "h1": "How widgets came to be.",
  "lede": "A widget is a small program you read at a glance: a clock, the weather, a timer. This story runs from the 1984 Calculator through web pages on the wallpaper, the paper clip, Dashboard and the Vista Sidebar, to today's complications and Live Activities. For forty years the goal was one: show what you need at a glance, without interrupting you.",
  "meta": "Checked on 25 October 2026. Each chapter has one exhibit, redrawn by HomePlay in its own code: no screenshots, no original icons, fonts or characters. Single-source items are listed at the end.",
  "stripLabel": "Eras",
  "tocLabel": "Contents",
  "home": "Back to HomePlay",
  "lessonLabel": "What it left behind",
  "chapters": [
   {
    "id": "desk",
    "year": "1984",
    "short": "Desk accessories",
    "era": "1984 · Macintosh",
    "title": "One program at a time, and still a calculator on the desk.",
    "body": [
     "In the fall of 1981 the Macintosh team decided to run one application at a time, because memory and screen space were tight. Bud Tribble suggested a second kind of program: small, with one job, opening its own little window beside the main one. He called them desk ornaments. In the fall of 1982 the publications group found “ornament” too fancy and renamed them desk accessories.",
     "Andy Hertzfeld and his colleagues wrote the Calculator, Alarm Clock, Note Pad, Scrapbook, Key Caps, Control Panel and a sliding number Puzzle. Steve Jobs set the Calculator's look himself, with a “Calculator Construction Set” that Chris Espinosa built for him. The Puzzle was first written in Pascal and came to more than 6 KB, so it was nearly cut. Hertzfeld rewrote it in assembly over a weekend, down to about 600 bytes, and it shipped with the first Mac.",
     "All of them lived in the Apple menu. You opened one, used it and closed it. Your document stayed put. Apple later explained in Inside Macintosh that desk accessories were small applications built like device drivers, giving the Mac a limited kind of multitasking."
    ],
    "links": [
     "folkOrn",
     "folkCalc",
     "folkPuzzle",
     "infiniteMac",
     "imDevices"
    ],
    "lesson": "From the start, a widget let you stay in what you were doing: there when you needed it, gone when you were done."
   },
   {
    "id": "clippy",
    "year": "1997",
    "short": "Web and assistants",
    "era": "1997 → 2009 · Web and assistants",
    "title": "“It looks like you're writing a letter.”",
    "body": [
     "On 1 October 1997 Microsoft released Internet Explorer 4.0 worldwide, and with it changed the Windows desktop. Active Desktop showed live web content; Microsoft's own examples were stock tickers and weather maps. Active Channel turned websites into channels that pushed new content to you, with more than 500 sites at launch. The idea was a desktop that became a window onto information, one that never closes. But most people were on dial-up: wallpaper that keeps updating takes a phone line and memory, and it keeps moving at the edge of your eye. Later versions of Windows gave that space to other designs.",
     "On 19 November 1996 Office 97 was released to manufacturing, and it reached stores early the next year with the Office Assistant, which offered advice, interactive Help and tips from a corner of the window. Its best-known form was a paper clip named Clippit, which everyone called Clippy. Real research stood behind it: Microsoft Research's Lumière project used Bayesian models, math that reasons with probabilities, to infer what a user was trying to do and where they were stuck, and its 1998 paper states that Lumière prototypes were the basis for components of the Assistant. But guessing what you want to do does not tell it when to speak. People remember the line “It looks like you're writing a letter.” You had not asked. It appeared while you typed, in front of the words you were writing. Office XP in 2001 turned the Assistant off by default, and Microsoft ran a web campaign about it; a product manager said Office XP was so easy to use that Clippy was no longer necessary. The 2007 Office system dropped it.",
     "Animated characters became a component too. Microsoft Agent became a free download on 8 September 1997, and version 2.0, on 12 October 1998, added Peedy the parrot, joining Genie, Merlin the wizard and Robby the robot as the characters people saw most. A web page or an app could call a character with a few lines of script, and developers could add text-to-speech and speech recognition. So characters turned up everywhere, often at the wrong moment. Microsoft's documentation later marked Agent obsolete as of Windows 7."
    ],
    "links": [
     "ie4",
     "office97",
     "lumiere",
     "officexp",
     "office2007",
     "agent1",
     "agent2",
     "agentDoc"
    ],
    "lesson": "Speaking up first was the shared mistake of this era. Who may speak, and when, should be your choice."
   },
   {
    "id": "dashboard",
    "year": "2003 → 2009",
    "short": "Dashboard and Sidebar",
    "era": "2003 → 2009 · Dashboard · SideShow",
    "title": "Widgets got a name, and a layer of their own.",
    "body": [
     "In 2003 Arlo Rose and Perry Clarke released Konfabulator for Mac OS X, which let people make small programs that floated on the desktop. Yahoo! bought it in July 2005, made the $20 program free, and later renamed it Yahoo! Widgets. On 28 June 2004 Apple previewed Mac OS X Tiger at WWDC, and its Dashboard introduced widgets as a class of their own. Tiger went on sale on 29 April 2005 with 14 of them, built on web technologies such as HTML and JavaScript. One keystroke brought them to the top; another sent them all away. Rose said Apple had copied his idea. John Gruber disagreed on Daring Fireball and traced the idea back to the 1984 desk accessories. Both views are still around. No one disputes this: Dashboard gave widgets a layer of their own, easy to summon and easy to dismiss.",
     "Windows Vista reached consumers on 30 January 2007, and its gadgets could sit in a Sidebar at the edge of the desktop; Windows 7, on sale from 22 October 2009, let them sit anywhere. In the same years Microsoft built Windows SideShow: gadgets still ran on the PC while their content went to a second small screen, such as a laptop lid. The prototype described in MSDN Magazine had a 220 × 176 display that drew about 4 milliwatts, against roughly 75 watts for the whole PC, and it could keep showing the last synced content while the PC slept. SideShow did not catch on. In May 2007 Computerworld noted that consumers could buy only one SideShow laptop, from ASUS, and WeatherBug's SideShow version had fewer than 10,000 downloads against more than 600,000 for the desktop one. The small screen showed a snapshot; fresh content meant waking the PC, and reviews complained that it woke the whole laptop far too often."
    ],
    "links": [
     "konfab",
     "konfabCopycat",
     "gruber",
     "tiger04",
     "tiger05",
     "vista",
     "win7",
     "sideshowBlog",
     "sideshowMsdn",
     "sideshowCw"
    ],
    "lesson": "A glance works only if the screen stays near you, the content stays fresh, and updating it does not wake the whole computer. SideShow managed one of the three at a time."
   },
   {
    "id": "removed",
    "year": "2012",
    "short": "Withdrawn",
    "era": "2012 · Security Advisory 2719662",
    "title": "Gadgets were withdrawn because they could do too much.",
    "body": [
     "On 10 July 2012 Microsoft published Security Advisory 2719662: vulnerabilities in Windows Sidebar and gadgets could allow remote code execution. A legitimate gadget might have a flaw, or an attacker might trick you into installing a malicious one; either way, the code ran with your rights. Microsoft's fix was a tool that turned off Sidebar and gadgets entirely, and for Windows 8 its compatibility notes said gadgets were obsolete, replaced by live tiles and apps. Even harmless gadgets could be exploited, so they were removed from the operating system altogether."
    ],
    "links": [
     "advisory",
     "gadgetsGone"
    ],
    "lesson": "A gadget looks small, but it runs a full program. Anything that can run any code can be used to attack you."
   },
   {
    "id": "pocket",
    "year": "2009 → 2023",
    "short": "Phones and watches",
    "era": "2009 → 2023 · Android · iOS · Watch",
    "title": "Widgets moved onto phones and watches, and learned not to run all the time.",
    "body": [
     "Phones brought widgets back. In April 2009 Android 1.5 opened the AppWidget framework for home-screen widgets. In 2013 iOS 7 added Today to Notification Center, a view of your day at a glance, and the next year iOS 8 let third-party apps put widgets there. In 2020 iOS 14 put widgets on the Home Screen, where they can stack into a Smart Stack, and developers build them with WidgetKit. This time the lesson stuck: a widget is not a program that keeps running. The app hands over a timeline in advance, writing down what to show at each time, and the system swaps in the next view when its time comes. Apple's documentation says a frequently viewed widget typically gets 40 to 70 refreshes a day, roughly one every 15 to 60 minutes. In 2023 macOS Sonoma put widgets back on the Mac desktop, and through Continuity iPhone widgets could appear there too. Between Dashboard's separate layer and widgets right on the desktop, the way they save power and stay secure changed completely.",
     "A watch makes the glance as short as it can be: raise your wrist, look, lower it, a few seconds at most. Watchmakers call any extra function on a dial a complication, such as the date, the moon phase or a chronograph, and Apple Watch, on sale from 24 April 2015, kept the word; watchOS 2 that September let third-party apps build their own with ClockKit. One slot holds only the one thing you most need to know right now. In 2022 iOS 16 put widgets on the Lock Screen, and Apple said they took inspiration from Apple Watch complications.",
     "On 7 September 2022 Apple introduced iPhone 14 Pro and the Dynamic Island at the top of its screen, and iOS 16.1 opened Live Activities to third-party apps: your delivery's location, the score and the minutes left on a timer stay on the Lock Screen and in the Island. Apple's guidelines reserve them for events with a defined beginning and end, recommend a limit of eight hours, and say to end a Live Activity as soon as the event ends. In 2023 iOS 17 added StandBy: an iPhone set on its side while charging becomes a clock and widgets you can read from across the room. It was the first time the iPhone itself was treated as a screen that sits on a table."
    ],
    "links": [
     "android15",
     "ios7",
     "ios8",
     "ios14",
     "wwdc20",
     "widgetkitBudget",
     "sonoma",
     "watch15",
     "watchos2",
     "ios16",
     "iphone14pro",
     "ios161",
     "higLive",
     "ios17"
    ],
    "lesson": "Not running all the time, swapping views on a timeline; in view only while something is happening, gone when it ends."
   },
   {
    "id": "homeplay",
    "year": "2026",
    "short": "HomeView and HomePlay",
    "era": "2026 · HomeView · HomePlay",
    "title": "One shared screen, and an assistant that waits for you to ask.",
    "body": [
     "On 13 October 2026 Apple announced HomeView, a home display with a 7-inch Liquid Retina screen in tabletop and wall-mounted versions. Its faces include Photos, Flow, Snoopy, Home Modular and Home Camera. Each enrolled member of the household gets their own Home Screen and widgets, and the song that is playing, a running timer and an Intercom message from another room appear as Live Activities.",
     "Every earlier lesson shows up here. The desk accessory was at hand. Dashboard could be summoned and dismissed. SideShow wanted a second screen. WidgetKit has the timeline, the watch has its one right slot, and a Live Activity has a clear start and end.",
     "HomePlay is an open-source desk pet for the Mac that looks like HomeView, with a pair of 👀 in the capsule at the top. Most of the time it just watches, quietly. It lights up when you come near, and it stays out of your way while you work. Its assistant ClioTalk turns what Clippy taught into rules. ClioTalk never pops up on its own; it starts listening only when you hold F5 or click it. Its answers are temporary until you choose to keep them. Anything done in your name, like sending a message, placing a call, adding an event or unlocking a door, is read back first and waits for your OK. When it drafts a message for you, it uses your own words and does not polish them into its voice.",
     "These rules do not promise that it always guesses right. They promise that when it guesses wrong, it will not do something you did not agree to. Forty years ago the Calculator in the Apple menu came out when you needed it and went away when you were done. We want HomePlay to work the same way."
    ],
    "links": [
     "homeview",
     "homeviewTw",
     "higWidgets",
     "homeplaySrc"
    ],
    "lesson": ""
   }
  ],
  "timelineTitle": "Timeline",
  "timelineLede": "The same story in order; the last column is what each step taught.",
  "timelineHead": [
   "When",
   "What happened",
   "What it left behind"
  ],
  "timeline": [
   [
    "Fall 1981",
    "Bud Tribble proposes desk ornaments, renamed desk accessories in 1982",
    "Small programs beside the main one"
   ],
   [
    "1984",
    "The first Mac's menu holds the Calculator, Puzzle and more",
    "At hand, and gone when done"
   ],
   [
    "1996-11-19",
    "Office 97 ships, with the Office Assistant",
    "Guessing right is not a reason to speak"
   ],
   [
    "1997-10-01",
    "Internet Explorer 4.0 and Active Desktop",
    "Constant updates have a cost"
   ],
   [
    "2001",
    "Office XP turns the Assistant off by default",
    "Interruptions start to matter"
   ],
   [
    "2003",
    "Konfabulator released",
    "Widgets become a kind of software"
   ],
   [
    "2005-04-29",
    "Tiger ships; Dashboard includes 14 widgets",
    "Easy to summon, easy to dismiss"
   ],
   [
    "2007-01-30",
    "Windows Vista: Sidebar and SideShow",
    "A second screen ships"
   ],
   [
    "2009-04",
    "Android 1.5 opens home-screen widgets",
    "Widgets move into the pocket"
   ],
   [
    "2012-07-10",
    "Security Advisory 2719662; Windows 8 removes gadgets",
    "Running any code carries risk"
   ],
   [
    "2015-04-24",
    "Apple Watch ships with complications",
    "Smaller space, sharper choice"
   ],
   [
    "2020",
    "iOS 14 Home Screen widgets and WidgetKit",
    "A timeline swaps the view"
   ],
   [
    "2022",
    "Lock Screen widgets, Dynamic Island, Live Activities",
    "Bounded things stay in view"
   ],
   [
    "2023",
    "iOS 17 StandBy; macOS Sonoma desktop widgets",
    "Widgets return to the Mac desktop"
   ],
   [
    "2026-10-13",
    "Apple announces HomeView",
    "One screen shared by a household"
   ],
   [
    "2026",
    "HomePlay: ClioTalk waits until you ask",
    "An assistant waits first, then acts"
   ]
  ],
  "unsureTitle": "What we are not sure of",
  "unsureLede": "These rest on secondary sources or on claims that disagree; the text avoids them or says who claims them.",
  "unsure": [
   "Which desk accessories shipped on the first Mac: the full list is Wikipedia only; we do not count the Chooser.",
   "Internet Explorer 4.0's date: Microsoft's release says 1 October 1997 worldwide; another source says 22 September.",
   "Active Desktop being replaced by the Sidebar in Vista: only Wikipedia and forum posts, no Microsoft source.",
   "What triggered “It looks like you're writing a letter”, and Kevan Atteberry's sketches: only secondary press.",
   "Konfabulator's exact release date, and the roles of Perry Clarke and Ed Voas: only Wikipedia.",
   "Windows 7 dropping the Sidebar bar: only Wikipedia and trade press.",
   "HomeView's faces: Apple's Taiwan newsroom translates them as 「桌面」, unlike the Watch's 「錶面」. HomePlay calls its own faces 錶面."
  ],
  "sourcesTitle": "Sources",
  "sourcesLede": "Every year, number and quote can be found below; primary material comes first.",
  "notice": "HomePlay is an independent open-source project, not affiliated with Apple, Microsoft, Google or Yahoo; names belong to their owners, and the exhibits are illustrations. Checked on 25 October 2026. If you spot a mistake, please tell us on GitHub.",
  "sources": [
   [
    "folkOrn",
    "Where desk accessories came from."
   ],
   [
    "folkCalc",
    "How the Calculator's look was set."
   ],
   [
    "folkPuzzle",
    "The Puzzle rewritten."
   ],
   [
    "imDevices",
    "Apple's definition."
   ],
   [
    "infiniteMac",
    "System 1.0 in a browser; loads on click."
   ],
   [
    "ie4",
    "Active Desktop and channels."
   ],
   [
    "office97",
    "Office 97 and the Assistant."
   ],
   [
    "lumiere",
    "Lumière and the Assistant."
   ],
   [
    "officexp",
    "Turned off by default."
   ],
   [
    "office2007",
    "Dropped in 2007."
   ],
   [
    "agent1",
    "Agent free to download."
   ],
   [
    "agent2",
    "2.0 and Peedy."
   ],
   [
    "agentDoc",
    "Obsolete from Windows 7."
   ],
   [
    "konfab",
    "Acquired, made free."
   ],
   [
    "konfabCopycat",
    "Rose's response."
   ],
   [
    "gruber",
    "Back to desk accessories."
   ],
   [
    "tiger04",
    "Tiger previewed."
   ],
   [
    "tiger05",
    "Ship date and 14 widgets."
   ],
   [
    "vista",
    "Vista and the Sidebar."
   ],
   [
    "win7",
    "Windows 7's date."
   ],
   [
    "sideshowBlog",
    "The team's explanation."
   ],
   [
    "sideshowMsdn",
    "Prototype screen and power."
   ],
   [
    "sideshowCw",
    "Why it did not catch on."
   ],
   [
    "advisory",
    "The security advisory."
   ],
   [
    "gadgetsGone",
    "Windows 8 removes gadgets."
   ],
   [
    "android15",
    "Android 1.5's framework."
   ],
   [
    "ios7",
    "Today in iOS 7."
   ],
   [
    "ios8",
    "Opened to third parties."
   ],
   [
    "ios14",
    "Home Screen widgets."
   ],
   [
    "wwdc20",
    "WidgetKit introduced."
   ],
   [
    "widgetkitBudget",
    "Timelines and budget."
   ],
   [
    "sonoma",
    "Desktop widgets."
   ],
   [
    "watch15",
    "Launch and complications."
   ],
   [
    "watchos2",
    "watchOS 2."
   ],
   [
    "ios16",
    "Inspired by complications."
   ],
   [
    "iphone14pro",
    "The Dynamic Island."
   ],
   [
    "ios161",
    "Live Activities opened."
   ],
   [
    "higLive",
    "Live Activities guidelines."
   ],
   [
    "ios17",
    "StandBy."
   ],
   [
    "higWidgets",
    "Guidelines and HomeView."
   ],
   [
    "homeview",
    "Announcement and specs."
   ],
   [
    "homeviewTw",
    "Taiwan wording."
   ],
   [
    "homeplaySrc",
    "The rules live in code."
   ]
  ],
  "reset": "Reset",
  "exUi": {
   "loading": "Loading the exhibit",
   "reduced": "Reduced motion is on: animations switch instantly."
  }
 }
};

for (const [lang, d] of Object.entries(DATA)) for (const k of [...d.chapters.flatMap((c) => c.links), ...d.sources.map((x) => x[0])]) if (!S[k]) throw new Error(`history.mjs: ${lang} cites unknown source ${k}`);

/** 每種語言一份：章節出處換成 [標題, 網址]；出處清單換成 [種類, 標題, 網址, 註記]。 */
export const history = Object.fromEntries(Object.entries(DATA).map(([lang, d]) => [lang, {
  ...d,
  checked: CHECKED,
  chapters: d.chapters.map((c) => ({ ...c, links: c.links.map((k) => [S[k][1], S[k][2]]) })),
  sources: d.sources.map(([k, note]) => [kindIn(lang, S[k][0]), S[k][1], S[k][2], note]),
}]));

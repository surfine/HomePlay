// 小工具往事：一篇有出處的長文，三種語言同一個形狀；版面在 build.mjs 的 historyPage()。
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
const DATA = {
 "zh-Hant": {
  "navLink": "小工具往事",
  "title": "小工具往事：從桌面附件到即時動態｜HomePlay",
  "ogTitle": "小工具往事：瞥一眼就夠的小工具，是這樣來的",
  "description": "從 1984 年 Mac 的桌面附件，講到 Active Desktop、Office 小幫手、Microsoft Agent、Dashboard、Vista 側邊欄與 SideShow，再到今天的小工具、複雜功能和即時動態。每一段都附出處。",
  "ogAlt": "HomePlay 桌寵：白色機身，螢幕上是時間和一雙眼睛",
  "keywords": "小工具, widgets, 桌面附件, Desk Accessory, Active Desktop, Clippy, Microsoft Agent, Konfabulator, Dashboard, Windows 側邊欄, SideShow, 複雜功能, 即時動態, HomeView, HomePlay",
  "kicker": "HomePlay 札記 01 · 一塊小螢幕的來歷",
  "h1": "<span class=\"l\">瞥一眼就夠的小工具，</span><span class=\"l\">是這樣來的。</span>",
  "lede": "小工具是一眼就能看懂的小程式，像時鐘、天氣和計時器。這篇從 1984 年蘋果選單裡的計算機講起，經過 Active Desktop、迴紋針小幫手、Dashboard 和 Vista 側邊欄，講到今天的小工具、複雜功能和即時動態。四十年來，大家想做到的是同一件事：不打斷你，又讓你一眼看到需要的資訊。",
  "meta": "查證於 2026 年 10 月 25 日。每一章有一件可以動手玩的展品。展品由 HomePlay 用自己的程式碼重畫，不是當年的截圖，也沒有用原廠的圖示、字型或角色。每一章後面附出處。只有二手來源的地方，列在文末「還不確定的地方」。",
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
     "1981 年秋天，Macintosh 團隊決定一次只跑一個應用程式，因為記憶體和螢幕都太小。Bud Tribble 提議另做一種小程式：在主程式旁邊開一個小視窗，只做一件事。他叫它們「桌面擺飾」（desk ornaments）。1982 年秋天，文件組覺得「擺飾」聽起來太花俏，改名「桌面附件」（desk accessories）。",
     "Andy Hertzfeld 和同事寫出計算機、鬧鐘、記事本、剪貼簿、Key Caps、控制面板，還有一個數字滑塊拼圖。計算機的外觀是 Steve Jobs 親手調的，他用的是 Chris Espinosa 做的「計算機組合工具」。拼圖原本用 Pascal 寫，超過 6 KB，一度不打算出貨。Hertzfeld 花一個週末用組合語言重寫，縮到大約 600 位元組，它才跟著第一台 Mac 出貨。",
     "這些附件都收在蘋果選單裡。要用時打開，用完關掉，手上的文件一直都在。Apple 後來在 Inside Macintosh 裡解釋：桌面附件是做得像裝置驅動程式的小應用程式，目的是讓 Mac 能有限地同時做幾件事（多工）。"
    ],
    "links": [
     "folkOrn",
     "folkCalc",
     "folkPuzzle",
     "infiniteMac",
     "imDevices"
    ],
    "lesson": "小工具從一開始就是為了讓你不必離開手上的事。要用時拿得到，用完就收。"
   },
   {
    "id": "active",
    "year": "1997",
    "short": "Active Desktop",
    "era": "1997 · Internet Explorer 4",
    "title": "把網頁鋪在桌布上。",
    "body": [
     "1997 年 10 月 1 日，Microsoft 在全球推出 Internet Explorer 4.0，也一起改了 Windows 桌面。新的「Active Desktop」讓桌面直接顯示網頁內容，Microsoft 舉的例子是股票報價和天氣圖。另一項「Active Channel」把網站做成頻道，自動把新內容推送過來。桌面邊有一條頻道列，首發時有 500 多個網站提供內容。",
     "這個想法讓桌面變成一扇一直開著的資訊窗。但當時大家用撥接上網。一直更新的桌布會佔用電話線和記憶體，也一直在你眼角動。後來的 Windows 把這塊位置交給了別的設計。"
    ],
    "links": [
     "ie4"
    ],
    "lesson": "內容一直更新，不代表有用。每次更新都要付出網路、電力和注意力。"
   },
   {
    "id": "clippy",
    "year": "1997",
    "short": "Office 小幫手",
    "era": "1997 · Office 97",
    "title": "「看起來你在寫信。」",
    "body": [
     "1996 年 11 月 19 日，Office 97 完成送廠，隔年初上市。新功能裡有一位「Office 小幫手」（Office Assistant）。它待在視窗角落，提供建議、互動說明和小訣竅。最出名的造型是一支迴紋針，叫 Clippit，大家叫它 Clippy。",
     "它背後有認真的研究。Microsoft Research 的 Lumière 計畫用貝氏網路推測使用者想做什麼、卡在哪裡。貝氏網路是一種用機率來推理的數學模型。1998 年發表的論文寫明，Office 97 小幫手有部分元件以 Lumière 的原型為基礎。可是猜得到你要做什麼，不代表該在那時開口。",
     "大家記得最清楚的是那句「看起來你在寫信」。你沒有問，它就在你打字時跳出來，擋住正在寫的字。2001 年的 Office XP 把小幫手預設關閉。Microsoft 還為此辦了一波網路宣傳，產品經理說 Office XP 好用到不再需要 Clippy。2007 年版 Office 淘汰了小幫手。"
    ],
    "links": [
     "office97",
     "lumiere",
     "officexp",
     "office2007"
    ],
    "lesson": "猜對了也可能打擾人。助手要先等你開口，再等你說好。"
   },
   {
    "id": "agent",
    "year": "1997 → 2009",
    "short": "Microsoft Agent",
    "era": "1997 → 2009 · Microsoft Agent",
    "title": "誰都能請一位角色上台。",
    "body": [
     "Microsoft 也把會動的角色做成元件，讓所有開發者使用。1997 年 9 月 8 日，Microsoft Agent 開放免費下載。1998 年 10 月 12 日的 2.0 版加入鸚鵡 Peedy。它和精靈 Genie、魔法師 Merlin、機器人 Robby 是最常見的四個角色。",
     "網頁和程式用幾行指令就能叫角色出場：走到某個位置、做個動作、開口說話。開發者還可以加上文字轉語音和語音辨識。所以角色到處都是，也常在不對的時候出現。",
     "Microsoft 後來在文件裡寫明：Windows 7 起淘汰 Microsoft Agent，之後的 Windows 可能不再提供。"
    ],
    "links": [
     "agent1",
     "agent2",
     "agentDoc"
    ],
    "lesson": "誰都能呼叫角色，等於每個網頁都能決定它什麼時候開口。這個時機應該由使用者決定。"
   },
   {
    "id": "dashboard",
    "year": "2003 → 2005",
    "short": "Dashboard",
    "era": "2003 → 2005 · Konfabulator · Mac OS X Tiger",
    "title": "小工具有了名字，也有了自己的一層。",
    "body": [
     "2003 年，Arlo Rose 和 Perry Clarke 在 Mac OS X 上推出 Konfabulator。它讓人做出浮在桌面上的小程式。2005 年 7 月，Yahoo! 買下它，把原本 20 美元的軟體改成免費，後來改名 Yahoo! Widgets。",
     "2004 年 6 月 28 日，Apple 在 WWDC 預覽 Mac OS X Tiger。Tiger 裡的 Dashboard 把這類小程式叫做「widgets」。2005 年 4 月 29 日 Tiger 上市，內附 14 個小工具，用 HTML 和 JavaScript 這些網頁技術寫成。按一個鍵，小工具浮到最上層。再按一次，全部收起。",
     "Rose 當時說 Apple 抄了他的點子。John Gruber 寫文章反駁，把源頭追回 1984 年的桌面附件。兩種說法都還在。沒有爭議的是：Dashboard 讓小工具有了自己的一層，叫得出來，也收得回去。"
    ],
    "links": [
     "konfab",
     "konfabCopycat",
     "gruber",
     "tiger04",
     "tiger05"
    ],
    "lesson": "給小工具一個能收起來的地方，比讓它一直開著好。看完就收，桌面還是你的。"
   },
   {
    "id": "sidebar",
    "year": "2007",
    "short": "側邊欄與 SideShow",
    "era": "2007 · Windows Vista",
    "title": "一條側邊欄，和電腦外面的一塊小螢幕。",
    "body": [
     "2007 年 1 月 30 日，Windows Vista 上市。Microsoft 說小工具（gadgets）是把即時線上內容和資料送到桌面的小程式。小工具可以放進「側邊欄」，也就是桌面側邊的一個窗格。2009 年 10 月 22 日上市的 Windows 7 讓小工具直接擺在桌面上。",
     "同一時期，Microsoft 還做了 Windows SideShow。小工具照樣在電腦上跑，畫面卻送到另一塊小螢幕，例如筆電外蓋、鍵盤或遙控器。電腦睡著時，小螢幕還能顯示上次同步的內容。MSDN 雜誌介紹的原型螢幕是 220 × 176，開著大約耗電 4 毫瓦，整台電腦大約 75 瓦。",
     "SideShow 沒有普及。2007 年 5 月，Computerworld 指出消費者買得到的 SideShow 筆電只有華碩一款。WeatherBug 的 SideShow 版下載不到一萬次，桌面版超過六十萬次。小螢幕上只是快照，要看新內容就得叫醒電腦。評測也抱怨：為了讓信件和行事曆保持最新，電腦要常常從待機醒來。"
    ],
    "links": [
     "vista",
     "win7",
     "sideshowBlog",
     "sideshowMsdn",
     "sideshowCw"
    ],
    "lesson": "要能瞥一眼，螢幕得一直在身邊，內容得一直是新的，更新時也不能叫醒整台電腦。SideShow 一次只做到其中一件。"
   },
   {
    "id": "removed",
    "year": "2012",
    "short": "收回",
    "era": "2012 · Security Advisory 2719662",
    "title": "小工具被收回，因為它能做的事太多了。",
    "body": [
     "2012 年 7 月 10 日，Microsoft 發布安全公告 2719662。公告說，Windows 側邊欄和小工具的漏洞可能讓人從遠端執行程式碼。正常的小工具可能有漏洞，攻擊者也可能騙你裝上惡意的小工具。兩種情況都能用你的權限執行任何程式。Microsoft 給的辦法是一個工具，把側邊欄和小工具整個關掉。",
     "到了 Windows 8，Microsoft 在相容性文件裡寫：小工具已經淘汰，由動態磚和 App 取代。就連無害的小工具也可能被利用，所以 Microsoft 把小工具從系統裡完全移除。"
    ],
    "links": [
     "advisory",
     "gadgetsGone"
    ],
    "lesson": "桌面上的小工具看起來很小，跑的卻是完整的程式。只要能執行任何程式碼，它就可能被拿來攻擊你。"
   },
   {
    "id": "pocket",
    "year": "2009 → 2023",
    "short": "口袋裡的小工具",
    "era": "2009 → 2023 · Android · iOS · macOS",
    "title": "小工具進了手機，也學會不一直執行。",
    "body": [
     "手機把小工具帶了回來。2009 年 4 月，Android 1.5 開放主畫面小工具框架（AppWidget）。2013 年，iOS 7 在通知中心加入「今天」，一眼看完今天的事。隔年 iOS 8 讓第三方 App 也能在這裡放小工具。",
     "2020 年，iOS 14 讓小工具放上主畫面，還能疊成「智慧型堆疊」。開發者用新的 WidgetKit 來做。這次的做法記取了前人的教訓：小工具不是一直在跑的程式。App 先交出一條時間軸，寫好每個時間該顯示的畫面，系統到時間就換上下一格。Apple 的文件寫，常被查看的小工具，一天通常有 40 到 70 次更新額度，大約每 15 到 60 分鐘一次。",
     "2023 年，macOS Sonoma 讓小工具回到 Mac 桌面。iPhone 的小工具也能透過接續互通出現在 Mac 上。從 Dashboard 的那一層，到直接擺在桌面上，中間換了一整套更省電、更安全的做法。"
    ],
    "links": [
     "android15",
     "ios7",
     "ios8",
     "ios14",
     "wwdc20",
     "widgetkitBudget",
     "sonoma"
    ],
    "lesson": "小工具不必一直執行。先決定什麼時候該變，再讓系統按時間換畫面。這樣省電，也更安全。"
   },
   {
    "id": "wrist",
    "year": "2015",
    "short": "複雜功能",
    "era": "2015 · Apple Watch",
    "title": "錶面上的一小格，叫做複雜功能。",
    "body": [
     "鐘錶業把錶盤上報時以外的功能叫做 complication，例如日期、月相和計時。2015 年 4 月 24 日開賣的 Apple Watch 沿用這個詞，中文叫「複雜功能」。Apple 說它們是錶面上的專門功能。同年 9 月，watchOS 2 開放第三方 App 用 ClockKit 做自己的複雜功能。",
     "手錶把「瞥一眼」縮到最短：抬手、看、放下，只有幾秒。一小格只放得下此刻最需要的那一件事。2022 年，iOS 16 把小工具放上鎖定畫面。Apple 說靈感來自 Apple Watch 的複雜功能。"
    ],
    "links": [
     "watch15",
     "watchos2",
     "ios16"
    ],
    "lesson": "空間越小，越要選對內容。要問的是：這一刻該放什麼。"
   },
   {
    "id": "live",
    "year": "2022 → 2023",
    "short": "即時動態",
    "era": "2022 → 2023 · 即時動態 · 待機模式",
    "title": "有開始、有結束的事，就讓它一直看得到。",
    "body": [
     "2022 年 9 月 7 日，Apple 發表 iPhone 14 Pro 和螢幕頂端的「動態島」。之後的 iOS 16.1 讓第三方 App 也能使用「即時動態」。外送到哪裡、比數多少、計時還剩幾分，會留在鎖定畫面和動態島上。Apple 的設計準則只讓它用在有明確開始和結束的事，建議不超過八小時。事情一結束，它就要馬上結束。",
     "2023 年，iOS 17 加入「待機模式」。iPhone 橫放充電時，會變成從遠處也看得清楚的時鐘、照片和小工具，也能全螢幕顯示即時動態。Apple 說這是一種瀏覽一眼即知資訊的新方式。這是 iPhone 第一次被當成一塊放在桌上的螢幕。"
    ],
    "links": [
     "iphone14pro",
     "ios161",
     "higLive",
     "ios17"
    ],
    "lesson": "事情進行時才出現，結束就消失。這樣的提醒最少打擾人。"
   },
   {
    "id": "homeview",
    "year": "2026",
    "short": "HomeView",
    "era": "2026 · Apple HomeView",
    "title": "一塊放在家裡、大家共用的螢幕。",
    "body": [
     "2026 年 10 月 13 日，Apple 發表 HomeView。它是一台家用顯示器，有 7 吋 Liquid Retina 螢幕，分桌上型和壁掛型。它有好幾種可以切換的畫面：Photos、Flow、Snoopy、Home Modular、Home Camera（Apple 台灣稱為「桌面」）。每位登記過的家人有自己的主畫面和小工具。正在播的歌、計時器、從別的房間傳來的對講，都用即時動態顯示。",
     "前面每一章學到的事，在這裡都看得到：桌面附件的隨手可得，Dashboard 的叫得出也收得回，SideShow 想要的另一塊螢幕，WidgetKit 的時間軸，手錶上選對的一格，還有即時動態的有始有終。"
    ],
    "links": [
     "homeview",
     "homeviewTw",
     "higWidgets"
    ],
    "lesson": ""
   },
   {
    "id": "homeplay",
    "year": "2026",
    "short": "HomePlay",
    "era": "2026 · HomePlay",
    "title": "在 Mac 上，等你開口。",
    "body": [
     "HomePlay 是 Mac 上的開源桌寵，長得像 HomeView。它有錶面、小工具和即時動態，頂端的膠囊裡有一雙 👀。它大部分時間只是看著你，不出聲。你靠近，它才亮起來。你專心工作時，它不吵你。",
     "它有一位助手，叫 ClioTalk。我們把從 Clippy 學到的事寫成了規則。ClioTalk 不會自己跳出來；你按住 F5 或點它，它才開始聽。它的回答是暫時的，你說要留下才會存。凡是用你的名義做的事，像傳訊息、打電話、加行程、解開門鎖，它都先唸給你聽，等你說好。替你寫訊息時，它用你自己說的話，不改成它的口氣。",
     "這些規則不保證它永遠猜對。它們保證的是：它猜錯時，不會替你做你沒答應的事。四十年前蘋果選單裡的計算機，要用時才出來，用完就收。我們希望 HomePlay 也是這樣。"
    ],
    "links": [
     "homeplaySrc"
    ],
    "lesson": ""
   }
  ],
  "timelineTitle": "年表",
  "timelineLede": "照時間排一次。最右邊一欄是後來的人從那一步學到的事。",
  "timelineHead": [
   "時間",
   "發生了什麼",
   "留下的"
  ],
  "timeline": [
   [
    "1981 秋",
    "Bud Tribble 提出「桌面擺飾」，1982 年秋改名桌面附件",
    "小程式可以陪在主程式旁邊"
   ],
   [
    "1984",
    "第一台 Mac 的蘋果選單裡有計算機、鬧鐘、記事本、拼圖等附件",
    "隨手可得，用完就收"
   ],
   [
    "1996-11-19",
    "Office 97 完成送廠，附 Office 小幫手",
    "猜得到，不代表該開口"
   ],
   [
    "1997-09-08",
    "Microsoft Agent 開放免費下載",
    "角色成了誰都能呼叫的元件"
   ],
   [
    "1997-10-01",
    "Internet Explorer 4.0：Active Desktop 與 Active Channel",
    "一直更新有代價"
   ],
   [
    "1998-10-12",
    "Microsoft Agent 2.0，加入 Peedy",
    ""
   ],
   [
    "2001",
    "Office XP 預設關閉小幫手",
    "開始在意打擾"
   ],
   [
    "2003",
    "Konfabulator 在 Mac OS X 上推出",
    "小工具成了一種軟體類別"
   ],
   [
    "2004-06-28",
    "Apple 預覽 Tiger 與 Dashboard",
    ""
   ],
   [
    "2005-04-29",
    "Tiger 上市，Dashboard 內附 14 個小工具",
    "叫得出，也收得回"
   ],
   [
    "2005-07",
    "Yahoo! 收購 Konfabulator，改為免費",
    ""
   ],
   [
    "2007-01-30",
    "Windows Vista 上市：側邊欄、小工具、SideShow",
    "另一塊螢幕第一次出貨"
   ],
   [
    "2007",
    "2007 年版 Office 淘汰小幫手",
    ""
   ],
   [
    "2009-04",
    "Android 1.5 開放主畫面小工具框架",
    "小工具進了口袋"
   ],
   [
    "2009-10-22",
    "Windows 7 上市；小工具可直接放在桌面；Agent 從這一版起淘汰",
    ""
   ],
   [
    "2012-07-10",
    "安全公告 2719662：建議關閉側邊欄與小工具",
    "能執行任何程式，就有風險"
   ],
   [
    "2012",
    "Windows 8 把小工具從系統移除",
    ""
   ],
   [
    "2013",
    "iOS 7 通知中心加入「今天」",
    "一眼看完今天"
   ],
   [
    "2014",
    "iOS 8 開放第三方小工具",
    ""
   ],
   [
    "2015-04-24",
    "Apple Watch 開賣，錶面上有複雜功能",
    "空間越小越要選對"
   ],
   [
    "2015-09",
    "watchOS 2 開放第三方複雜功能（ClockKit）",
    ""
   ],
   [
    "2020",
    "iOS 14 主畫面小工具與 WidgetKit；macOS Big Sur 通知中心小工具",
    "不一直執行，按時間軸換畫面"
   ],
   [
    "2022",
    "iOS 16 鎖定畫面小工具；iPhone 14 Pro 動態島；iOS 16.1 即時動態",
    "有始有終的事才一直看得到"
   ],
   [
    "2023",
    "iOS 17 待機模式與可互動小工具；macOS Sonoma 桌面小工具",
    "小工具回到 Mac 桌面"
   ],
   [
    "2026-10-13",
    "Apple 發表 HomeView",
    "一塊大家共用的螢幕"
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
   "第一台 Mac 出貨時到底附了哪幾個桌面附件：Folklore.org 的故事寫了團隊做了哪些，完整出貨清單只有維基百科。我們沒有把 Chooser 算進 1984 年。",
   "Internet Explorer 4.0 的日期：Microsoft 新聞稿是 1997 年 10 月 1 日全球上市，發表活動在前一天，也有來源寫 9 月 22 日。",
   "Active Desktop 在 Windows Vista 被拿掉、由側邊欄取代：只找到維基百科（轉引 PC Magazine 2006 年報導）與論壇說法，沒有 Microsoft 原文。",
   "「看起來你在寫信」在什麼條件下出現（打了地址再打 Dear），以及設計師 Kevan Atteberry 畫過多少草稿：只有維基百科與二手報導。",
   "2001 年那波「Clippy 失業了」宣傳：引用的是同期的 internetnews.com 報導，Microsoft 自己的新聞稿頁面打不開。",
   "Microsoft Agent 1.5 版是否存在、XP 搜尋小狗 Rover 是否是 Agent 角色：沒有找到可靠來源，正文不寫。",
   "Konfabulator 的確切發表日（2003 年 2 月 10 日）與 Perry Clarke、Ed Voas 的角色：只有維基百科；Arlo Rose 的部分有同期報導。",
   "Windows 7 拿掉「側邊欄」這條欄、讓小工具自由擺放的細節：只有維基百科與業界媒體。",
   "Windows 8.1 移除 SideShow 裝置支援（2013）：只有維基百科，正文因此不寫年份。",
   "Dashboard 在 OS X Yosemite 預設關閉、在 macOS Catalina 移除：只有二手報導，正文不寫。",
   "iOS 16.1 的上市日（2022 年 10 月 24 日）：Apple 的支援頁沒有日期，日期來自新聞報導。",
   "HomeView 的「桌面」：Apple 台灣新聞稿把 faces 譯作「桌面」，和 Apple Watch 的「錶面」不同；HomePlay 自己的畫面照首頁一律叫錶面。"
  ],
  "sourcesTitle": "出處",
  "sourcesLede": "文中的年份、數字和引述，都能在下面找到。我們優先列一手資料：當年的新聞稿、官方文件、親歷者的回憶。",
  "notice": "HomePlay 是獨立的開源專案，與 Apple、Microsoft、Google、Yahoo 無關。文中的產品和角色名稱屬於各自的權利人，這裡只引用名稱。Macintosh、Apple Watch、HomeView、Dynamic Island 是 Apple Inc. 的商標；Windows、Office、Clippit 是 Microsoft 的商標。展品只是示意，不是原產品。查證於 2026 年 10 月 25 日。發現錯誤，請在 GitHub 告訴我們。",
  "sources": [
   [
    "folkOrn",
    "桌面附件的由來、改名，以及為什麼一次只跑一個程式。"
   ],
   [
    "folkCalc",
    "計算機的外觀怎麼定下來。"
   ],
   [
    "folkPuzzle",
    "拼圖從 Pascal 改寫成組合語言，留在第一版。"
   ],
   [
    "imDevices",
    "Apple 對桌面附件的定義與用途。"
   ],
   [
    "infiniteMac",
    "在瀏覽器裡跑真正的 System 1.0。點了才會在新分頁載入；本站不嵌入，也不存放系統映像。"
   ],
   [
    "ie4",
    "Active Desktop、Active Channel、頻道列與 500 多個網站。"
   ],
   [
    "office97",
    "Office 97 送廠日期與 Office 小幫手的說明。"
   ],
   [
    "lumiere",
    "Lumière 計畫與 Office 97 小幫手的關係。"
   ],
   [
    "officexp",
    "Office XP 預設關閉小幫手，與那波宣傳。"
   ],
   [
    "office2007",
    "2007 年版 Office 淘汰小幫手。"
   ],
   [
    "agent1",
    "Microsoft Agent 開放免費下載。"
   ],
   [
    "agent2",
    "Agent 2.0、Peedy、網頁腳本與語音。"
   ],
   [
    "agentDoc",
    "Microsoft Agent 從 Windows 7 起淘汰。"
   ],
   [
    "konfab",
    "Yahoo! 收購 Konfabulator，改為免費。"
   ],
   [
    "konfabCopycat",
    "Arlo Rose 對 Dashboard 的回應。"
   ],
   [
    "gruber",
    "把 Dashboard 的源頭追回桌面附件的另一種看法。"
   ],
   [
    "tiger04",
    "WWDC 2004 預覽 Dashboard 與 widgets。"
   ],
   [
    "tiger05",
    "Tiger 上市日、14 個小工具與網頁技術。"
   ],
   [
    "vista",
    "Vista 上市與小工具、側邊欄的官方說法。"
   ],
   [
    "win7",
    "Windows 7 上市日期。"
   ],
   [
    "sideshowBlog",
    "SideShow 團隊自己的說明。"
   ],
   [
    "sideshowMsdn",
    "SideShow 的運作、原型螢幕與耗電數字。"
   ],
   [
    "sideshowCw",
    "SideShow 為什麼沒有普及。"
   ],
   [
    "advisory",
    "側邊欄與小工具的安全公告。"
   ],
   [
    "gadgetsGone",
    "Windows 8 移除小工具的理由。"
   ],
   [
    "android15",
    "Android 1.5 的主畫面小工具框架。"
   ],
   [
    "ios7",
    "iOS 7 通知中心的「今天」。"
   ],
   [
    "ios8",
    "iOS 8 開放小工具等擴充功能。"
   ],
   [
    "ios14",
    "iOS 14 主畫面小工具與智慧型堆疊。"
   ],
   [
    "wwdc20",
    "WidgetKit 的介紹。"
   ],
   [
    "widgetkitBudget",
    "小工具的時間軸與每日更新額度。"
   ],
   [
    "sonoma",
    "macOS Sonoma 桌面小工具與接續互通。"
   ],
   [
    "watch15",
    "Apple Watch 開賣日與複雜功能的定義。"
   ],
   [
    "watchos2",
    "watchOS 2 與 ClockKit。"
   ],
   [
    "ios16",
    "鎖定畫面小工具的靈感來自複雜功能。"
   ],
   [
    "iphone14pro",
    "iPhone 14 Pro 與動態島。"
   ],
   [
    "ios161",
    "iOS 16.1 讓第三方 App 使用即時動態。"
   ],
   [
    "higLive",
    "即時動態的設計準則：有始有終、時間上限。"
   ],
   [
    "ios17",
    "待機模式。"
   ],
   [
    "higWidgets",
    "小工具的設計準則，以及 HomeView 的個人主畫面。"
   ],
   [
    "homeview",
    "HomeView 發表、螢幕、畫面與即時動態。"
   ],
   [
    "homeviewTw",
    "HomeView 在台灣的中文用詞。"
   ],
   [
    "homeplaySrc",
    "HomePlay 與 ClioTalk 的原始碼，規則寫在程式裡。"
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
  "description": "从 1984 年 Mac 的桌面附件，讲到 Active Desktop、Office 助手、Microsoft Agent、Dashboard、Vista 侧边栏与 SideShow，再到今天的小组件、复杂功能和实时活动。每一段都附出处。",
  "ogAlt": "HomePlay 桌宠：白色机身，屏幕上是时间和一双眼睛",
  "keywords": "小工具, widgets, 桌面附件, Desk Accessory, Active Desktop, Clippy, Microsoft Agent, Konfabulator, Dashboard, Windows 侧边栏, SideShow, 复杂功能, 实时活动, HomeView, HomePlay",
  "kicker": "HomePlay 札记 01 · 一块小屏幕的来历",
  "h1": "<span class=\"l\">瞥一眼就够的小组件，</span><span class=\"l\">是这样来的。</span>",
  "lede": "小组件是一眼就能看懂的小程序，像时钟、天气和计时器。这篇从 1984 年苹果菜单里的计算机讲起，经过 Active Desktop、回形针助手、Dashboard 和 Vista 侧边栏，讲到今天的小组件、复杂功能和实时活动。四十年来，大家想做到的是同一件事：不打断你，又让你一眼看到需要的信息。",
  "meta": "查证于 2026 年 10 月 25 日。每一章有一件可以动手玩的展品。展品由 HomePlay 用自己的代码重画，不是当年的截图，也没有用原厂的图标、字体或角色。每一章后面附出处。只有二手来源的地方，列在文末「还不确定的地方」。",
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
     "1981 年秋天，Macintosh 团队决定一次只跑一个应用程序，因为内存和屏幕都太小。Bud Tribble 提议另做一种小程序：在主程序旁边开一个小窗口，只做一件事。他叫它们「桌面摆饰」（desk ornaments）。1982 年秋天，文档组觉得「摆饰」听起来太花哨，改名「桌面附件」（desk accessories）。",
     "Andy Hertzfeld 和同事写出计算机、闹钟、记事本、剪贴板、Key Caps、控制面板，还有一个数字滑块拼图。计算机的外观是 Steve Jobs 亲手调的，他用的是 Chris Espinosa 做的「计算机组合工具」。拼图原本用 Pascal 写，超过 6 KB，一度不打算出货。Hertzfeld 花一个周末用汇编语言重写，缩到大约 600 字节，它才跟着第一台 Mac 出货。",
     "这些附件都收在苹果菜单里。要用时打开，用完关掉，手上的文档一直都在。Apple 后来在 Inside Macintosh 里解释：桌面附件是做得像设备驱动程序的小应用程序，目的是让 Mac 能有限地同时做几件事（多任务）。"
    ],
    "links": [
     "folkOrn",
     "folkCalc",
     "folkPuzzle",
     "infiniteMac",
     "imDevices"
    ],
    "lesson": "小组件从一开始就是为了让你不必离开手上的事。要用时拿得到，用完就收。"
   },
   {
    "id": "active",
    "year": "1997",
    "short": "Active Desktop",
    "era": "1997 · Internet Explorer 4",
    "title": "把网页铺在壁纸上。",
    "body": [
     "1997 年 10 月 1 日，Microsoft 在全球推出 Internet Explorer 4.0，也一起改了 Windows 桌面。新的「Active Desktop」让桌面直接显示网页内容，Microsoft 举的例子是股票报价和天气图。另一项「Active Channel」把网站做成频道，自动把新内容推送过来。桌面边有一条频道栏，首发时有 500 多个网站提供内容。",
     "这个想法让桌面变成一扇一直开着的信息窗。但当时大家用拨号上网。一直更新的壁纸会占用电话线和内存，也一直在你眼角动。后来的 Windows 把这块位置交给了别的设计。"
    ],
    "links": [
     "ie4"
    ],
    "lesson": "内容一直更新，不代表有用。每次更新都要付出网络、电力和注意力。"
   },
   {
    "id": "clippy",
    "year": "1997",
    "short": "Office 助手",
    "era": "1997 · Office 97",
    "title": "「看起来你在写信。」",
    "body": [
     "1996 年 11 月 19 日，Office 97 完成 RTM（交付生产），隔年初上市。新功能里有一位「Office 助手」（Office Assistant）。它待在窗口角落，提供建议、交互说明和小诀窍。最出名的造型是一支回形针，叫 Clippit，大家叫它 Clippy。",
     "它背后有认真的研究。Microsoft Research 的 Lumière 计划用贝叶斯网络推测用户想做什么、卡在哪里。贝叶斯网络是一种用概率来推理的数学模型。1998 年发表的论文写明，Office 97 助手有部分组件以 Lumière 的原型为基础。可是猜得到你要做什么，不代表该在那时开口。",
     "大家记得最清楚的是那句「看起来你在写信」。你没有问，它就在你打字时跳出来，挡住正在写的字。2001 年的 Office XP 把助手默认关闭。Microsoft 还为此办了一波网络宣传，产品经理说 Office XP 好用到不再需要 Clippy。2007 年版 Office 淘汰了助手。"
    ],
    "links": [
     "office97",
     "lumiere",
     "officexp",
     "office2007"
    ],
    "lesson": "猜对了也可能打扰人。助手要先等你开口，再等你说好。"
   },
   {
    "id": "agent",
    "year": "1997 → 2009",
    "short": "Microsoft Agent",
    "era": "1997 → 2009 · Microsoft Agent",
    "title": "谁都能请一位角色上台。",
    "body": [
     "Microsoft 也把会动的角色做成组件，让所有开发者使用。1997 年 9 月 8 日，Microsoft Agent 开放免费下载。1998 年 10 月 12 日的 2.0 版加入鹦鹉 Peedy。它和精灵 Genie、魔法师 Merlin、机器人 Robby 是最常见的四个角色。",
     "网页和程序用几行指令就能叫角色出场：走到某个位置、做个动作、开口说话。开发者还可以加上文字转语音和语音识别。所以角色到处都是，也常在不对的时候出现。",
     "Microsoft 后来在文档里写明：Windows 7 起淘汰 Microsoft Agent，之后的 Windows 可能不再提供。"
    ],
    "links": [
     "agent1",
     "agent2",
     "agentDoc"
    ],
    "lesson": "谁都能调用角色，等于每个网页都能决定它什么时候开口。这个时机应该由用户决定。"
   },
   {
    "id": "dashboard",
    "year": "2003 → 2005",
    "short": "Dashboard",
    "era": "2003 → 2005 · Konfabulator · Mac OS X Tiger",
    "title": "小组件有了名字，也有了自己的一层。",
    "body": [
     "2003 年，Arlo Rose 和 Perry Clarke 在 Mac OS X 上推出 Konfabulator。它让人做出浮在桌面上的小程序。2005 年 7 月，Yahoo! 买下它，把原本 20 美元的软件改成免费，后来改名 Yahoo! Widgets。",
     "2004 年 6 月 28 日，Apple 在 WWDC 预览 Mac OS X Tiger。Tiger 里的 Dashboard 把这类小程序叫做「widgets」。2005 年 4 月 29 日 Tiger 上市，内附 14 个小组件，用 HTML 和 JavaScript 这些网页技术写成。按一个键，小组件浮到最上层。再按一次，全部收起。",
     "Rose 当时说 Apple 抄了他的点子。John Gruber 写文章反驳，把源头追回 1984 年的桌面附件。两种说法都还在。没有争议的是：Dashboard 让小组件有了自己的一层，叫得出来，也收得回去。"
    ],
    "links": [
     "konfab",
     "konfabCopycat",
     "gruber",
     "tiger04",
     "tiger05"
    ],
    "lesson": "给小组件一个能收起来的地方，比让它一直开着好。看完就收，桌面还是你的。"
   },
   {
    "id": "sidebar",
    "year": "2007",
    "short": "侧边栏与 SideShow",
    "era": "2007 · Windows Vista",
    "title": "一条侧边栏，和电脑外面的一块小屏幕。",
    "body": [
     "2007 年 1 月 30 日，Windows Vista 上市。Microsoft 说小工具（gadgets）是把实时在线内容和数据送到桌面的小程序。小工具可以放进「侧边栏」，也就是桌面侧边的一个窗格。2009 年 10 月 22 日上市的 Windows 7 让小工具直接摆在桌面上。",
     "同一时期，Microsoft 还做了 Windows SideShow。小工具照样在电脑上跑，画面却送到另一块小屏幕，例如笔记本电脑外盖、键盘或遥控器。电脑睡着时，小屏幕还能显示上次同步的内容。MSDN 杂志介绍的原型屏幕是 220 × 176，开着大约耗电 4 毫瓦，整台电脑大约 75 瓦。",
     "SideShow 没有普及。2007 年 5 月，Computerworld 指出消费者买得到的 SideShow 笔记本电脑只有华硕一款。WeatherBug 的 SideShow 版下载不到一万次，桌面版超过六十万次。小屏幕上只是快照，要看新内容就得叫醒电脑。评测也抱怨：为了让信件和日历保持最新，电脑要常常从待机醒来。"
    ],
    "links": [
     "vista",
     "win7",
     "sideshowBlog",
     "sideshowMsdn",
     "sideshowCw"
    ],
    "lesson": "要能瞥一眼，屏幕得一直在身边，内容得一直是新的，更新时也不能叫醒整台电脑。SideShow 一次只做到其中一件。"
   },
   {
    "id": "removed",
    "year": "2012",
    "short": "收回",
    "era": "2012 · Security Advisory 2719662",
    "title": "小工具被收回，因为它能做的事太多了。",
    "body": [
     "2012 年 7 月 10 日，Microsoft 发布安全公告 2719662。公告说，Windows 侧边栏和小工具的漏洞可能让人从远程运行代码。正常的小工具可能有漏洞，攻击者也可能骗你装上恶意的小工具。两种情况都能用你的权限运行任何程序。Microsoft 给的办法是一个工具，把侧边栏和小工具整个关掉。",
     "到了 Windows 8，Microsoft 在兼容性文档里写：小工具已经淘汰，由动态磁贴和 App 取代。就连无害的小工具也可能被利用，所以 Microsoft 把小工具从系统里完全移除。"
    ],
    "links": [
     "advisory",
     "gadgetsGone"
    ],
    "lesson": "桌面上的小工具看起来很小，跑的却是完整的程序。只要能运行任何代码，它就可能被拿来攻击你。"
   },
   {
    "id": "pocket",
    "year": "2009 → 2023",
    "short": "口袋里的小组件",
    "era": "2009 → 2023 · Android · iOS · macOS",
    "title": "小组件进了手机，也学会不一直运行。",
    "body": [
     "手机把小组件带了回来。2009 年 4 月，Android 1.5 开放主屏幕小组件框架（AppWidget）。2013 年，iOS 7 在通知中心加入「今天」视图，一眼看完今天的事。隔年 iOS 8 让第三方 App 也能在这里放小组件。",
     "2020 年，iOS 14 让小组件放上主屏幕，还能叠成「智能叠放」。开发者用新的 WidgetKit 来做。这次的做法吸取了前人的教训：小组件不是一直在跑的程序。App 先交出一条时间轴，写好每个时间该显示的画面，系统到时间就换上下一格。Apple 的文档写，常被查看的小组件，一天通常有 40 到 70 次更新额度，大约每 15 到 60 分钟一次。",
     "2023 年，macOS Sonoma 让小组件回到 Mac 桌面。iPhone 的小组件也能通过连续互通出现在 Mac 上。从 Dashboard 的那一层，到直接摆在桌面上，中间换了一整套更省电、更安全的做法。"
    ],
    "links": [
     "android15",
     "ios7",
     "ios8",
     "ios14",
     "wwdc20",
     "widgetkitBudget",
     "sonoma"
    ],
    "lesson": "小组件不必一直运行。先决定什么时候该变，再让系统按时间换画面。这样省电，也更安全。"
   },
   {
    "id": "wrist",
    "year": "2015",
    "short": "复杂功能",
    "era": "2015 · Apple Watch",
    "title": "表盘上的一小格，叫做复杂功能。",
    "body": [
     "钟表业把表盘上报时以外的功能叫做 complication，例如日期、月相和计时。2015 年 4 月 24 日发售的 Apple Watch 沿用这个词，中文叫「复杂功能」。Apple 说它们是表盘上的专门功能。同年 9 月，watchOS 2 开放第三方 App 用 ClockKit 做自己的复杂功能。",
     "手表把「瞥一眼」缩到最短：抬手、看、放下，只有几秒。一小格只放得下此刻最需要的那一件事。2022 年，iOS 16 把小组件放上锁定屏幕。Apple 说灵感来自 Apple Watch 的复杂功能。"
    ],
    "links": [
     "watch15",
     "watchos2",
     "ios16"
    ],
    "lesson": "空间越小，越要选对内容。要问的是：这一刻该放什么。"
   },
   {
    "id": "live",
    "year": "2022 → 2023",
    "short": "实时活动",
    "era": "2022 → 2023 · 实时活动 · 待机显示",
    "title": "有开始、有结束的事，就让它一直看得到。",
    "body": [
     "2022 年 9 月 7 日，Apple 发布 iPhone 14 Pro 和屏幕顶端的「灵动岛」。之后的 iOS 16.1 让第三方 App 也能使用「实时活动」。外卖到哪里、比分多少、计时还剩几分，会留在锁定屏幕和灵动岛上。Apple 的设计准则只让它用在有明确开始和结束的事，建议不超过八小时。事情一结束，它就要马上结束。",
     "2023 年，iOS 17 加入「待机显示」。iPhone 横放充电时，会变成从远处也看得清楚的时钟、照片和小组件，也能全屏显示实时活动。Apple 说这是一种浏览一眼即知信息的新方式。这是 iPhone 第一次被当成一块放在桌上的屏幕。"
    ],
    "links": [
     "iphone14pro",
     "ios161",
     "higLive",
     "ios17"
    ],
    "lesson": "事情进行时才出现，结束就消失。这样的提醒最少打扰人。"
   },
   {
    "id": "homeview",
    "year": "2026",
    "short": "HomeView",
    "era": "2026 · Apple HomeView",
    "title": "一块放在家里、大家共用的屏幕。",
    "body": [
     "2026 年 10 月 13 日，Apple 发布 HomeView。它是一台家用显示器，有 7 英寸 Liquid Retina 屏幕，分桌面款和壁挂款。它有好几种可以切换的画面：Photos、Flow、Snoopy、Home Modular、Home Camera（Apple 台湾称为「桌面」）。每位登记过的家人有自己的主屏幕和小组件。正在播的歌、计时器、从别的房间传来的对讲，都用实时活动显示。",
     "前面每一章学到的事，在这里都看得到：桌面附件的随手可得，Dashboard 的叫得出也收得回，SideShow 想要的另一块屏幕，WidgetKit 的时间轴，手表上选对的一格，还有实时活动的有始有终。"
    ],
    "links": [
     "homeview",
     "homeviewTw",
     "higWidgets"
    ],
    "lesson": ""
   },
   {
    "id": "homeplay",
    "year": "2026",
    "short": "HomePlay",
    "era": "2026 · HomePlay",
    "title": "在 Mac 上，等你开口。",
    "body": [
     "HomePlay 是 Mac 上的开源桌宠，长得像 HomeView。它有表盘、小组件和实时活动，顶端的胶囊里有一双 👀。它大部分时间只是看着你，不出声。你靠近，它才亮起来。你专心工作时，它不吵你。",
     "它有一位助手，叫 ClioTalk。我们把从 Clippy 学到的事写成了规则。ClioTalk 不会自己跳出来；你按住 F5 或点它，它才开始听。它的回答是暂时的，你说要留下才会存。凡是用你的名义做的事，像发消息、打电话、加日程、解开门锁，它都先念给你听，等你说好。替你写消息时，它用你自己说的话，不改成它的口气。",
     "这些规则不保证它永远猜对。它们保证的是：它猜错时，不会替你做你没答应的事。四十年前苹果菜单里的计算机，要用时才出来，用完就收。我们希望 HomePlay 也是这样。"
    ],
    "links": [
     "homeplaySrc"
    ],
    "lesson": ""
   }
  ],
  "timelineTitle": "年表",
  "timelineLede": "照时间排一次。最右边一栏是后来的人从那一步学到的事。",
  "timelineHead": [
   "时间",
   "发生了什么",
   "留下的"
  ],
  "timeline": [
   [
    "1981 秋",
    "Bud Tribble 提出「桌面摆饰」，1982 年秋改名桌面附件",
    "小程序可以陪在主程序旁边"
   ],
   [
    "1984",
    "第一台 Mac 的苹果菜单里有计算机、闹钟、记事本、拼图等附件",
    "随手可得，用完就收"
   ],
   [
    "1996-11-19",
    "Office 97 完成 RTM（交付生产），附 Office 助手",
    "猜得到，不代表该开口"
   ],
   [
    "1997-09-08",
    "Microsoft Agent 开放免费下载",
    "角色成了谁都能调用的组件"
   ],
   [
    "1997-10-01",
    "Internet Explorer 4.0：Active Desktop 与 Active Channel",
    "一直更新有代价"
   ],
   [
    "1998-10-12",
    "Microsoft Agent 2.0，加入 Peedy",
    ""
   ],
   [
    "2001",
    "Office XP 默认关闭助手",
    "开始在意打扰"
   ],
   [
    "2003",
    "Konfabulator 在 Mac OS X 上推出",
    "小工具成了一种软件类别"
   ],
   [
    "2004-06-28",
    "Apple 预览 Tiger 与 Dashboard",
    ""
   ],
   [
    "2005-04-29",
    "Tiger 上市，Dashboard 内附 14 个小组件",
    "叫得出，也收得回"
   ],
   [
    "2005-07",
    "Yahoo! 收购 Konfabulator，改为免费",
    ""
   ],
   [
    "2007-01-30",
    "Windows Vista 上市：侧边栏、小工具、SideShow",
    "另一块屏幕第一次出货"
   ],
   [
    "2007",
    "2007 年版 Office 淘汰助手",
    ""
   ],
   [
    "2009-04",
    "Android 1.5 开放主屏幕小组件框架",
    "小组件进了口袋"
   ],
   [
    "2009-10-22",
    "Windows 7 上市；小工具可直接放在桌面；Agent 从这一版起淘汰",
    ""
   ],
   [
    "2012-07-10",
    "安全公告 2719662：建议关闭侧边栏与小工具",
    "能运行任何程序，就有风险"
   ],
   [
    "2012",
    "Windows 8 把小工具从系统移除",
    ""
   ],
   [
    "2013",
    "iOS 7 通知中心加入「今天」视图",
    "一眼看完今天"
   ],
   [
    "2014",
    "iOS 8 开放第三方小组件",
    ""
   ],
   [
    "2015-04-24",
    "Apple Watch 发售，表盘上有复杂功能",
    "空间越小越要选对"
   ],
   [
    "2015-09",
    "watchOS 2 开放第三方复杂功能（ClockKit）",
    ""
   ],
   [
    "2020",
    "iOS 14 主屏幕小组件与 WidgetKit；macOS Big Sur 通知中心小组件",
    "不一直运行，按时间轴换画面"
   ],
   [
    "2022",
    "iOS 16 锁定屏幕小组件；iPhone 14 Pro 灵动岛；iOS 16.1 实时活动",
    "有始有终的事才一直看得到"
   ],
   [
    "2023",
    "iOS 17 待机显示与可交互小组件；macOS Sonoma 桌面小组件",
    "小组件回到 Mac 桌面"
   ],
   [
    "2026-10-13",
    "Apple 发布 HomeView",
    "一块大家共用的屏幕"
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
   "第一台 Mac 出货时到底附了哪几个桌面附件：Folklore.org 的故事写了团队做了哪些，完整出货清单只有维基百科。我们没有把 Chooser 算进 1984 年。",
   "Internet Explorer 4.0 的日期：Microsoft 新闻稿是 1997 年 10 月 1 日全球上市，发布活动在前一天，也有来源写 9 月 22 日。",
   "Active Desktop 在 Windows Vista 被拿掉、由侧边栏取代：只找到维基百科（转引 PC Magazine 2006 年报道）与论坛说法，没有 Microsoft 原文。",
   "「看起来你在写信」在什么条件下出现（打了地址再打 Dear），以及设计师 Kevan Atteberry 画过多少草稿：只有维基百科与二手报道。",
   "2001 年那波「Clippy 失业了」宣传：引用的是同期的 internetnews.com 报道，Microsoft 自己的新闻稿页面打不开。",
   "Microsoft Agent 1.5 版是否存在、XP 搜索小狗 Rover 是否是 Agent 角色：没有找到可靠来源，正文不写。",
   "Konfabulator 的确切发布日（2003 年 2 月 10 日）与 Perry Clarke、Ed Voas 的角色：只有维基百科；Arlo Rose 的部分有同期报道。",
   "Windows 7 拿掉「侧边栏」这条栏、让小工具自由摆放的细节：只有维基百科与业界媒体。",
   "Windows 8.1 移除 SideShow 设备支持（2013）：只有维基百科，正文因此不写年份。",
   "Dashboard 在 OS X Yosemite 默认关闭、在 macOS Catalina 移除：只有二手报道，正文不写。",
   "iOS 16.1 的上市日（2022 年 10 月 24 日）：Apple 的支持页没有日期，日期来自新闻报道。",
   "HomeView 的「桌面」：Apple 台湾新闻稿把 faces 译作「桌面」，和 Apple Watch 的「表盘」不同；HomePlay 自己的画面照首页一律叫表盘。"
  ],
  "sourcesTitle": "出处",
  "sourcesLede": "文中的年份、数字和引述，都能在下面找到。我们优先列一手资料：当年的新闻稿、官方文档、亲历者的回忆。",
  "notice": "HomePlay 是独立的开源项目，与 Apple、Microsoft、Google、Yahoo 无关。文中的产品和角色名称属于各自的权利人，这里只引用名称。Macintosh、Apple Watch、HomeView、Dynamic Island 是 Apple Inc. 的商标；Windows、Office、Clippit 是 Microsoft 的商标。展品只是示意，不是原产品。查证于 2026 年 10 月 25 日。发现错误，请在 GitHub 告诉我们。",
  "sources": [
   [
    "folkOrn",
    "桌面附件的由来、改名，以及为什么一次只跑一个程序。"
   ],
   [
    "folkCalc",
    "计算机的外观怎么定下来。"
   ],
   [
    "folkPuzzle",
    "拼图从 Pascal 改写成汇编语言，留在第一版。"
   ],
   [
    "imDevices",
    "Apple 对桌面附件的定义与用途。"
   ],
   [
    "infiniteMac",
    "在浏览器里跑真正的 System 1.0。点了才会在新标签页载入；本站不嵌入，也不存放系统镜像。"
   ],
   [
    "ie4",
    "Active Desktop、Active Channel、频道栏与 500 多个网站。"
   ],
   [
    "office97",
    "Office 97 送厂日期与 Office 助手的说明。"
   ],
   [
    "lumiere",
    "Lumière 计划与 Office 97 助手的关系。"
   ],
   [
    "officexp",
    "Office XP 默认关闭助手，与那波宣传。"
   ],
   [
    "office2007",
    "2007 年版 Office 淘汰助手。"
   ],
   [
    "agent1",
    "Microsoft Agent 开放免费下载。"
   ],
   [
    "agent2",
    "Agent 2.0、Peedy、网页脚本与语音。"
   ],
   [
    "agentDoc",
    "Microsoft Agent 从 Windows 7 起淘汰。"
   ],
   [
    "konfab",
    "Yahoo! 收购 Konfabulator，改为免费。"
   ],
   [
    "konfabCopycat",
    "Arlo Rose 对 Dashboard 的回应。"
   ],
   [
    "gruber",
    "把 Dashboard 的源头追回桌面附件的另一种看法。"
   ],
   [
    "tiger04",
    "WWDC 2004 预览 Dashboard 与 widgets。"
   ],
   [
    "tiger05",
    "Tiger 上市日、14 个小组件与网页技术。"
   ],
   [
    "vista",
    "Vista 上市与小工具、侧边栏的官方说法。"
   ],
   [
    "win7",
    "Windows 7 上市日期。"
   ],
   [
    "sideshowBlog",
    "SideShow 团队自己的说明。"
   ],
   [
    "sideshowMsdn",
    "SideShow 的运作、原型屏幕与耗电数字。"
   ],
   [
    "sideshowCw",
    "SideShow 为什么没有普及。"
   ],
   [
    "advisory",
    "侧边栏与小工具的安全公告。"
   ],
   [
    "gadgetsGone",
    "Windows 8 移除小工具的理由。"
   ],
   [
    "android15",
    "Android 1.5 的主屏幕小组件框架。"
   ],
   [
    "ios7",
    "iOS 7 通知中心的「今天」视图。"
   ],
   [
    "ios8",
    "iOS 8 开放小组件等扩充功能。"
   ],
   [
    "ios14",
    "iOS 14 主屏幕小组件与智能叠放。"
   ],
   [
    "wwdc20",
    "WidgetKit 的介绍。"
   ],
   [
    "widgetkitBudget",
    "小组件的时间轴与每日更新额度。"
   ],
   [
    "sonoma",
    "macOS Sonoma 桌面小组件与连续互通。"
   ],
   [
    "watch15",
    "Apple Watch 发售日与复杂功能的定义。"
   ],
   [
    "watchos2",
    "watchOS 2 与 ClockKit。"
   ],
   [
    "ios16",
    "锁定屏幕小组件的灵感来自复杂功能。"
   ],
   [
    "iphone14pro",
    "iPhone 14 Pro 与灵动岛。"
   ],
   [
    "ios161",
    "iOS 16.1 让第三方 App 使用实时活动。"
   ],
   [
    "higLive",
    "实时活动的设计准则：有始有终、时间上限。"
   ],
   [
    "ios17",
    "待机显示。"
   ],
   [
    "higWidgets",
    "小组件的设计准则，以及 HomeView 的个人主屏幕。"
   ],
   [
    "homeview",
    "HomeView 发表、屏幕、画面与实时活动。"
   ],
   [
    "homeviewTw",
    "HomeView 在台湾的中文用词。"
   ],
   [
    "homeplaySrc",
    "HomePlay 与 ClioTalk 的源代码，规则写在程序里。"
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
  "description": "A tour from the Mac's 1984 desk accessories through Active Desktop, the Office Assistant, Microsoft Agent, Dashboard, the Vista Sidebar and SideShow, to today's widgets, complications and Live Activities. Every chapter lists its sources.",
  "ogAlt": "HomePlay desk pet: a white body with the time and a pair of eyes on screen",
  "keywords": "widgets, history, desk accessories, Active Desktop, Clippy, Office Assistant, Microsoft Agent, Konfabulator, Dashboard, Windows Sidebar, SideShow, complications, Live Activities, HomeView, HomePlay",
  "kicker": "HomePlay Notes 01 · Where a small screen came from",
  "h1": "How widgets came to be.",
  "lede": "A widget is a small program you can read at a glance, like a clock, the weather or a timer. This story starts with the Calculator in the 1984 Apple menu. It passes through Active Desktop, the paper clip, Dashboard and the Vista Sidebar. It ends with today's widgets, complications and Live Activities. For forty years, people have tried to do one thing: show you what you need at a glance, without interrupting you.",
  "meta": "Checked on 25 October 2026. Each chapter has an exhibit you can play with. HomePlay redrew every exhibit in its own code, so none is a screenshot or uses original icons, fonts or characters. Sources follow each chapter. Anything resting on one secondary source is listed under “What we are not sure of”.",
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
     "All of them lived in the Apple menu. You opened one, used it and closed it. Your document stayed put. Apple later explained in Inside Macintosh that desk accessories were small applications built like device drivers. They gave the Mac a limited kind of multitasking, meaning it could do a few things at once."
    ],
    "links": [
     "folkOrn",
     "folkCalc",
     "folkPuzzle",
     "infiniteMac",
     "imDevices"
    ],
    "lesson": "From the start, a widget let you stay in what you were doing. It was there when you needed it and gone when you were done."
   },
   {
    "id": "active",
    "year": "1997",
    "short": "Active Desktop",
    "era": "1997 · Internet Explorer 4",
    "title": "A web page laid over the wallpaper.",
    "body": [
     "On 1 October 1997 Microsoft released Internet Explorer 4.0 worldwide. The new Active Desktop could show live web content. Microsoft's own examples were stock tickers and weather maps. Active Channel turned websites into channels that pushed new content to you. A Channel Bar sat on the desktop, and more than 500 sites provided channels at launch.",
     "The idea turned the desktop into a window onto information that never closes. But most people were on dial-up then. Wallpaper that keeps updating takes a phone line and memory. It also keeps moving at the edge of your eye. Later versions of Windows gave that space to other designs."
    ],
    "links": [
     "ie4"
    ],
    "lesson": "Content that keeps changing is not always useful. Every update costs bandwidth, power and attention."
   },
   {
    "id": "clippy",
    "year": "1997",
    "short": "Office Assistant",
    "era": "1997 · Office 97",
    "title": "“It looks like you're writing a letter.”",
    "body": [
     "On 19 November 1996 Office 97 was released to manufacturing, and it reached stores early the next year. The new Office Assistant sat in a corner of the window and offered advice, interactive Help and tips. Its best-known form was a paper clip named Clippit, which everyone called Clippy.",
     "Real research stood behind it. Microsoft Research's Lumière project used Bayesian models to infer what a user was trying to do and where they were stuck. A Bayesian model is a math model that reasons with probabilities. The project's 1998 paper states that Lumière prototypes were the basis for components of the Office 97 Assistant. But guessing what you want to do does not tell it when to speak.",
     "People remember the line “It looks like you're writing a letter.” You had not asked. It appeared while you typed, in front of the words you were writing. Office XP in 2001 turned the Assistant off by default. Microsoft ran a web campaign about it. A product manager said Office XP was so easy to use that Clippy was no longer necessary. The 2007 Office system marked the Assistant as obsolete."
    ],
    "links": [
     "office97",
     "lumiere",
     "officexp",
     "office2007"
    ],
    "lesson": "A correct guess can still be an interruption. An assistant first needs to wait for you to ask, then wait for you to say yes."
   },
   {
    "id": "agent",
    "year": "1997 → 2009",
    "short": "Microsoft Agent",
    "era": "1997 → 2009 · Microsoft Agent",
    "title": "Any developer could add an animated character.",
    "body": [
     "Microsoft also made animated characters a component any developer could use. Microsoft Agent became a free download on 8 September 1997. Version 2.0, on 12 October 1998, added Peedy the parrot. He joined Genie, Merlin the wizard and Robby the robot as the four characters people saw most.",
     "A web page or an app could call a character with a few lines of script: move here, play an animation, say something. Developers could add text-to-speech and speech recognition. So characters turned up everywhere, often at the wrong moment.",
     "Microsoft's documentation later said: Microsoft Agent is obsolete as of Windows 7 and may be unavailable in later versions."
    ],
    "links": [
     "agent1",
     "agent2",
     "agentDoc"
    ],
    "lesson": "If any page can call a character, any page decides when it speaks. That choice should belong to the person using the computer."
   },
   {
    "id": "dashboard",
    "year": "2003 → 2005",
    "short": "Dashboard",
    "era": "2003 → 2005 · Konfabulator · Mac OS X Tiger",
    "title": "Widgets got a name, and a layer of their own.",
    "body": [
     "In 2003 Arlo Rose and Perry Clarke released Konfabulator for Mac OS X. It let people make small programs that floated on the desktop. Yahoo! bought it in July 2005, made the $20 program free, and later renamed it Yahoo! Widgets.",
     "On 28 June 2004, at WWDC, Apple previewed Mac OS X Tiger. Its Dashboard introduced “a new class of accessory applications called Widgets”. Tiger went on sale on 29 April 2005 with 14 widgets built on web technologies such as HTML and JavaScript. One keystroke brought them to the top. Another sent them all away.",
     "Rose said at the time that Apple had copied his idea. John Gruber disagreed on Daring Fireball and traced the idea back to the 1984 desk accessories. Both views are still around. No one disputes this: Dashboard gave widgets a layer of their own, easy to summon and easy to dismiss."
    ],
    "links": [
     "konfab",
     "konfabCopycat",
     "gruber",
     "tiger04",
     "tiger05"
    ],
    "lesson": "A widget is better off with a place to go away to than with a permanent spot on the screen. Look, then dismiss it. The desktop is still yours."
   },
   {
    "id": "sidebar",
    "year": "2007",
    "short": "Sidebar and SideShow",
    "era": "2007 · Windows Vista",
    "title": "A sidebar, and a small screen outside the computer.",
    "body": [
     "Windows Vista reached consumers on 30 January 2007. Microsoft described gadgets as small apps that deliver live online content and data to the desktop. They could sit in the Windows Sidebar, a pane at the side of the Vista desktop. Windows 7, on sale from 22 October 2009, let gadgets sit directly on the desktop.",
     "In the same years Microsoft built Windows SideShow. Gadgets still ran on the PC. Their content went to a second small screen, such as a laptop lid, a keyboard or a remote. With the PC asleep, the small screen could still show what was last synced. The prototype described in MSDN Magazine had a 220 × 176 display that drew about 4 milliwatts. The whole PC drew roughly 75 watts.",
     "SideShow did not catch on. In May 2007 Computerworld noted that consumers could buy only one SideShow laptop, from ASUS. WeatherBug's SideShow version had fewer than 10,000 downloads, against more than 600,000 for the desktop one. The small screen showed a snapshot, and fresh content meant waking the PC. A review complained that mail and calendar stayed current only if the laptop kept waking from standby."
    ],
    "links": [
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
     "On 10 July 2012 Microsoft published Security Advisory 2719662. It said vulnerabilities in Windows Sidebar and gadgets could allow remote code execution, meaning someone else could run a program on your PC. A legitimate gadget might have a flaw, or an attacker might trick you into installing a malicious one. Either way, the code ran with your rights. Microsoft's fix was a tool, called a Fix it, that turned off Sidebar and gadgets entirely.",
     "For Windows 8, Microsoft's compatibility notes said gadgets were already obsolete and replaced by live tiles and apps. They said even harmless gadgets could be exploited, so Microsoft chose to remove gadgets from the operating system entirely."
    ],
    "links": [
     "advisory",
     "gadgetsGone"
    ],
    "lesson": "A gadget looks small, but it runs a full program. Any program that can run any code can be used to attack you, however small its window."
   },
   {
    "id": "pocket",
    "year": "2009 → 2023",
    "short": "Widgets in your pocket",
    "era": "2009 → 2023 · Android · iOS · macOS",
    "title": "Widgets moved onto phones, and learned not to run all the time.",
    "body": [
     "Phones brought widgets back. In April 2009 Android 1.5 opened the AppWidget framework for home-screen widgets. In 2013 iOS 7 added Today to Notification Center, a view of your day at a glance. The next year iOS 8 let third-party apps put widgets there.",
     "In 2020 iOS 14 put widgets on the Home Screen, where they can stack into a Smart Stack. Developers build them with WidgetKit. Its design learns from the past: a widget is not a program that keeps running. The app hands over a timeline in advance, which is a list of what to show at each time. The system swaps in the next view when its time comes. Apple's documentation says a frequently viewed widget typically gets 40 to 70 refreshes a day, roughly one every 15 to 60 minutes.",
     "In 2023 macOS Sonoma put widgets back on the Mac desktop. Through Continuity, iPhone widgets could appear on the Mac too. Between Dashboard's separate layer and widgets right on the desktop, the way they save power and stay secure changed completely."
    ],
    "links": [
     "android15",
     "ios7",
     "ios8",
     "ios14",
     "wwdc20",
     "widgetkitBudget",
     "sonoma"
    ],
    "lesson": "A widget does not need to run all the time. Decide in advance when it should change, and let the system swap the view on time. That saves battery and is safer."
   },
   {
    "id": "wrist",
    "year": "2015",
    "short": "Complications",
    "era": "2015 · Apple Watch",
    "title": "A small slot on the watch face, called a complication.",
    "body": [
     "Watchmakers call any extra function on a dial, beyond telling the time, a complication. Examples are the date, the moon phase and a chronograph. Apple Watch, on sale from 24 April 2015, kept the word. Apple described complications as specialized functions on the watch face. That September, watchOS 2 let third-party apps use ClockKit to turn their own data into complications.",
     "A watch makes the glance as short as it can be: raise your wrist, look, lower it, a few seconds at most. One slot holds only the one thing you most need to know right now. In 2022 iOS 16 put widgets on the Lock Screen. Apple said they took inspiration from Apple Watch complications."
    ],
    "links": [
     "watch15",
     "watchos2",
     "ios16"
    ],
    "lesson": "The smaller the space, the more the choice matters. Ask what belongs there right now."
   },
   {
    "id": "live",
    "year": "2022 → 2023",
    "short": "Live Activities",
    "era": "2022 → 2023 · Live Activities · StandBy",
    "title": "If something has a start and an end, keep it in view.",
    "body": [
     "On 7 September 2022 Apple introduced iPhone 14 Pro and the Dynamic Island at the top of its screen. iOS 16.1 then opened Live Activities to third-party apps. Your delivery's location, the score and the minutes left on a timer stay on the Lock Screen and in the Dynamic Island. Apple's design guidelines reserve Live Activities for tasks and events with a defined beginning and end. They recommend a limit of eight hours. They say to end a Live Activity as soon as the event ends.",
     "In 2023 iOS 17 added StandBy. An iPhone set on its side while charging becomes a clock, photos and widgets you can read from across the room. It can also show Live Activities full screen. Apple called it a new way to view glanceable information. It was the first time the iPhone itself was treated as a screen that sits on a table."
    ],
    "links": [
     "iphone14pro",
     "ios161",
     "higLive",
     "ios17"
    ],
    "lesson": "A reminder that appears only while something is happening, and leaves when it ends, interrupts you the least."
   },
   {
    "id": "homeview",
    "year": "2026",
    "short": "HomeView",
    "era": "2026 · Apple HomeView",
    "title": "One screen at home, shared by everyone.",
    "body": [
     "On 13 October 2026 Apple announced HomeView. It is a home display with a 7-inch Liquid Retina screen, in tabletop and wall-mounted versions. It has faces you can switch between, among them Photos, Flow, Snoopy, Home Modular and Home Camera. Each enrolled member of the household gets their own Home Screen with their own apps and widgets. The song that is playing, a running timer and an Intercom message from another room appear as Live Activities.",
     "Every earlier lesson shows up here. The desk accessory was at hand. Dashboard could be summoned and dismissed. SideShow wanted a second screen. WidgetKit has the timeline, the watch has its one right slot, and a Live Activity has a clear start and end."
    ],
    "links": [
     "homeview",
     "higWidgets"
    ],
    "lesson": ""
   },
   {
    "id": "homeplay",
    "year": "2026",
    "short": "HomePlay",
    "era": "2026 · HomePlay",
    "title": "On the Mac, waiting until you ask.",
    "body": [
     "HomePlay is an open-source desk pet for the Mac that looks like HomeView. It has faces, widgets and Live Activities, and a pair of 👀 in the capsule at the top. Most of the time it just watches, quietly. It lights up when you come near. It stays out of your way while you work.",
     "It also has an assistant, ClioTalk. We wrote what we learned from Clippy into its rules. ClioTalk never pops up on its own. It starts listening only when you hold F5 or click it. Its answers are temporary until you choose to keep them. It reads back anything done in your name first and waits for your OK. That covers sending a message, placing a call, adding an event and unlocking a door. When it drafts a message for you, it uses your own words and does not polish them into its voice.",
     "These rules do not promise that it always guesses right. They promise that when it guesses wrong, it will not do something you did not agree to. Forty years ago the Calculator in the Apple menu came out when you needed it and went away when you were done. We want HomePlay to work the same way."
    ],
    "links": [
     "homeplaySrc"
    ],
    "lesson": ""
   }
  ],
  "timelineTitle": "Timeline",
  "timelineLede": "The same story in order. The last column is what people learned from each step.",
  "timelineHead": [
   "When",
   "What happened",
   "What it left behind"
  ],
  "timeline": [
   [
    "Fall 1981",
    "Bud Tribble proposes desk ornaments, renamed desk accessories in fall 1982",
    "Small programs can keep the main one company"
   ],
   [
    "1984",
    "The first Mac's Apple menu holds Calculator, Alarm Clock, Note Pad, Puzzle and more",
    "At hand, and gone when you are done"
   ],
   [
    "1996-11-19",
    "Office 97 released to manufacturing, with the Office Assistant",
    "Guessing right is not a reason to speak up"
   ],
   [
    "1997-09-08",
    "Microsoft Agent becomes a free download",
    "Characters become a component anyone can call"
   ],
   [
    "1997-10-01",
    "Internet Explorer 4.0: Active Desktop and Active Channel",
    "Constant updates have a cost"
   ],
   [
    "1998-10-12",
    "Microsoft Agent 2.0 adds Peedy",
    ""
   ],
   [
    "2001",
    "Office XP turns the Assistant off by default",
    "People start to care about interruptions"
   ],
   [
    "2003",
    "Konfabulator released for Mac OS X",
    "Widgets become a kind of software"
   ],
   [
    "2004-06-28",
    "Apple previews Tiger and Dashboard",
    ""
   ],
   [
    "2005-04-29",
    "Tiger ships; Dashboard includes 14 widgets",
    "Easy to summon, easy to dismiss"
   ],
   [
    "2005-07",
    "Yahoo! acquires Konfabulator and makes it free",
    ""
   ],
   [
    "2007-01-30",
    "Windows Vista: Sidebar, gadgets, SideShow",
    "A second screen ships for the first time"
   ],
   [
    "2007",
    "The 2007 Office system marks the Assistant obsolete",
    ""
   ],
   [
    "2009-04",
    "Android 1.5 opens the home-screen widget framework",
    "Widgets move into the pocket"
   ],
   [
    "2009-10-22",
    "Windows 7: gadgets sit on the desktop; Agent obsolete from this version",
    ""
   ],
   [
    "2012-07-10",
    "Security Advisory 2719662 advises turning off Sidebar and gadgets",
    "Running any code carries risk"
   ],
   [
    "2012",
    "Windows 8 removes gadgets from the system",
    ""
   ],
   [
    "2013",
    "iOS 7 adds Today to Notification Center",
    "Your day at a glance"
   ],
   [
    "2014",
    "iOS 8 opens widgets to third-party apps",
    ""
   ],
   [
    "2015-04-24",
    "Apple Watch goes on sale with complications on its faces",
    "The smaller the space, the more the choice matters"
   ],
   [
    "2015-09",
    "watchOS 2 opens complications to third parties (ClockKit)",
    ""
   ],
   [
    "2020",
    "iOS 14 Home Screen widgets and WidgetKit; macOS Big Sur widgets in Notification Center",
    "Not always running: a timeline swaps the view"
   ],
   [
    "2022",
    "iOS 16 Lock Screen widgets; iPhone 14 Pro Dynamic Island; Live Activities in iOS 16.1",
    "Things with a start and an end stay in view"
   ],
   [
    "2023",
    "iOS 17 StandBy and interactive widgets; macOS Sonoma desktop widgets",
    "Widgets return to the Mac desktop"
   ],
   [
    "2026-10-13",
    "Apple announces HomeView",
    "One screen shared by a household"
   ],
   [
    "2026",
    "HomePlay: on the Mac, ClioTalk waits until you ask",
    "An assistant waits first, then acts"
   ]
  ],
  "unsureTitle": "What we are not sure of",
  "unsureLede": "For these we found only secondary sources, or sources that disagree. The text above avoids them or says who claims them.",
  "unsure": [
   "Exactly which desk accessories shipped on the first Mac: Folklore.org tells which ones the team built, but the full list comes only from Wikipedia. We do not count the Chooser for 1984.",
   "Internet Explorer 4.0's date: Microsoft's press release gives worldwide availability on 1 October 1997, after a launch event the day before. Another source says 22 September.",
   "Active Desktop being dropped in Windows Vista and replaced by the Sidebar: only Wikipedia (citing PC Magazine, 2006) and forum posts. No Microsoft source.",
   "What triggered “It looks like you're writing a letter” (an address followed by “Dear”) and how many sketches designer Kevan Atteberry made: only Wikipedia and secondary press.",
   "The 2001 “Clippy is out of a job” campaign: cited from a contemporaneous internetnews.com report. Microsoft's own press release page would not open.",
   "Whether a Microsoft Agent 1.5 existed, and whether the Windows XP search dog Rover was an Agent character: no reliable source, so not in the text.",
   "Konfabulator's exact release date (10 February 2003) and the roles of Perry Clarke and Ed Voas: only Wikipedia. Arlo Rose's part has coverage from the time.",
   "The details of Windows 7 dropping the Sidebar bar and letting gadgets sit anywhere: only Wikipedia and trade press.",
   "Windows 8.1 removing SideShow device support (2013): only Wikipedia, so the text gives no year.",
   "Dashboard being off by default in OS X Yosemite and removed in macOS Catalina: only secondary reports, so not in the text.",
   "The release date of iOS 16.1 (24 October 2022): Apple's support page has no date; the date comes from news coverage.",
   "HomeView's faces: Apple's Taiwan newsroom translates them as 「桌面」, unlike Apple Watch's 「錶面」. In English, Apple calls both faces."
  ],
  "sourcesTitle": "Sources",
  "sourcesLede": "Every year, number and quotation above can be found below. We list primary material first: press releases of the day, official documentation, and the recollections of people who were there.",
  "notice": "HomePlay is an independent open-source project, not affiliated with Apple, Microsoft, Google or Yahoo. Product and character names belong to their owners and are used for reference only. Macintosh, Apple Watch, HomeView and Dynamic Island are trademarks of Apple Inc.; Windows, Office and Clippit are trademarks of Microsoft. The exhibits are illustrations, not the original products. Checked on 25 October 2026. If you spot a mistake, please tell us on GitHub.",
  "sources": [
   [
    "folkOrn",
    "Where desk accessories came from, the rename, and why one program at a time."
   ],
   [
    "folkCalc",
    "How the Calculator's look was decided."
   ],
   [
    "folkPuzzle",
    "The Puzzle rewritten from Pascal to assembly to make the first release."
   ],
   [
    "imDevices",
    "Apple's definition of desk accessories and what they were for."
   ],
   [
    "infiniteMac",
    "Run the real System 1.0 in your browser with Infinite Mac. It loads in a new tab only when you click. This site neither embeds nor hosts the system image."
   ],
   [
    "ie4",
    "Active Desktop, Active Channel, the Channel Bar and the 500-plus sites."
   ],
   [
    "office97",
    "Office 97's release to manufacturing and the Office Assistant."
   ],
   [
    "lumiere",
    "The Lumière project and its link to the Office 97 Assistant."
   ],
   [
    "officexp",
    "Office XP turning the Assistant off by default, and the campaign."
   ],
   [
    "office2007",
    "The Assistant marked obsolete in the 2007 Office system."
   ],
   [
    "agent1",
    "Microsoft Agent released as a free download."
   ],
   [
    "agent2",
    "Agent 2.0, Peedy, web scripting and speech."
   ],
   [
    "agentDoc",
    "Microsoft Agent obsolete as of Windows 7."
   ],
   [
    "konfab",
    "Yahoo! acquiring Konfabulator and making it free."
   ],
   [
    "konfabCopycat",
    "Arlo Rose's response to Dashboard."
   ],
   [
    "gruber",
    "The other view, tracing Dashboard back to desk accessories."
   ],
   [
    "tiger04",
    "WWDC 2004 preview of Dashboard and widgets."
   ],
   [
    "tiger05",
    "Tiger's ship date, 14 widgets and web technologies."
   ],
   [
    "vista",
    "Vista's launch and Microsoft's description of gadgets and the Sidebar."
   ],
   [
    "win7",
    "Windows 7's general availability date."
   ],
   [
    "sideshowBlog",
    "The SideShow team's own explanation."
   ],
   [
    "sideshowMsdn",
    "How SideShow worked, the prototype screen and its power draw."
   ],
   [
    "sideshowCw",
    "Why SideShow did not catch on."
   ],
   [
    "advisory",
    "The security advisory on Sidebar and gadgets."
   ],
   [
    "gadgetsGone",
    "Why Windows 8 removed gadgets."
   ],
   [
    "android15",
    "Android 1.5's home-screen widget framework."
   ],
   [
    "ios7",
    "Today in iOS 7's Notification Center."
   ],
   [
    "ios8",
    "iOS 8 opening widgets and other extensions."
   ],
   [
    "ios14",
    "iOS 14 Home Screen widgets and the Smart Stack."
   ],
   [
    "wwdc20",
    "WidgetKit introduced."
   ],
   [
    "widgetkitBudget",
    "Widget timelines and the daily refresh budget."
   ],
   [
    "sonoma",
    "macOS Sonoma desktop widgets and Continuity."
   ],
   [
    "watch15",
    "Apple Watch's on-sale date and the definition of complications."
   ],
   [
    "watchos2",
    "watchOS 2 and ClockKit."
   ],
   [
    "ios16",
    "Lock Screen widgets inspired by complications."
   ],
   [
    "iphone14pro",
    "iPhone 14 Pro and the Dynamic Island."
   ],
   [
    "ios161",
    "iOS 16.1 opening Live Activities to third-party apps."
   ],
   [
    "higLive",
    "Live Activities guidelines: a defined beginning and end, a time limit."
   ],
   [
    "ios17",
    "StandBy."
   ],
   [
    "higWidgets",
    "Widget guidelines, and HomeView's personal Home Screens."
   ],
   [
    "homeview",
    "HomeView's announcement, display, faces and Live Activities."
   ],
   [
    "homeplaySrc",
    "HomePlay and ClioTalk source code, where the rules live."
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

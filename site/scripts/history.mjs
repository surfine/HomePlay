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
  msrSideshow01: ['Microsoft Research · MSR-TR-2001-83 · 2001-09', 'Sideshow: Providing Peripheral Awareness of Important Information', 'https://www.microsoft.com/en-us/research/publication/sideshow-providing-peripheral-awareness-of-important-information/'],
  msrSideshow02: ['Microsoft Research · CSCW 2002', 'Designing and Deploying an Information Awareness Interface', 'https://www.microsoft.com/en-us/research/publication/designing-and-deploying-an-information-awareness-interface/'],
  desktopxHistory: ['Stardock', 'DesktopX History', 'https://www.stardock.com/products/desktopx/dx-history.asp'],
  rainmeterHistory: ['Rainmeter forum', "Rainmeter's History (1999-2006)", 'https://forum.rainmeter.net/viewtopic.php?t=45370'],
  rainmeterHome: ['Rainmeter', 'Rainmeter', 'https://www.rainmeter.net/'],
  gdEol: ['Google Desktop team blog · 2011-09-02', 'Google Desktop Update · Internet Archive 存檔', 'https://web.archive.org/web/20120103090239/http://googledesktop.blogspot.com/'],
  gd2005: ['Google', 'Google Desktop Download · 2005 年產品頁 · Internet Archive 存檔', 'https://web.archive.org/web/20051001003453/http://desktop.google.com/'],
  yahooWidgetsEol: ['Yahoo!', 'Desktop Widgets Gallery Website Discontinued · Internet Archive 存檔', 'https://web.archive.org/web/20120414221532/http://widgets.yahoo.com/'],
  konfabSite: ['Pixoria · 2003-07-17', 'Konfabulator 官方網站 · Internet Archive 存檔', 'https://web.archive.org/web/20030717162907/http://konfabulator.com/'],
  desktopx35: ['Stardock forums · 2008-07-17', 'DesktopX 3.5 Officially Released', 'https://forums.stardock.com/1071/desktopx-3-5-officially-released'],
  build2011: ['Microsoft press release', 'Microsoft Reimagines Windows, Presents Windows 8 Developer Preview · 2011-09-13', 'https://news.microsoft.com/source/2011/09/13/microsoft-reimagines-windows-presents-windows-8-developer-preview/'],
  sidebarDocs: ['Microsoft developer archive', 'Windows Sidebar', 'https://learn.microsoft.com/en-us/previous-versions/windows/desktop/sidebar/-sidebar-entry'],
  msSidebarHistory: ['MicrosoftGadgets · 2005-09-15', 'A Brief History of Windows Sidebar · Internet Archive 存檔', 'https://web.archive.org/web/20070621071923/http://microsoftgadgets.com/blogs/gadgetnews/archive/2005/09/15/181.aspx'],
  thurrott3683: ["Paul Thurrott's SuperSite for Windows · 2002-11", 'Longhorn Alpha Preview · Internet Archive 存檔', 'https://web.archive.org/web/20050102014858/http://www.winsupersite.com/reviews/longhorn_alpha.asp'],
};

// 出處的「種類」在中文頁翻成中文；沒列在這裡的（期刊名、網站名）照原文。
const KIND = {
  'zh-Hant': [['Apple press release', 'Apple 新聞稿'], ['Microsoft Research', '微軟研究院'], ['Wikipedia', '維基百科'], ['Microsoft press release', 'Microsoft 新聞稿'], ['Apple Newsroom', 'Apple 新聞稿'], ['Apple Developer documentation', 'Apple 開發者文件'], ['Apple developer archive', 'Apple 開發者文件封存'], ['Microsoft developer archive', 'Microsoft 開發者文件封存'], ['Apple Human Interface Guidelines', 'Apple 人機介面準則'], ['Apple Support', 'Apple 支援'], ['HomePlay source', 'HomePlay 原始碼'], ['Microsoft SideShow team blog', 'Microsoft SideShow 團隊部落格']],
  'zh-Hans': [['Apple press release', 'Apple 新闻稿'], ['Microsoft Research', '微软研究院'], ['Wikipedia', '维基百科'], ['Microsoft press release', 'Microsoft 新闻稿'], ['Apple Newsroom', 'Apple 新闻稿'], ['Apple Developer documentation', 'Apple 开发者文档'], ['Apple developer archive', 'Apple 开发者文档存档'], ['Microsoft developer archive', 'Microsoft 开发者文档存档'], ['Apple Human Interface Guidelines', 'Apple 人机界面指南'], ['Apple Support', 'Apple 支持'], ['HomePlay source', 'HomePlay 源代码'], ['Microsoft SideShow team blog', 'Microsoft SideShow 团队博客']],
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
     "1981 年秋天，Macintosh 團隊決定一次只跑一個程式。記憶體和螢幕都太小。Bud Tribble 出了個主意：另做一種小程式，開在主程式旁邊的小視窗裡，只做一件事。這種小程式叫「桌面擺飾」。1982 年秋天，文件組嫌「擺飾」太花俏，改名「桌面附件」。",
     "Andy Hertzfeld 和同事做出了這批附件：計算機、鬧鐘、記事本、剪貼簿、Key Caps、控制面板，還有一個數字拼圖。計算機長什麼樣，是 Steve Jobs 親手調的。他用的是 Chris Espinosa 做的「計算機組合工具」。拼圖一開始用 Pascal 寫，超過 6 KB，團隊一度不打算出貨。Hertzfeld 花一個週末用組合語言重寫，縮到約 600 位元組。就這樣，拼圖跟著第一台 Mac 出貨了。",
     "這些附件都收在蘋果選單裡。要用時打開，用完關掉，手上的文件一直都在。Apple 在《Inside Macintosh》裡解釋過它們的做法：桌面附件是做得像驅動程式的小程式。靠這個辦法，Mac 在一次只跑一個程式的限制下，還能同時做幾件事。"
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
     "1997 年 10 月 1 日，Internet Explorer 4.0 把網頁放上了 Windows 桌面。「Active Desktop」讓桌面直接顯示網頁內容。「Active Channel」把 500 多個網站做成自動推送的頻道。想法是讓桌面變成一扇一直開著的資訊窗。可當時上網靠撥接。一直更新的桌布佔著電話線和記憶體，還在你眼角一直動。後來的 Windows 把這塊地方給了別的設計。",
     "1996 年 11 月 19 日，Office 97 完成開發交給工廠，隔年初上市。裡面有一位「Office 小幫手」，待在視窗角落提供建議和說明，最出名的造型是迴紋針 Clippy。它背後是認真的研究。Microsoft Research 的 Lumière 計畫，用貝氏網路推測你在做什麼、卡在哪裡。貝氏網路是一種用機率做推測的數學模型。1998 年的論文寫明，小幫手的部分元件以此為基礎。",
     "可是，猜得到你要做什麼，不代表該在那時開口。大家記得最清楚的，就是那句「看起來你在寫信」。你沒有問，它就在你打字時跳出來，擋住正在寫的字。Office XP（2001）把它預設關閉。Microsoft 還為此辦了一波網路宣傳，產品經理說 Office XP 好用到不再需要 Clippy。2007 年版把它淘汰。",
     "Microsoft 還把會動的角色做成了現成的開發元件。1997 年 9 月 8 日，Microsoft Agent 免費開放下載。1998 年 10 月 12 日的 2.0 版加入鸚鵡 Peedy，和精靈 Genie、魔法師 Merlin、機器人 Robby 一起，成為最常見的四個角色。任何程式只要幾行指令，就能叫角色走位、做動作、開口說話，還能接上文字轉語音和語音辨識。於是這些角色到處都是，也常常出現在不對的時候。Windows 7 起，Microsoft 把它淘汰了。"
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
    "year": "1999 → 2011",
    "short": "遍地開花",
    "era": "1999 → 2011 · 桌面小工具遍地開花",
    "title": "小工具有了名字，也有了自己的一層。",
    "body": [
     "這件事不是哪一家公司的專利。微軟內部在 2000 年就有了這條側邊欄，許多員工的桌面上都看得到它。2001 年 9 月，研究員把它的道理寫成論文：資訊可以待在螢幕邊緣，用眼角餘光看，不必打斷手上的事。他們把這叫「周邊察覺」，介面叫 Sideshow，數百名員工試用了七個月。微軟後來自己說：Windows 側邊欄的根，就是這條研究線。",
     "民間更早就動手了。1999 年的 DesktopX、2001 年的 Rainmeter，都讓人自己往桌上放時鐘、天氣和系統狀態。到 2005 年前後，Apple、Google 和微軟都交出了自己的版本。",
     "2003 年，Arlo Rose 和 Perry Clarke 在 Mac OS X 上推出 Konfabulator，讓人做自己浮在桌面上的小程式。2005 年 7 月，Yahoo! 買下它，把 20 美元的軟體改成免費，後來改名 Yahoo! Widgets。2004 年 6 月 28 日，Apple 在 WWDC 上預覽了 Tiger，裡面的 Dashboard 也做這類小程式，還給它們起了統一的名字：widgets。Tiger 在 2005 年 4 月 29 日上市，Dashboard 內附 14 個，用 HTML 和 JavaScript 這樣的網頁技術寫成。按一個鍵，全部浮上來。再按一次，收回去。",
     "Rose 說 Apple 抄了他的點子。John Gruber 寫文章反駁，把這類東西的源頭追回到 1984 年的桌面附件。兩種說法到今天都還在。沒有爭議的是結果：Dashboard 讓小工具有了一層自己的空間，叫得出來，也收得回去。",
     "Windows 這邊，故事從側邊欄開始。最早的公開記錄在 2002 年 11 月：記者 Paul Thurrott 試用了 Longhorn 的早期開發版，把側邊欄稱為「Longhorn 討論度最高的功能」。上面放著一格格叫 Tiles 的元件：時鐘、搜尋列、照片輪播，連快速啟動列都搬了進去。微軟自己在 2003 年的 PDC 開發者大會上公開了側邊欄；2004 年 Longhorn 重置後，一小組人把它繼續養大。到了 Vista，側邊欄正式上市：微軟的文件說，它是桌面上一條像工作列的長板，專門放小工具（gadgets）。Vista 在 2007 年 1 月 30 日上市，Windows 7 從 2009 年 10 月 22 日起，讓小工具直接放在桌面上。",
     "Microsoft 同期還做了 SideShow：小工具在電腦上跑，畫面送到另一塊小螢幕上，比如筆電的外蓋。原型螢幕是 220 × 176，開著只耗約 4 毫瓦，而整台電腦約 75 瓦。電腦睡著時，它還能顯示上次同步的內容。",
     "但 SideShow 沒有普及。2007 年 5 月，Computerworld 報導，買得到的 SideShow 筆電只有華碩一款。WeatherBug 的 SideShow 版下載不到一萬次，桌面版超過六十萬次。小螢幕上看到的只是快照。想看新的內容，就得喚醒電腦。評測也抱怨，它為了更新，常把整台電腦從待機裡吵醒。",
     "這股熱鬧在十年末散場：DesktopX 的最後一版停在 2008 年，Google 在 2011 年收掉 Google Desktop，Yahoo! 在 2012 年關上小工具藝廊。",
    ],
    "links": [
     "msrSideshow01",
     "msrSideshow02",
     "desktopxHistory",
     "rainmeterHistory",
     "rainmeterHome",
     "gd2005",
     "gdEol",
     "yahooWidgetsEol",
     "konfabSite",
     "desktopx35",
     "sidebarDocs",
     "msSidebarHistory",
     "thurrott3683",
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
     "2012 年 7 月 10 日，Microsoft 發布安全公告 2719662：側邊欄和小工具有漏洞，攻擊者可以從遠端在你電腦上執行程式。漏洞有兩種來路。正常的小工具自己可能有漏洞。攻擊者也能騙你裝上惡意的小工具。無論哪種，程式碼都用你的權限跑，能做任何事。",
     "Microsoft 的應對是一個官方工具，把側邊欄和小工具整個關掉。早在 2011 年 9 月的 BUILD 開發者大會，Microsoft 就公開展示了觸控優先的 Windows 8，並發布開發者預覽。到了 Windows 8，小工具被整個移出系統，換成動態磚和 App。因為就連無害的小工具，也可能被人利用。"
    ],
    "links": [
     "advisory",
     "build2011",
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
     "手機把小工具帶了回來。2009 年 4 月，Android 1.5 開放主畫面小工具。2013 年，iOS 7 在通知中心加了「今天」，一眼看完今天的事，隔年 iOS 8 開放第三方。2020 年，iOS 14 讓小工具上主畫面，還能疊成「智慧型堆疊」，開發者改用 WidgetKit。",
     "這一次，大家記住了教訓：小工具不是一直在跑的程式。App 先交出一份時間軸，寫好每個時間點該顯示什麼。系統到了時間，自己換下一格畫面。Apple 的文件寫，常被查看的小工具一天約有 40 到 70 次更新額度，大約每 15 到 60 分鐘一次。2023 年，macOS Sonoma 讓小工具回到 Mac 桌面，iPhone 上的也能透過接續互通一起出現。從 Dashboard 的單獨一層，到直接擺在桌面上，中間這二十年，做法換成了更省電、也更安全的一套。",
     "手錶把「瞥一眼」縮到了最短：抬起手腕，看一眼，放下，只有幾秒。錶面上報時以外的功能，鐘錶業本來就叫 complication，像日期、月相和計時。2015 年 4 月 24 日開賣的 Apple Watch 沿用了這個詞，中文叫「複雜功能」。同年 9 月的 watchOS 2 開放第三方用 ClockKit 做。錶面上的一小格，只放得下此刻最需要的那一件事。2022 年，iOS 16 把小工具放上鎖定畫面，Apple 說靈感就來自這裡。",
     "2022 年 9 月 7 日，iPhone 14 Pro 帶來螢幕頂端的「動態島」。iOS 16.1 開放第三方用「即時動態」：外送到哪裡、比數多少、計時剩幾分，都留在鎖定畫面和島上。Apple 的準則只允許用在有明確開始和結束的事上，建議不超過八小時。事情一結束，畫面立刻收掉。2023 年，iOS 17 的「待機模式」讓橫放充電的 iPhone 變成一座遠處也看得清的時鐘，加上小工具。這是 iPhone 第一次被當成一塊放在桌上的螢幕。"
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
    "lesson": "不一直執行，照時間軸換畫面。進行中才出現，結束就消失。"
   },
   {
    "id": "homeplay",
    "year": "2026",
    "short": "HomeView 與 HomePlay",
    "era": "2026 · HomeView · HomePlay",
    "title": "一塊共用的螢幕，一個等你開口的助手。",
    "body": [
     "2026 年 10 月 13 日，Apple 發表 HomeView。這是一台 7 吋 Liquid Retina 的家用顯示器，有桌上型和壁掛型。畫面可以切換，有 Photos、Flow、Snoopy、Home Modular、Home Camera 等。Apple 台灣把這些畫面稱為「桌面」。每位登記的家人，有自己的主畫面和小工具。播放中的歌、計時器、從別的房間傳來的對講，都用即時動態顯示。",
     "這台機器把前面每一章的功課都做齊了。桌面附件的「要用時拿得到」，Dashboard 的「叫得出來、收得回去」，它都做到了。SideShow 當年想要的另一塊螢幕，它本身就是。WidgetKit 的時間軸、手錶的「一格只放一件事」、即時動態的「有始有終」，也都在這裡。",
     "HomePlay 是 Mac 上的開源桌寵，長得像 HomeView，頂端膠囊裡有一雙 👀。它大部分時間只是看著你，不出聲。你靠近，它才亮起來。你專心工作時，它不吵你。",
     "它的助手 ClioTalk，把從 Clippy 學到的事寫成了規則。它不自己跳出來，按住 F5 或點它，才開始聽。回答是暫時的，你說要留下，才會保存。凡是用你的名義做的事，像傳訊息、打電話、加行程、解開門鎖，都先唸給你聽，等你說好。替你寫訊息時，它用你自己說的話，不改成它的口氣。",
     "這些規則不保證它永遠猜對，只保證猜錯時不會替你做你沒答應的事。四十年前，蘋果選單裡的計算機要用時才出來，用完就收。我們希望 HomePlay 也是這樣。"
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
    "1999",
    "Stardock 開始做 DesktopX",
    "民間先動手"
   ],
   [
    "2001",
    "Office XP 預設關閉小幫手",
    "開始在意打擾"
   ],

   [
    "2001",
    "微軟 Sideshow 報告：周邊察覺",
    "研究先給了理由"
   ],
   [
    "2001-02",
    "Rainmeter 發布",
    "開源，活到今天"
   ],
   [
    "2003",
    "Konfabulator 推出",
    "成了一種軟體類別"
   ],

   [
    "2004",
    "Google Desktop",
    "搜尋公司也做側邊欄"
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
    "2011-09",
    "BUILD 開發者大會公開展示 Windows 8",
    "觸控優先的新面貌"
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
  "srcToggle": "本章出處（{n}）",
  "sourcesToggle": "全部出處（{n}）",
  "unsureToggle": "可能的疑點（{n}）",
  "unsureTitle": "還不確定的地方",
  "unsureLede": "下面這些只找到二手來源，或來源之間說法不一。正文已經避開，或寫成「據……」。",
  "unsure": [
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
   ],
  [
   "msrSideshow01",
   "周邊察覺的原始報告。"
  ],
  [
   "msrSideshow02",
   "數千人採用的後續。"
  ],
  [
   "desktopxHistory",
   "1999 年的起點。"
  ],
  [
   "rainmeterHistory",
   "2001-02-22 的發布。"
  ],
  [
   "rainmeterHome",
   "至今仍在維護。"
  ],
  [
   "gd2005",
   "2005 年的產品頁，側邊欄已在。"
  ],
  [
   "gdEol",
   "2004 年推出與 2011 年收攤，都由 Google 自己說。"
  ],
  [
   "yahooWidgetsEol",
   "Yahoo! 自己的關閉公告（2012-04-11）。"
  ],
  [
   "konfabSite",
   "2003 年 7 月的官方網站存檔。"
  ],
  [
   "desktopx35",
   "最後一版 3.5（2008-07-17）。"
  ],
  [
   "build2011",
   "Windows 8 首次公開。"
  ],
  [
   "sidebarDocs",
   "側邊欄的官方定義。"
  ],
  [
   "msSidebarHistory",
   "微軟自述側邊欄的族譜。"
  ],
  [
   "thurrott3683",
   "2002 年 11 月的公開報導。"
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
     "1981 年秋天，Macintosh 团队决定一次只跑一个程序。内存和屏幕都太小。Bud Tribble 出了个主意：另做一种小程序，开在主程序旁边的小窗口里，只做一件事。这种小程序叫「桌面摆饰」。1982 年秋天，文档组嫌「摆饰」太花哨，改名「桌面附件」。",
     "Andy Hertzfeld 和同事做出了这批附件：计算器、闹钟、记事本、剪贴板、Key Caps、控制面板，还有一个数字拼图。计算器长什么样，是 Steve Jobs 亲手调的。他用的是 Chris Espinosa 做的「计算器组合工具」。拼图一开始用 Pascal 写，超过 6 KB，团队一度不打算出货。Hertzfeld 花一个周末用汇编语言重写，缩到约 600 字节。就这样，拼图跟着第一台 Mac 出货了。",
     "这些附件都收在苹果菜单里。要用时打开，用完关掉，手上的文档一直都在。Apple 在《Inside Macintosh》里解释过它们的做法：桌面附件是做得像驱动程序的小程序。靠这个办法，Mac 在一次只跑一个程序的限制下，还能同时做几件事。"
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
     "1997 年 10 月 1 日，Internet Explorer 4.0 把网页放上了 Windows 桌面。「Active Desktop」让桌面直接显示网页内容。「Active Channel」把 500 多个网站做成自动推送的频道。想法是让桌面变成一扇一直开着的信息窗。可当时上网靠拨号。一直更新的壁纸占着电话线和内存，还在你眼角一直动。后来的 Windows 把这块地方给了别的设计。",
     "1996 年 11 月 19 日，Office 97 完成开发交给工厂，隔年初上市。里面有一位「Office 助手」，待在窗口角落提供建议和说明，最出名的造型是回形针 Clippy。它背后是认真的研究。Microsoft Research 的 Lumière 计划，用贝叶斯网络推测你在做什么、卡在哪里。贝叶斯网络是一种用概率做推测的数学模型。1998 年的论文写明，助手的部分组件以此为基础。",
     "可是，猜得到你要做什么，不代表该在那时开口。大家记得最清楚的，就是那句「看起来你在写信」。你没有问，它就在你打字时跳出来，挡住正在写的字。Office XP（2001）把它默认关闭。Microsoft 还为此办了一波网络宣传，产品经理说 Office XP 好用到不再需要 Clippy。2007 年版把它淘汰。",
     "Microsoft 还把会动的角色做成了现成的开发组件。1997 年 9 月 8 日，Microsoft Agent 免费开放下载。1998 年 10 月 12 日的 2.0 版加入鹦鹉 Peedy，和精灵 Genie、魔法师 Merlin、机器人 Robby 一起，成为最常见的四个角色。任何程序只要几行指令，就能叫角色走位、做动作、开口说话，还能接上文字转语音和语音识别。于是这些角色到处都是，也常常出现在不对的时候。Windows 7 起，Microsoft 把它淘汰了。"
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
    "year": "1999 → 2011",
    "short": "遍地开花",
    "era": "1999 → 2011 · 桌面小组件遍地开花",
    "title": "小组件有了名字，也有了自己的一层。",
    "body": [
     "这件事不是哪一家公司的专利。微软内部在 2000 年就有了这条侧边栏，许多员工的桌面上都看得到它。2001 年 9 月，研究员把它的道理写成论文：信息可以待在屏幕边缘，用眼角余光看，不必打断手上的事。他们把这叫「周边察觉」，界面叫 Sideshow，数百名员工试用了七个月。微软后来自己说：Windows 侧边栏的根，就是这条研究线。",
     "民间更早就动手了。1999 年的 DesktopX、2001 年的 Rainmeter，都让人自己往桌上放时钟、天气和系统状态。到 2005 年前后，Apple、Google 和微软都交出了自己的版本。",
     "2003 年，Arlo Rose 和 Perry Clarke 在 Mac OS X 上推出 Konfabulator，让人做自己浮在桌面上的小程序。2005 年 7 月，Yahoo! 买下它，把 20 美元的软件改成免费，后来改名 Yahoo! Widgets。2004 年 6 月 28 日，Apple 在 WWDC 上预览了 Tiger，里面的 Dashboard 也做这类小程序，还给它们起了统一的名字：widgets。Tiger 在 2005 年 4 月 29 日上市，Dashboard 内置 14 个，用 HTML 和 JavaScript 这样的网页技术写成。按一个键，全部浮上来。再按一次，收回去。",
     "Rose 说 Apple 抄了他的点子。John Gruber 写文章反驳，把这类东西的源头追回到 1984 年的桌面附件。两种说法到今天都还在。没有争议的是结果：Dashboard 让小组件有了一层自己的空间，叫得出来，也收得回去。",
     "Windows 这边，故事从侧边栏开始。最早的公开记录在 2002 年 11 月：记者 Paul Thurrott 试用了 Longhorn 的早期开发版，把侧边栏称为「Longhorn 讨论度最高的功能」。上面放着一格一格叫 Tiles 的组件：时钟、搜索栏、照片轮播，连快速启动栏都搬了进去。微软自己在 2003 年的 PDC 开发者大会上公开了侧边栏；2004 年 Longhorn 重置后，一小群人把它继续养大。到了 Vista，侧边栏正式上市：微软的文件说，它是桌面上一条像任务栏的长板，专门放小工具（gadgets）。Vista 在 2007 年 1 月 30 日上市，Windows 7 从 2009 年 10 月 22 日起，让小工具直接放在桌面上。",
     "Microsoft 同期还做了 SideShow：小工具在电脑上跑，画面送到另一块小屏幕上，比如笔记本的外盖。原型屏幕是 220 × 176，开着只耗约 4 毫瓦，而整台电脑约 75 瓦。电脑睡着时，它还能显示上次同步的内容。",
     "但 SideShow 没有普及。2007 年 5 月，Computerworld 报道，买得到的 SideShow 笔记本只有华硕一款。WeatherBug 的 SideShow 版下载不到一万次，桌面版超过六十万次。小屏幕上看到的只是快照。想看新的内容，就得唤醒电脑。评测也抱怨，它为了更新，常把整台电脑从待机里吵醒。",
     "这股热闹在十年末散场：DesktopX 的最后一版停在 2008 年，Google 在 2011 年收掉 Google Desktop，Yahoo! 在 2012 年关上小工具画廊。",
    ],
    "links": [
     "msrSideshow01",
     "msrSideshow02",
     "desktopxHistory",
     "rainmeterHistory",
     "rainmeterHome",
     "gd2005",
     "gdEol",
     "yahooWidgetsEol",
     "konfabSite",
     "desktopx35",
     "sidebarDocs",
     "msSidebarHistory",
     "thurrott3683",
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
     "2012 年 7 月 10 日，Microsoft 发布安全公告 2719662：侧边栏和小工具有漏洞，攻击者可以从远程在你电脑上运行代码。漏洞有两种来路。正常的小工具自己可能有漏洞。攻击者也能骗你装上恶意的小工具。无论哪种，代码都用你的权限跑，能做任何事。",
     "Microsoft 的应对是一个官方工具，把侧边栏和小工具整个关掉。早在 2011 年 9 月的 BUILD 开发者大会，Microsoft 就公开展示了触控优先的 Windows 8，并发布开发者预览。到了 Windows 8，小工具被整个移出系统，换成动态磁贴和 App。因为就连无害的小工具，也可能被人利用。"
    ],
    "links": [
     "advisory",
     "build2011",
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
     "手机把小组件带了回来。2009 年 4 月，Android 1.5 开放主屏幕小组件。2013 年，iOS 7 在通知中心加了「今天」，一眼看完今天的事，隔年 iOS 8 开放第三方。2020 年，iOS 14 让小组件上主屏幕，还能叠成「智能叠放」，开发者改用 WidgetKit。",
     "这一次，大家记住了教训：小组件不是一直在跑的程序。App 先交出一份时间轴，写好每个时间点该显示什么。系统到了时间，自己换下一格画面。Apple 的文档写，常被查看的小组件一天约有 40 到 70 次更新额度，大约每 15 到 60 分钟一次。2023 年，macOS Sonoma 让小组件回到 Mac 桌面，iPhone 上的也能通过连续互通一起出现。从 Dashboard 的单独一层，到直接摆在桌面上，中间这二十年，做法换成了更省电、也更安全的一套。",
     "手表把「瞥一眼」缩到了最短：抬起手腕，看一眼，放下，只有几秒。表盘上报时以外的功能，钟表业本来就叫 complication，像日期、月相和计时。2015 年 4 月 24 日发售的 Apple Watch 沿用了这个词，中文叫「复杂功能」。同年 9 月的 watchOS 2 开放第三方用 ClockKit 来做。表盘上的一小格，只放得下此刻最需要的那一件事。2022 年，iOS 16 把小组件放上锁定屏幕，Apple 说灵感就来自这里。",
     "2022 年 9 月 7 日，iPhone 14 Pro 带来屏幕顶端的「灵动岛」。iOS 16.1 开放第三方用「实时活动」：外卖到哪里、比分多少、计时还剩几分钟，都留在锁定屏幕和岛上。Apple 的准则只允许用在有明确开始和结束的事上，建议不超过八小时。事情一结束，画面立刻收掉。2023 年，iOS 17 的「待机显示」让横放充电的 iPhone 变成一座远处也看得清的时钟，加上小组件。这是 iPhone 第一次被当成一块放在桌上的屏幕。"
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
    "lesson": "不一直运行，照时间轴换画面。进行中才出现，结束就消失。"
   },
   {
    "id": "homeplay",
    "year": "2026",
    "short": "HomeView 与 HomePlay",
    "era": "2026 · HomeView · HomePlay",
    "title": "一块共用的屏幕，一个等你开口的助手。",
    "body": [
     "2026 年 10 月 13 日，Apple 发布 HomeView。这是一台 7 英寸 Liquid Retina 的家用显示器，有桌面款和壁挂款。画面可以切换，有 Photos、Flow、Snoopy、Home Modular、Home Camera 等。Apple 台湾把这些画面称为「桌面」。每位登记的家人，有自己的主屏幕和小组件。播放中的歌、计时器、从别的房间传来的对讲，都用实时活动显示。",
     "这台机器把前面每一章的功课都做齐了。桌面附件的「要用时拿得到」，Dashboard 的「叫得出来、收得回去」，它都做到了。SideShow 当年想要的另一块屏幕，它本身就是。WidgetKit 的时间轴、手表的「一格只放一件事」、实时活动的「有始有终」，也都在这里。",
     "HomePlay 是 Mac 上的开源桌宠，长得像 HomeView，顶端胶囊里有一双 👀。它大部分时间只是看着你，不出声。你靠近，它才亮起来。你专心工作时，它不吵你。",
     "它的助手 ClioTalk，把从 Clippy 学到的事写成了规则。它不自己跳出来，按住 F5 或点它，才开始听。回答是暂时的，你说要留下，才会保存。凡是用你的名义做的事，像发消息、打电话、加日程、解开门锁，都先念给你听，等你说好。替你写消息时，它用你自己说的话，不改成它的口气。",
     "这些规则不保证它永远猜对，只保证猜错时不会替你做没答应的事。四十年前，苹果菜单里的计算器要用时才出来，用完就收。我们希望 HomePlay 也是这样。"
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
    "1999",
    "Stardock 开始做 DesktopX",
    "民间先动手"
   ],
   [
    "2001",
    "Office XP 默认关闭助手",
    "开始在意打扰"
   ],

   [
    "2001",
    "微软 Sideshow 报告：周边察觉",
    "研究先给了理由"
   ],
   [
    "2001-02",
    "Rainmeter 发布",
    "开源，活到今天"
   ],
   [
    "2003",
    "Konfabulator 推出",
    "成了一种软件类别"
   ],
   [
    "2004",
    "Google Desktop",
    "搜索公司也做侧边栏"
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
    "2011-09",
    "BUILD 开发者大会公开展示 Windows 8",
    "触控优先的新面貌"
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
  "srcToggle": "本章出处（{n}）",
  "sourcesToggle": "全部出处（{n}）",
  "unsureToggle": "可能的疑点（{n}）",
  "unsureTitle": "还不确定的地方",
  "unsureLede": "下面这些只找到二手来源，或来源之间说法不一。正文已经避开，或写成「据……」。",
  "unsure": [
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
   ],
  [
   "msrSideshow01",
   "周边察觉的原始报告。"
  ],
  [
   "msrSideshow02",
   "数千人采用的后续。"
  ],
  [
   "desktopxHistory",
   "1999 年的起点。"
  ],
  [
   "rainmeterHistory",
   "2001-02-22 的发布。"
  ],
  [
   "rainmeterHome",
   "至今仍在维护。"
  ],
  [
   "gd2005",
   "2005 年的产品页，侧边栏已在。"
  ],
  [
   "gdEol",
   "2004 年推出与 2011 年收摊，都由 Google 自己说。"
  ],
  [
   "yahooWidgetsEol",
   "Yahoo! 自己的关闭公告（2012-04-11）。"
  ],
  [
   "konfabSite",
   "2003 年 7 月的官方网站存档。"
  ],
  [
   "desktopx35",
   "最后一版 3.5（2008-07-17）。"
  ],
  [
   "build2011",
   "Windows 8 首次公开。"
  ],
  [
   "sidebarDocs",
   "侧边栏的官方定义。"
  ],
  [
   "msSidebarHistory",
   "微软自述侧边栏的族谱。"
  ],
  [
   "thurrott3683",
   "2002 年 11 月的公开报道。"
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
    "year": "1999 → 2011",
    "short": "The bloom",
    "era": "1999 → 2011 · widgets everywhere",
    "title": "Widgets got a name, and a layer of their own.",
    "body": [
     "This was not one company's idea. Inside Microsoft a sidebar was already running by 2000, visible on many employees' desktops. In September 2001 its researchers put the reason into words: information can wait at the edge of the screen, caught with a glance, without interrupting the work at hand. They called it peripheral awareness, the interface Sideshow, and several hundred employees used it for seven months. Microsoft later said so itself: the Windows Sidebar grew out of this research line.",
     "Hobbyists had started even earlier. DesktopX in 1999 and Rainmeter in 2001 both let people put clocks, weather and system meters on the desktop themselves. By around 2005, Apple, Google and Microsoft had each shipped their own version.",
     "In 2003 Arlo Rose and Perry Clarke released Konfabulator for Mac OS X, which let people make small programs that floated on the desktop. Yahoo! bought it in July 2005, made the $20 program free, and later renamed it Yahoo! Widgets. On 28 June 2004 Apple previewed Mac OS X Tiger at WWDC, and its Dashboard introduced widgets as a class of their own. Tiger went on sale on 29 April 2005 with 14 of them, built on web technologies such as HTML and JavaScript. One keystroke brought them to the top; another sent them all away. Rose said Apple had copied his idea. John Gruber disagreed on Daring Fireball and traced the idea back to the 1984 desk accessories. Both views are still around. No one disputes this: Dashboard gave widgets a layer of their own, easy to summon and easy to dismiss.",
     "On the Windows side, the story starts with the Sidebar. The earliest public record is from November 2002: Paul Thurrott tried an early Longhorn build and called the Sidebar 'Longhorn's most discussed feature'. It held components called Tiles: a clock, a search bar, a photo slide show, even the Quick Launch toolbar moved in. Microsoft itself showed the Sidebar at the PDC conference in 2003, and after the 2004 Longhorn reset a small team kept it alive. With Windows Vista the Sidebar shipped for real: Microsoft's documentation describes it as a lockable panel on the desktop, like the taskbar, that hosts gadgets, and gadgets could sit at the edge of the desktop. Windows Vista reached consumers on 30 January 2007; Windows 7, on sale from 22 October 2009, let them sit anywhere. In the same years Microsoft built Windows SideShow: gadgets still ran on the PC while their content went to a second small screen, such as a laptop lid. The prototype described in MSDN Magazine had a 220 × 176 display that drew about 4 milliwatts, against roughly 75 watts for the whole PC, and it could keep showing the last synced content while the PC slept. SideShow did not catch on. In May 2007 Computerworld noted that consumers could buy only one SideShow laptop, from ASUS, and WeatherBug's SideShow version had fewer than 10,000 downloads against more than 600,000 for the desktop one. The small screen showed a snapshot; fresh content meant waking the PC, and reviews complained that it woke the whole laptop far too often.",
     "The bloom faded at the decade's end: DesktopX shipped its last version in 2008, Google retired Google Desktop in 2011, and Yahoo! closed the widget gallery in 2012."
    ],
    "links": [
     "msrSideshow01",
     "msrSideshow02",
     "desktopxHistory",
     "rainmeterHistory",
     "rainmeterHome",
     "gd2005",
     "gdEol",
     "yahooWidgetsEol",
     "konfabSite",
     "desktopx35",
     "sidebarDocs",
     "msSidebarHistory",
     "thurrott3683",
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
     "On 10 July 2012 Microsoft published Security Advisory 2719662: vulnerabilities in Windows Sidebar and gadgets could allow remote code execution. A legitimate gadget might have a flaw, or an attacker might trick you into installing a malicious one; either way, the code ran with your rights. Microsoft's fix was a tool that turned off Sidebar and gadgets entirely. Windows 8 itself had been shown to the public at the BUILD conference in September 2011, touch-first, as a developer preview. For Windows 8 its compatibility notes said gadgets were obsolete, replaced by live tiles and apps. Even harmless gadgets could be exploited, so they were removed from the operating system altogether."
    ],
    "links": [
     "advisory",
     "build2011",
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
    "1999",
    "Stardock starts DesktopX",
    "Hobbyists first"
   ],
   [
    "2001",
    "Office XP turns the Assistant off by default",
    "Interruptions start to matter"
   ],

   [
    "2001",
    "Microsoft’s Sideshow report: peripheral awareness",
    "Research named the need"
   ],
   [
    "2001-02",
    "Rainmeter released",
    "Open source, alive today"
   ],
   [
    "2003",
    "Konfabulator released",
    "Widgets become a kind of software"
   ],
   [
    "2004",
    "Google Desktop",
    "A search company too"
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
    "2011-09",
    "BUILD conference shows Windows 8 in public",
    "A touch-first look"
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
  "srcToggle": "Sources for this chapter ({n})",
  "sourcesToggle": "The full source list ({n})",
  "unsureToggle": "Open questions ({n})",
  "unsureTitle": "What we are not sure of",
  "unsureLede": "These rest on secondary sources or on claims that disagree; the text avoids them or says who claims them.",
  "unsure": [
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
   ],
  [
   "msrSideshow01",
   "The original peripheral-awareness report."
  ],
  [
   "msrSideshow02",
   "The follow-up: thousands of users."
  ],
  [
   "desktopxHistory",
   "The 1999 starting point."
  ],
  [
   "rainmeterHistory",
   "The 2001-02-22 release."
  ],
  [
   "rainmeterHome",
   "Still maintained today."
  ],
  [
   "gd2005",
   "The 2005 product page, sidebar already in."
  ],
  [
   "gdEol",
   "Google itself on the 2004 launch and the 2011 retirement."
  ],
  [
   "yahooWidgetsEol",
   "Yahoo!'s own notice (2012-04-11)."
  ],
  [
   "konfabSite",
   "The official site, archived July 2003."
  ],
  [
   "desktopx35",
   "Version 3.5, the last (2008-07-17)."
  ],
  [
   "build2011",
   "Windows 8 shown in public."
  ],
  [
   "sidebarDocs",
   "The official definition of the Sidebar."
  ],
  [
   "msSidebarHistory",
   "Microsoft tells the Sidebar's own lineage."
  ],
  [
   "thurrott3683",
   "The November 2002 report."
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

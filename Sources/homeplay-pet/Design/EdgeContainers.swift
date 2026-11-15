// 貼邊容器登記表（圓角同心稽核，2026-11-07）：HIG——貼近螢幕邊的容器，圓角跟機身螢幕同心。
// 每一個貼近螢幕邊的自繪容器在這裡登記「它的框」和「畫的時候用的半徑」（讀同一個 static，不另抄數字）；
// ShellSelfTest 逐一驗：半徑＝螢幕半徑 − 離螢幕邊的最短距離（不小於 12）。巢狀子元件驗「父半徑（實際畫出來的）− 內距」。
// 新加貼邊容器（卡片、面板、橫幅、sheet）：半徑用 HPTokens.Radius.concentric(rect:)，再在 all 加一行。
// 不登記：列表中間的列、網格中間的格子、置中的對話框（離邊超過螢幕半徑，見 docs 或稽核回報）、膠囊。

import AppKit

enum EdgeContainers {
    struct Entry {
        let name: String
        let rect: CGRect
        let radius: CGFloat
    }
    struct Nested {
        let name: String
        let parentRect: CGRect
        let parentRadius: CGFloat
        let padding: CGFloat
        let radius: CGFloat
    }

    static var all: [Entry] {
        let cpModel = CarPlayAirDropCard.Model(symbol: AirDropShare.symbol, tint: HPTokens.blue, title: "CarPlay", body: "AirDrop",   // l10n-ignore：自檢用的版面樣本
                                               note: "0:42", buttons: [(.resume, "OK", true)])   // l10n-ignore：自檢用的版面樣本
        let cp = CarPlayAirDropCard.layout(cpModel).rect
        let tip = CGRect(x: 92, y: 182, width: 840, height: 330)   // 膠囊在頂端時的位置（drawTouchTip：膠囊下緣 + 92）
        let la = LiveActivityStack.expandedRect(height: 200, top: LiveActivityStack.expandedInset)
        var list: [Entry] = [
            Entry(name: "AirDrop 收件卡", rect: AirDropCard.rect, radius: AirDropCard.radius),   // l10n-ignore
            Entry(name: "CarPlay 上的 AirDrop／暫停倒數卡", rect: cp, radius: CarPlayAirDropCard.radius(cp)),   // l10n-ignore
            Entry(name: "觸控提示卡", rect: tip, radius: TouchTip.radius(tip)),   // l10n-ignore
            Entry(name: "家庭警報橫幅（主頁）", rect: HomeApp.alertBannerRect(camera: false), radius: HomeApp.alertBannerRadius(HomeApp.alertBannerRect(camera: false))),   // l10n-ignore
            Entry(name: "家庭警報橫幅（攝影機頁）", rect: HomeApp.alertBannerRect(camera: true), radius: HomeApp.alertBannerRadius(HomeApp.alertBannerRect(camera: true))),   // l10n-ignore
            Entry(name: "浮動資料夾面板", rect: SBFloaty.panel, radius: SBFloaty.radius),   // l10n-ignore
            Entry(name: "控制中心展開大卡", rect: ControlCenter.expandedRect, radius: ControlCenter.expandedRadius),   // l10n-ignore
            Entry(name: "控制中心圖庫", rect: ControlCenter.galleryRect, radius: ControlCenter.galleryRadius),   // l10n-ignore
            Entry(name: "首次設定：語言卡", rect: SetupCards.language(rows: 4), radius: SetupCards.radius(SetupCards.language(rows: 4))),   // l10n-ignore
            Entry(name: "首次設定：權限卡", rect: SetupCards.permissions(rows: SetupPermission.allCases.count),   // l10n-ignore
                  radius: SetupCards.radius(SetupCards.permissions(rows: SetupPermission.allCases.count))),
            Entry(name: "即時動態展開大卡", rect: la, radius: LiveActivityStack.expandedRadius(la)),   // l10n-ignore
            Entry(name: "手勢引導：字卡", rect: Face.introCaption, radius: Face.introRadius(Face.introCaption)),   // l10n-ignore
            Entry(name: "手勢引導：其他手勢清單卡", rect: Face.introList, radius: Face.introRadius(Face.introList)),   // l10n-ignore
            Entry(name: "手勢引導：桌寵本身動作表", rect: Face.introTable, radius: Face.introRadius(Face.introTable)),   // l10n-ignore
            Entry(name: "手勢引導：升級提示卡", rect: IntroHint.card, radius: IntroHint.radius),   // l10n-ignore
        ]
        // 下面幾個在畫的地方寫 Screen.concentric(inset: card.minX)：登記它們的框，框改了讓 minX 不再是最近的那邊時這裡會擋
        for (name, r) in [("切換家人 sheet", Shell.sheetCard),   // l10n-ignore
                          ("加入網頁 App 卡", AddToHomeSheet.card), ("主畫面 sheet", SBUI.sheetCard)] {   // l10n-ignore
            list.append(Entry(name: name, rect: r, radius: Screen.concentric(inset: r.minX)))
        }
        // 2026-11-12：貼內容邊線 98.5 的分組卡 39.5（螢幕上的設定第一頁的兩張、尋找的兩張地圖卡）
        for (i, r) in SettingsApp.rootCards.enumerated() {
            list.append(Entry(name: "設定分組卡 \(i + 1)", rect: r, radius: HPTokens.Radius.contentCard))   // l10n-ignore
        }
        for (name, r) in [("尋找：地圖卡", HPTokens.FindMy.map), ("尋找：細節地圖卡", HPTokens.FindMy.detailMap)] {   // l10n-ignore
            list.append(Entry(name: name, rect: r, radius: HPTokens.Radius.group))
        }
        list.append(Entry(name: "計時器橫幅", rect: HPTokens.bannerCard, radius: Face.bannerRadius))   // l10n-ignore
        list.append(Entry(name: "世界時鐘地圖卡", rect: HPTokens.WorldClock.mapCard, radius: HPTokens.WorldClock.mapRadius))   // l10n-ignore
        return list
    }

    static var nested: [Nested] {
        let cpModel = CarPlayAirDropCard.Model(symbol: AirDropShare.symbol, tint: HPTokens.blue, title: "CarPlay", body: "AirDrop", note: nil, buttons: [])   // l10n-ignore：自檢用的版面樣本
        let cp = CarPlayAirDropCard.layout(cpModel).rect
        return [
            Nested(name: "AirDrop 收件卡的縮圖", parentRect: AirDropCard.rect, parentRadius: AirDropCard.radius, padding: 32, radius: AirDropCard.thumbRadius),   // l10n-ignore
            Nested(name: "CarPlay AirDrop 卡的圖示", parentRect: cp, parentRadius: CarPlayAirDropCard.radius(cp), padding: CarPlayAirDropCard.pad,   // l10n-ignore
                   radius: CarPlayAirDropCard.iconRadius(cp)),
            Nested(name: "設定列首的圖示方塊", parentRect: SettingsApp.rootCards[0], parentRadius: HPTokens.Radius.contentCard, padding: SettingsApp.inset,   // l10n-ignore
                   radius: SettingsApp.iconTileRadius),
        ]
    }

    /// 自檢：獨立算一次（不經過 HPTokens.Radius），跟登記的半徑比
    static func selfTest(_ check: (Bool, String) -> Void) {
        let R = Screen.cornerRadius, side = Screen.side
        for e in all {
            let inset = min(e.rect.minX, e.rect.minY, side - e.rect.maxX, side - e.rect.maxY)
            let want = max(12, R - inset)
            check(abs(e.radius - want) < 0.5, "同心：\(e.name) 離螢幕邊 \(Int(inset))，圓角 \(Int(e.radius)) 應為 \(Int(want.rounded()))")   // l10n-ignore
        }
        for n in nested {
            let drawn = min(n.parentRadius, min(n.parentRect.width, n.parentRect.height) / 2 / 1.52866483)
            let want = max(12, drawn - n.padding)
            check(abs(n.radius - want) < 0.5, "同心（巢狀）：\(n.name) 圓角 \(Int(n.radius)) 應為父 \(Int(drawn)) − 內距 \(Int(n.padding))")   // l10n-ignore
        }
        // 2026-11-12 共用規則：貼內容邊線的分組卡 39.5，往內逐層減內距（31.5、15.5，最小 12）；不貼邊的容器＝內容圓角＋內距
        let card = HPTokens.Radius.contentCard
        check(abs(card - (R - HPGrid.Content.leading)) < 0.01 && abs(card - 39.5) < 0.5, "同心：貼內容邊線 98.5 的分組卡圓角 39.5")   // l10n-ignore
        check(abs(HPTokens.Radius.concentric(parent: card, padding: 8) - 31.5) < 0.5
              && abs(HPTokens.Radius.concentric(parent: card, padding: 24) - 15.5) < 0.5
              && HPTokens.Radius.concentric(parent: card, padding: 40) == 12, "同心：分組卡往內逐層減內距（31.5、15.5），最小 12")   // l10n-ignore
        check(HPTokens.Radius.group == card, "同心：整台的分組卡同一個固定圓角 39.5（清單中段的卡片不逐張算同心）")   // l10n-ignore
        check(HPTokens.Radius.enclosing(content: 16, padding: 13) == 29, "同心：不貼邊的容器＝內容圓角＋內距（16 + 13 = 29）")   // l10n-ignore
        check(HPTokens.Radius.edgeInset(CGRect(x: 96, y: 96, width: 832, height: 888)) == 40, "同心：inset 取四邊最近的那邊（下緣 40，不是 minX 96）")   // l10n-ignore
    }
}

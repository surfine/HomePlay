// 2.0 P02：設定 › 外觀 › 主畫面外觀（HIG Widgets 的 Apple HomeView 一節：淺色、深色、透明、著色四選一；著色可以選色）。
// 原生 grouped Form 的一個 Section（跟其他設定頁一樣）；改了就丟掉主畫面靜態層、叫桌寵重畫。

import SwiftUI
import AppKit
import ImageIO

struct HomeAppearanceSection: View {
    @EnvironmentObject var m: SettingsModel
    @State private var look = HomeAppearance.current
    @State private var tint = Color(nsColor: HomeAppearance.tintColor)
    @State private var large = SB.largeIcons
    @State private var phoneApps = PhoneAppProvider.show
    @State private var wallPhoto = HomeWallpaper.photoPath
    @State private var lookName = HPLook.name
    @State private var confirmReset = false

    var body: some View {
        Section {
            Picker(selection: Binding(get: { look }, set: { v in
                look = v; HomeAppearance.set(v); m.app?.view.face.forceDirty = true
            })) {
                ForEach(HomeAppearance.allCases, id: \.self) { a in Label(a.title, systemImage: a.symbol).tag(a) }
            } label: {
                RowLabel(title: L("settings.home.appearance", "主屏幕外观"),
                         subtitle: L("settings.home.appearance.sub", "App 图标和小组件一起换"))
            }
            if look == .tinted {
                ColorPicker(L("settings.home.tint", "着色颜色"), selection: Binding(get: { tint }, set: { c in
                    tint = c; HomeAppearance.setTint(NSColor(c)); m.app?.view.face.forceDirty = true
                }), supportsOpacity: false)
            }
            // 2.0 SpringBoard：大圖示（隱藏名稱，iOS 18 起）與還原這個人的主畫面排列
            Toggle(L("sb.largeIcons", "大图标（隐藏名称）"), isOn: Binding(get: { large }, set: { v in
                large = v; SB.setLargeIcons(v); m.app?.view.face.forceDirty = true
            }))
            // 體驗追趕 P4-3：主畫面桌布——跟著錶面（預設）或照片牆的一張
            Picker(selection: Binding(get: { wallPhoto == nil ? 0 : 1 }, set: { v in
                if v == 0 { wallPhoto = nil; HomeWallpaper.set(nil) }
                else if wallPhoto == nil, let first = HomeWallpaper.photos().first { wallPhoto = first.path; HomeWallpaper.set(first.path) }
                else if wallPhoto == nil { wallPhoto = "" }
                m.app?.view.face.forceDirty = true
            })) {
                Text(L("settings.home.wallpaper.face", "跟着表盘")).tag(0)
                Text(L("settings.home.wallpaper.photo", "照片")).tag(1)
            } label: {
                RowLabel(title: L("settings.home.wallpaper", "主屏幕墙纸"), subtitle: L("settings.home.wallpaper.sub", "跟着刚才的表盘，或从照片墙挑一张"))
            }
            if wallPhoto != nil { wallpaperWall }
            // 照 Mac 的「顯示 iPhone App」：只管 App 資源庫與搜尋；放在主畫面上的不拿掉
            Toggle(isOn: Binding(get: { phoneApps }, set: { v in phoneApps = v; PhoneAppProvider.setShow(v); m.app?.view.face.forceDirty = true })) {
                RowLabel(title: L("settings.home.phoneApps", "显示 iPhone App"), subtitle: L("settings.home.phoneApps.sub", "在 App 资源库和搜索里列出 iPhone 上能用 CarPlay 的 App"))
            }
            Button(L("settings.home.reset", "还原主屏幕排列…")) { confirmReset = true }
                .disabled(!PersonHome.canEdit)
                .confirmationDialog(L("settings.home.reset.title", "要把主屏幕还原成默认排列吗？"), isPresented: $confirmReset) {
                    Button(L("settings.home.reset.ok", "还原"), role: .destructive) { SB.resetLayout(); m.app?.view.face.forceDirty = true }
                    Button(L("sb.cancel", "取消"), role: .cancel) {}
                } message: {
                    Text(L("settings.home.reset.body", "只还原现在这个人的主屏幕：App、小组件、文件夹和页面回到默认，App 都还在 App 资源库里。"))
                }
        } footer: {
            Text(L("settings.home.appearance.note", "每位家人的主屏幕排列各自保存：在主屏幕上按住半秒进入编辑。"))
        }
    }

    /// 照片牆：照片錶面那個資料夾的縮圖，點一張就換；下面是建議的 Look
    @ViewBuilder private var wallpaperWall: some View {
        let photos = HomeWallpaper.photos()
        if photos.isEmpty {
            Text(L("settings.home.wallpaper.empty", "把照片放进「图片 › HomePlay」文件夹，就能在这里挑。")).foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(photos.prefix(24), id: \.path) { u in
                    Button {
                        wallPhoto = u.path; HomeWallpaper.set(u.path); m.app?.view.face.forceDirty = true
                    } label: {
                        WallpaperThumb(url: u)
                            .overlay { if wallPhoto == u.path { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 3) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(u.deletingPathExtension().lastPathComponent)
                    .accessibilityAddTraits(wallPhoto == u.path ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
            if let s = HomeWallpaper.suggestedLook, s.name != lookName {
                Button(String(format: L("settings.home.wallpaper.look", "套用建议的 Look：%@"), s.name)) {
                    HPLook.select(s.name); lookName = s.name; Shell.homeLayer = nil; m.app?.view.face.forceDirty = true
                }
            }
        }
    }
}

/// 照片牆的一格：正方形縮圖（背景讀、長邊 240）
private struct WallpaperThumb: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Color.gray.opacity(0.2)
            .aspectRatio(1, contentMode: .fit)
            .overlay { if let image { Image(nsImage: image).resizable().scaledToFill() } }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task(id: url) {
                let u = url
                let img = await Task.detached(priority: .utility) { () -> NSImage? in
                    guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                                  kCGImageSourceThumbnailMaxPixelSize: 240,
                                                                                  kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }.value
                image = img
            }
    }
}

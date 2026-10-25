import AppKit
import SwiftUI

// 2.0 P10（HV-NEWS-47、HV-MAIN-57）：設定 › 外觀 ›「共享相簿」：勾哪幾本，主畫面的「照片」小工具與「照片」錶面就輪流放它們的照片。
// 系統的分組表單；沒授權時一顆「允許取用照片…」（走既有的權限卡），沒有共享相簿時一句怎麼打開。

final class SharedAlbumsModel: ObservableObject {
    @Published var status = PhotosWidgetSource.status
    @Published var albums: [SharedAlbumInfo]?     // nil＝正在讀
    @Published var selected = Set(SharedAlbums.selected)

    func refresh() {
        status = PhotosWidgetSource.status
        selected = Set(SharedAlbums.selected)
        guard status == .granted else { albums = []; return }
        albums = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let xs = SharedAlbums.list()
            DispatchQueue.main.async { self.albums = xs }
        }
    }

    func set(_ id: String, _ on: Bool) {
        if on { selected.insert(id) } else { selected.remove(id) }
        // 照列表的順序存；已經不在的（相簿被刪了）一併拿掉
        SharedAlbums.selected = (albums ?? []).map(\.id).filter(selected.contains)
        (NSApp.delegate as? AppDelegate)?.view?.face.forceDirty = true
        Shell.homeLayer = nil
    }

    func ask() {
        (NSApp.delegate as? AppDelegate)?.withPermission(.photos) { [weak self] ok in
            if ok { PhotosWidgetSource.shared.reset() }
            self?.refresh()
        }
    }
}

struct SharedAlbumsSection: View {
    @StateObject private var m = SharedAlbumsModel()

    var body: some View {
        Section {
            switch m.status {
            case .granted:
                if let albums = m.albums {
                    if albums.isEmpty {
                        InfoRow(title: L("sharedAlbums.none", "没有找到共享相簿"),
                                subtitle: L("sharedAlbums.none.sub", "在「照片」App 的设置里打开「共享相簿」，或请家人邀请你加入"))
                    }
                    ForEach(albums) { a in
                        Toggle(isOn: Binding(get: { m.selected.contains(a.id) }, set: { m.set(a.id, $0) })) {
                            RowLabel(title: a.title, subtitle: String(format: L("sharedAlbums.count", "%d 张照片"), a.count))
                        }
                    }
                } else {
                    InfoRow(title: L("sharedAlbums.loading", "正在读取共享相簿…"))
                }
            case .notDetermined, .denied:
                LabeledContent {
                    Button(m.status == .denied ? L("sharedAlbums.openSettings", "打开系统设置…") : L("sharedAlbums.allow", "允许读取照片…")) {
                        if m.status == .denied { PermissionCenter.openSettings(.photos) } else { m.ask() }
                    }
                } label: {
                    RowLabel(title: L("sharedAlbums.title", "共享相簿"),
                             subtitle: m.status == .denied ? L("sharedAlbums.denied", "HomePlay 没有读取照片的权限") : L("sharedAlbums.ask", "先允许 HomePlay 读取「照片」图库"))
                }
            }
        } header: {
            Text(L("sharedAlbums.title", "共享相簿"))
        } footer: {
            Text(L("sharedAlbums.footer", "勾了的相簿会轮流出现在主屏幕的「照片」小组件和「照片」表盘上；一本都不勾就照旧（精选照片、照片文件夹）。只读这台 Mac 上已经下载的照片，不联网、不存档。共享相簿认出你或家人时显示，访客和认不出的人看不到。"))
                .foregroundStyle(.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { m.refresh() }
    }
}

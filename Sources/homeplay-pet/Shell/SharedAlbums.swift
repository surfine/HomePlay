// 2.0 P10（HV-NEWS-47、HV-MAIN-57）：「照片」App 的共享相簿當照片來源——主畫面的「照片」小工具與「照片」錶面。
// HomeView 的說法：選一本共享相簿，親友一起把它填滿，HomeView 就是一個相框。
// PhotoKit：PHAssetCollection（.album／.albumCloudShared）；macOS 27 SDK 有這個子類型，相簿要在「照片」App 打開「共享相簿」才會出現。
// 規則跟照片小工具一樣：只在本機（isNetworkAccessAllowed = false，還沒下載到這台 Mac 的那張就跳過）、不存檔、不寫日誌；
// 主人與登記的家人看得到（PersonalGate.audience：訪客模式、認不出的人不讀，小工具顯示「需要主人」、錶面退回照片資料夾）；個人圖庫仍只給主人；快照一律不讀。
// 設定 › 外觀 ›「共享相簿」勾哪幾本（Settings/SharedAlbumsSection.swift）；一本都沒勾＝照舊（小工具＝精選照片、錶面＝照片資料夾）。
// --photos-probe 也印共享相簿的本數與張數（驗 PhotoKit 這條路，不印名字、不出圖）。

import AppKit
import Photos

struct SharedAlbumInfo: Equatable, Identifiable {
    var id: String
    var title: String
    var count: Int
}

enum SharedAlbums {
    static let key = "SharedAlbumsSelected"

    /// 勾了哪幾本（localIdentifier）
    static var selected: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            PhotosWidgetSource.shared.reset()   // 小工具重新挑
            SharedAlbumFeed.shared.reset()      // 錶面重新挑
        }
    }

    // MARK: 純邏輯

    enum Source: Equatable { case library, shared, none }
    /// 小工具／錶面這次從哪裡拿：沒勾＝照舊；勾了：主人與登記的家人讀共享相簿，訪客、認不出的人、訪客模式不讀（none）；快照不讀
    static func source(selected: [String], audience: PersonalGate.Audience, snapshot: Bool) -> Source {
        if snapshot || selected.isEmpty { return .library }
        return audience == .none ? .none : .shared
    }
    /// 好幾本合起來：新的在前、同一張只算一次、截圖不算、最多 limit 張
    static func merge(_ albums: [[PhotoCandidate]], limit: Int = 300) -> [PhotoCandidate] {
        var seen = Set<String>()
        return albums.flatMap { $0 }.filter { !$0.screenshot }
            .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
            .filter { seen.insert($0.id).inserted }
            .prefix(limit).map { $0 }
    }
    /// 錶面：每分鐘換一張（跟照片資料夾一樣）
    static func faceIndex(count: Int, now: Date) -> Int? {
        guard count > 0 else { return nil }
        return Int(floor(now.timeIntervalSince1970 / 60)) % count
    }

    static func selftest(_ check: (Bool, String) -> Void) {
        check(source(selected: [], audience: .owner, snapshot: false) == .library && source(selected: ["a"], audience: .owner, snapshot: false) == .shared
              && source(selected: ["a"], audience: .none, snapshot: false) == .none && source(selected: ["a"], audience: .owner, snapshot: true) == .library,
              "共享相簿：沒勾照舊、勾了給主人與家人、快照不讀")   // l10n-ignore：selftest 訊息
        // 觀眾真值表：主人、家人、陌生人、訪客模式、沒開認人、換人提示
        typealias I = PersonalGate.Inputs
        check(PersonalGate.audience(I(recognitionActive: true, viewer: .owner("o"))) == .owner
              && PersonalGate.audience(I(recognitionActive: true, viewer: .known("k"))) == .family
              && PersonalGate.audience(I(recognitionActive: true, viewer: .guest)) == .none
              && PersonalGate.audience(I(recognitionActive: true, viewer: .nobody)) == .none
              && PersonalGate.audience(I(guestMode: true, recognitionActive: true, viewer: .known("k"))) == .none
              && PersonalGate.audience(I(guestMode: true)) == .none
              && PersonalGate.audience(I()) == .owner
              && PersonalGate.audience(I(hintIsOwner: false), hintIsFamily: true) == .family
              && PersonalGate.audience(I(hintIsOwner: false)) == .none,
              "共享相簿觀眾：主人、家人看得到；陌生人、訪客模式、沒人看不到；沒開認人照舊是主人")   // l10n-ignore：selftest 訊息
        check(source(selected: ["a"], audience: .family, snapshot: false) == .shared && source(selected: ["a"], audience: .family, snapshot: true) == .library
              && source(selected: [], audience: .family, snapshot: false) == .library, "共享相簿：家人讀共享相簿、快照不讀")   // l10n-ignore：selftest 訊息
        let d = { (s: Double) in Date(timeIntervalSince1970: s) }
        let a = [PhotoCandidate(id: "1", created: d(100), favorite: false, screenshot: false), PhotoCandidate(id: "2", created: d(300), favorite: false, screenshot: false)]
        let b = [PhotoCandidate(id: "3", created: d(200), favorite: false, screenshot: false), PhotoCandidate(id: "1", created: d(100), favorite: false, screenshot: false),
                 PhotoCandidate(id: "s", created: d(400), favorite: false, screenshot: true)]
        check(merge([a, b]).map(\.id) == ["2", "3", "1"] && merge([a, b], limit: 1).map(\.id) == ["2"], "共享相簿：幾本合起來新的在前、不重複、截圖不算")
        check(faceIndex(count: 3, now: d(120)) == 2 && faceIndex(count: 3, now: d(180)) == 0 && faceIndex(count: 0, now: d(0)) == nil, "共享相簿：錶面每分鐘換一張")
    }

    // MARK: PhotoKit（只在本機，呼叫端在背景執行緒）

    /// 拿得到共享相簿的照片（預設的 fetch 只看自己的圖庫）
    static var assetOptions: PHFetchOptions {
        let o = PHFetchOptions()
        o.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
        return o
    }

    static func list() -> [SharedAlbumInfo] {
        guard PhotosWidgetSource.status == .granted else { return [] }
        var out: [SharedAlbumInfo] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil).enumerateObjects { c, _, _ in
            out.append(SharedAlbumInfo(id: c.localIdentifier, title: c.localizedTitle ?? "—", count: PHAsset.fetchAssets(in: c, options: imagesOnly).count))
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static var imagesOnly: PHFetchOptions {
        let o = assetOptions
        o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return o
    }

    /// 勾的那幾本裡的照片（id，新的在前）
    static func candidates(_ ids: [String]) -> [String] {
        guard !ids.isEmpty, PhotosWidgetSource.status == .granted else { return [] }
        var albums: [[PhotoCandidate]] = []
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids, options: nil).enumerateObjects { c, _, _ in
            var xs: [PhotoCandidate] = []
            let o = imagesOnly; o.fetchLimit = 300
            PHAsset.fetchAssets(in: c, options: o).enumerateObjects { a, _, _ in
                xs.append(PhotoCandidate(id: a.localIdentifier, created: a.creationDate, favorite: a.isFavorite, screenshot: a.mediaSubtypes.contains(.photoScreenshot)))
            }
            albums.append(xs)
        }
        return merge(albums).map(\.id)
    }
}

/// 「照片」錶面的共享相簿來源：每分鐘換一張，在背景讀、讀好叫重畫；沒勾、不是主人、快照時回 nil（錶面照舊用照片資料夾）
final class SharedAlbumFeed {
    static let shared = SharedAlbumFeed()
    private var ids: [String]?
    private var fetchedAt: Date?
    private var loading = false
    private var shownID: String?
    private(set) var image: CGImage?
    private let queue = DispatchQueue(label: "homeplay.sharedAlbums", qos: .utility)

    func reset() { ids = nil; fetchedAt = nil; shownID = nil; image = nil }

    func faceImage(now: Date = Date(), onChange: @escaping () -> Void) -> CGImage? {
        let sel = SharedAlbums.selected
        guard SharedAlbums.source(selected: sel, audience: PersonalGate.cachedAudience, snapshot: PhotosWidgetSource.snapshotMode) == .shared,
              PhotosWidgetSource.status == .granted else { return nil }
        if ids == nil || fetchedAt.map({ now.timeIntervalSince($0) > 3600 }) ?? true {
            if !loading {
                loading = true
                queue.async { [weak self] in
                    let found = SharedAlbums.candidates(sel)
                    DispatchQueue.main.async { self?.loading = false; self?.ids = found; self?.fetchedAt = now; onChange() }
                }
            }
            return image
        }
        guard let ids, let i = SharedAlbums.faceIndex(count: ids.count, now: now) else { return image }
        if ids[i] != shownID {
            shownID = ids[i]
            load(ids[i], onChange: onChange)
        }
        return image
    }

    private func load(_ id: String, onChange: @escaping () -> Void) {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: SharedAlbums.assetOptions).firstObject else { return }
        let o = PHImageRequestOptions()
        o.isNetworkAccessAllowed = false          // 只在本機
        o.deliveryMode = .highQualityFormat
        o.resizeMode = .fast
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1400, height: 1400), contentMode: .aspectFill, options: o) { [weak self] img, _ in
            DispatchQueue.main.async {
                guard let self, self.shownID == id else { return }
                var r = NSRect(origin: .zero, size: img?.size ?? .zero)
                if let cg = img?.cgImage(forProposedRect: &r, context: nil, hints: nil) { self.image = cg; onChange() }
            }
        }
    }
}

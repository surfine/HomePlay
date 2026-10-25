import AppKit
import Foundation

// 家人名册：最多 6 人，第 1 位是这台 Mac 的主人（名字取自 NSFullUserName()）。
// 脸部模板是生物特征：
// - 放在 ~/Library/Application Support/HomePlay/People/（目录 0700，文件 0600，排除备份）；
// - 只存特征数字，不存图像；任何地方都不写日志（日志里最多出现「几个人」「成功／失败」，不出现名字和数字）；
// - 随时可以「删除所有脸部数据」。
// 名册（名字、头像颜色）和模板分开存：people.json 不含任何生物特征。

struct Person: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    /// 头像配色在 Person.palette 里的序号。
    var colorIndex: Int
    let isOwner: Bool
    /// 2.0 第四輪：自己選的 👀 人物頭像（nil＝照配色序號的預設，見 Design/HPAvatar.swift）
    var avatar: HPAvatar.Style? = nil
    /// 2.0 第四輪：改用聯絡人照片（只對主人有用：Contacts 的「我」）；第五輪起只當舊資料讀（見 avatarSource）
    var useContactPhoto: Bool? = nil
    /// 2.0 第五輪：頭像來源（nil＝自動：帳號頭像 → 聯絡人「我」→ 縮寫；見 People/AvatarSources.swift）
    var avatarSource: AvatarSource? = nil

    /// 头像上的字：名字的第一个字（取第一个字素，不拆开 emoji 和合字）。
    var initial: String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(first).uppercased()
    }

    /// 头像配色（底色, 字色）：第一组是设计稿里的 #f2b07a / #3a2210。
    static let palette: [(bg: UInt32, fg: UInt32)] = [
        (0xf2b07a, 0x3a2210), (0x9fd3ff, 0x0b2a45), (0xa8e0b0, 0x12351a),
        (0xf5a9c8, 0x45152f), (0xc6b2f2, 0x261a4a), (0xf3d98b, 0x3d2f08),
    ]
    var avatarColors: (bg: UInt32, fg: UInt32) { Self.palette[((colorIndex % Self.palette.count) + Self.palette.count) % Self.palette.count] }
}

enum PeopleError: Error, Equatable {
    case limitReached
    case emptyName
    case notFound
    case isOwner
    case writeFailed
}

final class PeopleRegistry {
    static let maxPeople = 6
    static let maxNameLength = 24
    /// 目前钉死的特征模型版本；模板是别的版本的就不参与比对（人要重新录）。
    static let modelVersion = FaceModelProfile.visionFeaturePrintVersion

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("HomePlay/People", isDirectory: true)
    }
    nonisolated(unsafe) static let shared = PeopleRegistry(directory: defaultDirectory)

    let directory: URL
    private let ownerName: () -> String
    private let fm = FileManager.default
    private(set) var people: [Person] = []
    /// 名册或模板变了（主线程之外也可能触发，观察者自己切回主线程）。
    var onChange: (() -> Void)?

    init(directory: URL, ownerName: @escaping () -> String = PeopleRegistry.systemOwnerName) {
        self.directory = directory
        self.ownerName = ownerName
        load()
    }

    static func systemOwnerName() -> String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? NSUserName() : full
    }

    var owner: Person? { people.first(where: \.isOwner) }
    func person(_ id: String) -> Person? { people.first { $0.id == id } }
    var canAddPerson: Bool { people.count < Self.maxPeople }

    // MARK: 路径与权限

    private var rosterURL: URL { directory.appendingPathComponent("people.json") }
    private func templatesURL(_ id: String) -> URL { directory.appendingPathComponent("templates-\(id).json") }

    /// 目录 0700；文件创建时就是 0600（先建临时文件再改名，不会有一瞬间是宽松权限）。
    private func ensureDirectory() throws {
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var dir = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try ensureDirectory()
        let tmp = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw PeopleError.writeFailed
        }
        if Darwin.rename(tmp.path, url.path) != 0 {
            try? fm.removeItem(at: tmp)
            throw PeopleError.writeFailed
        }
    }

    // MARK: 名册

    private func load() {
        if let data = try? Data(contentsOf: rosterURL), let decoded = try? JSONDecoder().decode([Person].self, from: data) {
            // 校验：最多 6 人、恰好一位主人且排第一；坏数据当没有，重建主人，不猜。
            let owners = decoded.filter(\.isOwner)
            if decoded.count <= Self.maxPeople, owners.count == 1, decoded.first?.isOwner == true,
               Set(decoded.map(\.id)).count == decoded.count {
                people = decoded
                return
            }
        }
        people = [Person(id: UUID().uuidString, name: String(ownerName().prefix(Self.maxNameLength)), colorIndex: 0, isOwner: true)]
        try? saveRoster()
    }

    private func saveRoster() throws {
        guard let data = try? JSONEncoder().encode(people) else { throw PeopleError.writeFailed }
        try writePrivate(data, to: rosterURL)
    }

    private func cleaned(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(Self.maxNameLength))
    }

    @discardableResult
    func add(name: String) throws -> Person {
        guard people.count < Self.maxPeople else { throw PeopleError.limitReached }
        guard let name = cleaned(name) else { throw PeopleError.emptyName }
        // 配色挑还没被用的第一个，用完了再轮回。
        let used = Set(people.map(\.colorIndex))
        let color = (0..<Person.palette.count).first { !used.contains($0) } ?? people.count % Person.palette.count
        let person = Person(id: UUID().uuidString, name: name, colorIndex: color, isOwner: false)
        people.append(person)
        do { try saveRoster() } catch { people.removeLast(); throw error }
        onChange?()
        return person
    }

    func rename(_ id: String, to name: String) throws {
        guard let index = people.firstIndex(where: { $0.id == id }) else { throw PeopleError.notFound }
        guard let name = cleaned(name) else { throw PeopleError.emptyName }
        people[index].name = name
        try saveRoster()
        onChange?()
    }

    /// 2.0 第五輪：換頭像（來源：自動／聯絡人照片／👀 人物；👀 的樣式照樣存著，換回來不用重選）
    func setAvatar(_ id: String, style: HPAvatar.Style?, source: AvatarSource) throws {
        guard let index = people.firstIndex(where: { $0.id == id }) else { throw PeopleError.notFound }
        people[index].avatar = style
        people[index].useContactPhoto = nil
        people[index].avatarSource = source == .contact && !people[index].isOwner ? .automatic : source
        try saveRoster()
        onChange?()
    }

    /// 删一个人和他的脸部数据。主人不能删（只能删他的脸部数据）。
    func remove(_ id: String) throws {
        guard let index = people.firstIndex(where: { $0.id == id }) else { throw PeopleError.notFound }
        guard !people[index].isOwner else { throw PeopleError.isOwner }
        try? fm.removeItem(at: templatesURL(id))
        people.remove(at: index)
        try saveRoster()
        onChange?()
    }

    // MARK: 模板

    /// 整组替换这个人的模板（重新录制）。
    func saveTemplates(_ templates: [FaceTemplate], for id: String) throws {
        guard person(id) != nil else { throw PeopleError.notFound }
        guard let data = FaceTemplateSet.encode(templates, modelVersion: Self.modelVersion) else { throw PeopleError.writeFailed }
        try writePrivate(data, to: templatesURL(id))
        onChange?()
    }

    /// 当前模型版本的模板；没录过、坏了、是别的版本的都返回空。
    func templates(for id: String) -> [FaceTemplate] {
        guard let data = try? Data(contentsOf: templatesURL(id)) else { return [] }
        return FaceTemplateSet.decode(data, modelVersion: Self.modelVersion)
    }

    enum FaceDataState: Equatable { case none, enrolled, staleModel }

    func faceDataState(_ id: String) -> FaceDataState {
        guard let data = try? Data(contentsOf: templatesURL(id)) else { return .none }
        if !FaceTemplateSet.decode(data, modelVersion: Self.modelVersion).isEmpty { return .enrolled }
        return FaceTemplateSet.storedModelVersion(data) != Self.modelVersion ? .staleModel : .none
    }

    func deleteTemplates(for id: String) {
        try? fm.removeItem(at: templatesURL(id))
        onChange?()
    }

    /// 删除所有脸部数据：全部模板文件。名册（名字）留着，人要重新录脸。返回删了几个文件。
    @discardableResult
    func deleteAllFaceData() -> Int {
        var removed = 0
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("templates-") || name.hasPrefix(".tmp-") {
            if (try? fm.removeItem(at: directory.appendingPathComponent(name))) != nil { removed += 1 }
        }
        onChange?()
        return removed
    }

    /// 给比对器的输入：每个人当前模型版本的模板（没录的人不出现）。
    func matcherInput() -> [PersonTemplates] {
        people.compactMap { p in
            let t = templates(for: p.id)
            return t.isEmpty ? nil : PersonTemplates(id: p.id, isOwner: p.isOwner, templates: t)
        }
    }

    var hasAnyFaceData: Bool { people.contains { faceDataState($0.id) != .none } }
}

// 錶面各自的選項：Typograph 的「材質」（平面／浮雕）、System 6 的「版式」（Finder／Alarm Clock／About）。
// 原本是三款獨立錶面（浮雕指針、System 6 · Alarm Clock、System 6 · About），併進這兩款當選項；設定存 UserDefaults。

import AppKit

extension Face {
    /// 啟動時讀回材質／版式；舊偏好存的是被併掉的錶面時，搬成對應的選項並寫回一次（使用者看到的還是同一個錶面）。
    /// 快照的命令行覆蓋優先，且不寫偏好。
    func restoreFaceOptions(migrating saved: FaceStyle) {
        let d = UserDefaults.standard
        let snapshotting = CommandLine.arguments.contains("--snapshot")
        typographMaterial = TypographMaterial(rawValue: d.string(forKey: TypographMaterial.defaultsKey) ?? "") ?? .flat
        system6Layout = System6Layout(rawValue: d.string(forKey: System6Layout.defaultsKey) ?? "") ?? .finder
        let mig = saved.migratedOptions
        if let m = mig.material { typographMaterial = m }
        if let l = mig.layout { system6Layout = l }
        if saved != saved.inLineup, !snapshotting {   // 只搬一次：之後 HomePlayFaceStyle 已是新錶面
            if let m = mig.material { d.set(m.rawValue, forKey: TypographMaterial.defaultsKey) }
            if let l = mig.layout { d.set(l.rawValue, forKey: System6Layout.defaultsKey) }
            d.set(saved.inLineup.rawValue, forKey: FaceStyle.defaultsKey)
        }
        if let m = faceOptionSnapshotOverride.material { typographMaterial = m }
        if let l = faceOptionSnapshotOverride.layout { system6Layout = l }
    }
}

// MARK: - 右键菜单与设置的动作

extension PetView {
    /// 右键菜单「Typograph 材质」「System 6 版式」：不是那一款時灰掉（設定裡也是同樣的條件）
    func faceOptionMenuItems() -> [NSMenuItem] {
        func sub(_ title: String, _ relevant: Bool, _ sel: Selector, _ choices: [(title: String, raw: String, on: Bool)]) -> NSMenuItem {
            let m = NSMenu()
            for c in choices {
                let i = NSMenuItem(title: c.title, action: sel, keyEquivalent: "")
                i.target = self; i.representedObject = c.raw; i.state = c.on ? .on : .off; m.addItem(i)
            }
            let item = submenuItem(title, m, symbol: "slider.horizontal.3")
            item.isEnabled = relevant
            return item
        }
        return [
            sub(L("typograph.material", "Typograph 材质"), face.style == .analog, #selector(menuTypographMaterial(_:)),
                TypographMaterial.allCases.map { ($0.title, $0.rawValue, face.typographMaterial == $0) }),
            sub(L("system6.layout", "System 6 版式"), face.style == .system6, #selector(menuSystem6Layout(_:)),
                System6Layout.allCases.map { ($0.title, $0.rawValue, face.system6Layout == $0) }),
        ]
    }
    @objc func menuTypographMaterial(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String, let v = TypographMaterial(rawValue: raw) else { return }
        face.typographMaterial = v; UserDefaults.standard.set(raw, forKey: TypographMaterial.defaultsKey)
        face.staticCache = nil; if face.style != .analog { setFaceStyle(.analog) }
        if !showingVideo { model.setScreen(face.render()) }
        log("typograph material \(raw)")
    }
    @objc func menuSystem6Layout(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String, let v = System6Layout(rawValue: raw) else { return }
        face.system6Layout = v; UserDefaults.standard.set(raw, forKey: System6Layout.defaultsKey)
        face.staticCache = nil; if face.style != .system6 { setFaceStyle(.system6) }
        if !showingVideo { model.setScreen(face.render()) }
        log("system6 layout \(raw)")
    }
}

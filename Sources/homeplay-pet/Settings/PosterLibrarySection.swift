// 多臉（錶面體系 backlog #1）：設定 › 外觀 › 海報——官方 PosterKit「多張海報」的等價物。
// 使用者 2026-11-08／11-09 拍板：多臉只換海報外觀（Look／字體／數字／版式），不換錶面種類；
// 新增時先選一個 Look 當模板（像官方畫廊），不是在目前這張上直接複製。
// 資料層在 Shell/PosterConfiguration.swift（PosterLibrary／PosterLibraryStore）。
import AppKit
import SwiftUI

struct PosterLibrarySection: View {
    @EnvironmentObject var m: SettingsModel
    @State private var items = PosterLibraryStore.all
    @State private var index = PosterLibraryStore.index
    @State private var removing: Int?
    @State private var choosing = false

    var body: some View {
        Section {
            ForEach(items.indices, id: \.self) { i in
                row(i)
            }
            Button {
                choosing = true
            } label: {
                RowLabel(title: L("settings.posters.add", "新增海报…"), symbol: "plus.circle.fill", tint: .blue)
            }
        } header: {
            SectionTitle(title: L("settings.posters", "海报"),
                         info: L("settings.posters.footer", "每一张是一套外观：Look、字体、数字与版式。删除不会移除任何 App 或数据。"))
        }
        .confirmationDialog(L("settings.posters.delete.confirm", "删除这张海报？"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L("settings.posters.delete", "删除海报"), role: .destructive) {
                if let i = removing { delete(i) }
                removing = nil
            }
            Button(L("sb.cancel", "取消"), role: .cancel) { removing = nil }
        } message: {
            Text(L("settings.posters.delete.message", "不会删除任何 App 或数据。"))
        }
        .sheet(isPresented: $choosing) { templateSheet }
    }

    /// 模板挑選：12 個官方 Look，點一個就用它建立一張新海報（字體照官方配對，版式沿用目前這張）
    private var templateSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("settings.posters.template", "选择模板")).font(.headline)
            Text(L("settings.posters.template.footer", "从 12 个 Look 里挑一个开始；之后还能改字体、数字与版式。"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 10)], spacing: 10) {
                    ForEach(HVTruth.looks, id: \.name) { l in
                        Button {
                            add(look: l)
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(nsColor: l.background_color))
                                VStack(spacing: 2) {
                                    Text("10:09")
                                        .font(.system(size: 22, weight: .medium))
                                        .foregroundStyle(Color(nsColor: l.numerals_color))
                                    Text(l.name)
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color(nsColor: l.secondary_color))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                                .padding(6)
                            }
                            .frame(height: 76)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            HStack {
                Spacer()
                Button(L("sb.cancel", "取消")) { choosing = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 460)
    }

    private func row(_ i: Int) -> some View {
        let c = items[i]
        let on = i == index
        let look = HVTruth.look(c.look)
        return HStack(spacing: 12) {
            // 選取只包左邊這一塊：垃圾桶在按鈕外面，點刪除不會順便選到這張
            Button {
                select(i)
            } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: look?.background_color ?? .secondaryLabelColor))
                        .overlay(Text("10:09")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color(nsColor: look?.numerals_color ?? .white))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6))
                        .frame(width: 42, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.look)
                        Text(subtitle(c)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            if on { Image(systemName: "checkmark").foregroundStyle(.tint) }
            Button(role: .destructive) {
                removing = i
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(items.count <= 1)
            .help(L("settings.posters.delete", "删除海报"))
        }
        .opacity(on ? 1 : 0.92)
    }

    private func subtitle(_ c: PosterConfiguration) -> String {
        let numerals = c.numerals.map { _ in L("settings.posters.customNumerals", "自订数字") } ?? L("settings.posters.autoNumerals", "自动数字")
        return "\(c.galleryFace.title) · \(c.typeface.title) · \(c.style.title) · \(numerals)"
    }

    private func select(_ i: Int) {
        guard i != index, PosterLibraryStore.select(i) else { return }
        apply()
    }

    /// 新增：以選中的 Look 為模板——字體照官方配對（factoryPresets），其餘沿用目前這張
    private func add(look: HVTruth.Look) {
        var c = PosterLibraryStore.current
        c.look = look.name
        if let pair = PosterConfiguration.factoryPresets.first(where: { $0.config.look == look.name }) {
            c.typeface = pair.config.typeface
        }
        c.extras.lookChosen = true
        _ = PosterLibraryStore.add(c)
        choosing = false
        apply()
    }

    private func delete(_ i: Int) {
        guard PosterLibraryStore.remove(i) else { return }
        apply()
    }

    private func apply() {
        PosterConfiguration.current = PosterLibraryStore.current
        HPLook.select(PosterLibraryStore.current.look)   // 明確選了外觀：日曆／Typograph 也跟這個 Look
        items = PosterLibraryStore.all
        index = PosterLibraryStore.index
        m.app?.view.face.forceDirty = true
        m.refresh()
    }
}

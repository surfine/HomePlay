// CarPlay 兩指：觸控報告依 id 分槽（HID.TouchSlots）與桌寵觸控訊息解析（HID.touchContacts(forPetMessage:)）。
// 單指的報告必須跟改之前逐位元組相同：legacyTouchReport 是改之前（65a643d）HID.touchReport 的原樣搬過來當參考。
import Foundation
import Session

/// 改之前的 HID.touchReport（第 i 個觸點占第 i 槽），只給比對用
private func legacyTouchReport(_ contacts: [HIDContact]) -> Data {
    let fingers = HID.touchContacts, per = 6
    func axis(_ v: Double) -> Int { Int(min(65535, max(0, (v + 0.5).rounded(.down)))) }
    var r = [UInt8](repeating: 0, count: per * fingers)
    for i in 0..<fingers {
        let off = i * per
        r[off] = UInt8(i)
        guard i < contacts.count else { continue }
        let c = contacts[i]
        r[off + 1] = c.down ? 1 : 0
        let x = axis(c.x), y = axis(c.y)
        r[off + 2] = UInt8(x & 0xff); r[off + 3] = UInt8(x >> 8)
        r[off + 4] = UInt8(y & 0xff); r[off + 5] = UInt8(y >> 8)
    }
    return Data(r)
}

private func c(_ id: Int, _ x: Double, _ y: Double, _ down: Bool) -> HIDContact { HIDContact(id: id, x: x, y: y, down: down) }

func runTouchSlotsSuites() {
    suite("touch-single-finger-bytes") {
        // 單指整段（按下、移動、邊界、超界、放開、重複放開、再按）走有狀態的分槽，每一份都跟舊實作逐位元組相同
        let seq: [HIDContact] = [
            c(0, 960.4, 359.5, true), c(0, 961, 360, true), c(0, 0, 0, true), c(0, 1919, 719, true),
            c(0, 1920, 720, true), c(0, -5, -0.6, true), c(0, 70000, 65535.4, true), c(0, 65534.5, 1, true),
            c(0, 100.5, 200, false), c(0, 100.5, 200, false), c(0, 10, 20, true), c(0, 10, 20, false),
        ]
        var slots = HID.TouchSlots()
        var same = true
        for (i, t) in seq.enumerated() {
            let new = slots.report([t]), old = legacyTouchReport([t])
            if new != old { same = false; print("     step \(i): new \(hexs(new)) old \(hexs(old))") }
            if HID.touchReport([t]) != old { same = false; print("     stateless step \(i) differs") }
        }
        expect(same, "單指序列（按下／移動／邊界／超界夾值／放開／重複放開／再按）與 65a643d 逐位元組相同")
        // 寫死的向量（不靠參考實作）
        var s2 = HID.TouchSlots()
        expect(hexs(s2.report([c(0, 960.4, 359.5, true)])) == "0001c0036801010000000000", "單指按下 960.4,359.5")
        expect(hexs(s2.report([c(0, 0, 0, true)])) == "000100000000010000000000", "單指移到 0,0")
        expect(hexs(s2.report([c(0, 70000, -3, true)])) == "0001ffff0000010000000000", "單指超界夾到 65535／0")
        expect(hexs(s2.report([c(0, 100.5, 200, false)])) == "00006500c800010000000000", "單指放開：touch 位 0、保留最後座標（同改之前）")
        expect(hexs(s2.report([c(0, 100.5, 200, false)])) == "00006500c800010000000000", "單指重複放開照舊")
        // 正規化路徑（EventChannel 用的那條）
        var s3 = HID.TouchSlots()
        expect(s3.report(normalized: [(0, 0.25, 0.75, true)], streamWidth: 1920, streamHeight: 720)
               == legacyTouchReport([c(0, 480, 540, true)]), "正規化單指與舊實作相同")
        expect(hexs(s3.report(normalized: [(0, 1, 1, false)], streamWidth: 1920, streamHeight: 720)) == "00008007d002010000000000",
               "正規化單指放開在右下角 1920,720")
        // 舊的無狀態向量照舊
        expect(hexs(HID.touchReport([])) == "000000000000010000000000", "空報告保留槽號")
        expect(hexs(HID.touchReport([c(0, 100.5, 200, false), c(1, -5, 300, true)])) == "00006500c800010100002c01", "舊向量：一放一按")
    }

    suite("touch-two-finger-slots") {
        var s = HID.TouchSlots()
        expect(hexs(s.report([c(0, 100, 200, true), c(1, 300, 400, true)])) == "00016400c80001012c019001", "兩指同時按：0 槽、1 槽")
        expect(hexs(s.report([c(0, 110, 200, true), c(1, 290, 400, true)])) == "00016e00c800010122019001", "兩指各自移動")
        expect(hexs(s.report([c(1, 280, 400, true), c(0, 120, 200, true)])) == "00017800c800010118019001", "觸點順序對調仍依 id 留在原槽")
        expect(hexs(s.report([c(0, 120, 200, false), c(1, 270, 400, true)])) == "00007800c80001010e019001", "第一指先放：0 槽送一次放開、1 槽維持按著")
        expect(hexs(s.report([c(1, 260, 400, true)])) == "000000000000010104019001", "第一指放開後：第二指留在 1 槽，不移到 0 槽")
        expect(hexs(s.report([c(1, 260, 400, false)])) == "000000000000010004019001", "最後一指放開：那一槽 touch 位 0")

        var t = HID.TouchSlots()
        _ = t.report([c(0, 100, 200, true), c(1, 300, 400, true)])
        expect(hexs(t.report([c(0, 100, 200, true), c(1, 300, 400, false)])) == "00016400c80001002c019001", "第二指先放：1 槽送放開、0 槽維持按著")
        expect(hexs(t.report([c(0, 105, 200, true)])) == "00016900c800010000000000", "第二指放開後：0 槽照舊、1 槽空")

        var u = HID.TouchSlots()
        _ = u.report([c(0, 100, 200, true), c(1, 300, 400, true)])
        expect(hexs(u.report([c(0, 100, 200, false), c(1, 300, 400, false)])) == "000000000000010000000000", "兩指一起放開＝全零（槽號保留）")
        expect(hexs(u.report([c(0, 50, 60, true)])) == "000132003c00010000000000", "全放開後下一指從 0 槽開始")

        var v = HID.TouchSlots()
        _ = v.report([c(0, 100, 200, true), c(1, 300, 400, true)])
        expect(hexs(v.report([c(1, 300, 400, true)])) == "00006400c80001012c019001", "前一份按著、這一份沒出現的手指當放開（送一次放開）")
        expect(hexs(v.report([])) == "00000000000001002c019001", "全部消失：最後一指送放開")

        var w = HID.TouchSlots()
        expect(hexs(w.report([c(0, 100, 200, true), c(3, 300, 400, true)])) == "00016400c80001012c019001", "id 不連續（0 與 3）也放進兩槽")
        expect(hexs(w.report([c(0, 100, 200, false), c(3, 310, 400, true)])) == "00006400c800010136019001", "0 先放：id 3 留在 1 槽")
        expect(hexs(w.report([c(3, 320, 400, true)])) == "000000000000010140019001", "之後 id 3 仍在 1 槽")
        expect(hexs(w.report([c(5, 10, 20, true), c(3, 320, 400, true)])) == "00010a001400010140019001", "新的 id 5 拿空出來的 0 槽")

        var x = HID.TouchSlots()
        expect(hexs(x.report([c(2, 10, 20, true), c(7, 30, 40, true)])) == "00010a00140001011e002800", "兩個都超出槽號範圍的 id 依序放兩槽")
        expect(hexs(x.report([c(2, 10, 20, true), c(7, 30, 40, true), c(9, 50, 60, true)])) == "00010a00140001011e002800", "第三指被忽略")

        var y = HID.TouchSlots()
        expect(hexs(y.report([c(0, 1, 2, true), c(1, 3, 4, true), c(2, 5, 6, true)])) == "000101000200010103000400", "同一份三指：第三指被忽略")
        expect(hexs(y.report([c(2, 5, 6, true), c(0, 1, 2, true), c(1, 3, 4, true)])) == "000101000200010103000400", "第三指排在前面也不搶槽")
        var z = HID.TouchSlots()
        expect(hexs(z.report([c(2, 5, 6, true), c(1, 3, 4, true), c(0, 1, 2, true)])) == "000101000200010103000400", "同一份新手指：id 0、1 優先拿自己的槽")
    }

    suite("touch-pet-message") {
        // 桌寵 VideoPipeline.sendTouch（單指）與 sendTouches（兩指實驗）送出的格式
        let one = #"{"type":"touch","contacts":[{"id":0,"x":0.25000,"y":0.75000,"down":true}]}"#
        let p1 = HID.touchContacts(forPetMessage: one)
        expect(p1?.count == 1 && p1?[0].id == 0 && p1?[0].x == 0.25 && p1?[0].y == 0.75 && p1?[0].down == true, "單指訊息照舊解析")
        let up = HID.touchContacts(forPetMessage: #"{"type":"touch","contacts":[{"id":0,"x":1.20000,"y":-0.10000,"down":false}]}"#)
        expect(up?.count == 1 && up?[0].x == 1 && up?[0].y == 0 && up?[0].down == false, "單指放開、座標夾到 0...1")
        let noDown = HID.touchContacts(forPetMessage: #"{"type":"touch","contacts":[{"x":0.5,"y":0.5}]}"#)
        expect(noDown?.count == 1 && noDown?[0].id == 0 && noDown?[0].down == false, "沒有 id／down：id 用位置、down 當 false")
        let two = #"{"type":"touch","contacts":[{"id":0,"x":0.10000,"y":0.20000,"down":true},{"id":1,"x":0.30000,"y":0.40000,"down":true}]}"#
        let p2 = HID.touchContacts(forPetMessage: two)
        expect(p2?.count == 2 && p2?[1].id == 1 && p2?[1].x == 0.3 && p2?[1].y == 0.4 && p2?[1].down == true, "兩指訊息回兩個觸點")
        let three = #"{"type":"touch","contacts":[{"id":0,"x":0.1,"y":0.1,"down":true},{"id":3,"x":0.2,"y":0.2,"down":true},{"id":4,"x":0.3,"y":0.3,"down":true}]}"#
        let p3 = HID.touchContacts(forPetMessage: three)
        expect(p3?.count == HID.touchContacts && p3?.map(\.id) == [0, 3], "多於槽數只取前兩個")
        expect(HID.touchContacts(forPetMessage: #"{"type":"knob","command":"select"}"#) == nil, "不是觸控訊息回 nil")
        expect(HID.touchContacts(forPetMessage: #"{"type":"touch","contacts":[]}"#) == nil, "沒有觸點回 nil")
        expect(HID.touchContacts(forPetMessage: #"{"type":"touch","contacts":[{"id":0,"x":0.5}]}"#) == nil, "缺 y 的觸點略過，沒得用回 nil")
        // 桌寵兩指送法 → 解析 → 分槽：放開時兩個觸點一起 down=false → 全零
        var s = HID.TouchSlots()
        let down = s.report(normalized: p2!, streamWidth: 1000, streamHeight: 1000)
        let lift = HID.touchContacts(forPetMessage: two.replacingOccurrences(of: "true", with: "false"))!
        expect(hexs(down) == "00016400c80001012c019001" && hexs(s.report(normalized: lift, streamWidth: 1000, streamHeight: 1000)) == "000000000000010000000000",
               "桌寵兩指探驗：按下兩槽、放開全零")
    }
}

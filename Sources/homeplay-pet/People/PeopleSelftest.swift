import CoreImage
import Foundation

// 「谁在看」纯逻辑自检（--selftest 会调）。真相机、真人脸的录脸与比对没法在这里测，见交接说明。

func peopleSelftest(_ check: (Bool, String) -> Void) {
    let version = FaceModelProfile.visionFeaturePrintVersion
    func unit(_ degrees: Double, dim: Int = 8) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[0] = Float(cos(degrees * .pi / 180)); v[1] = Float(sin(degrees * .pi / 180))
        return v
    }
    func tpl(_ v: [Float], _ seq: Double, _ ver: String? = nil) -> FaceTemplate {
        FaceTemplate(embedding: v, modelVersion: ver ?? version, enrolledAt: seq)
    }
    let threshold = FaceModelProfile.visionFeaturePrint.similarityThreshold
    check(PeopleVisionEmbedder.modelVersion == version, "谁在看：嵌入器的模型版本串和阈值表一字不差")
    check(threshold == 0.92 && !FaceModelProfile.visionFeaturePrint.calibrated, "谁在看：默认阈值 0.92，未标定")

    // --- 模板编码与版本钉死
    do {
        let a = [tpl(unit(0), 1), tpl(unit(10), 2)]
        let data = FaceTemplateSet.encode(a, modelVersion: version)
        check(data != nil && FaceTemplateSet.decode(data!, modelVersion: version) == a, "模板：编码再解码原样")
        check(FaceTemplateSet.decode(data!, modelVersion: "other-model").isEmpty, "模板：版本不同的整组作废")
        check(FaceTemplateSet.storedModelVersion(data!) == version, "模板：能只读出文件里的模型版本")
        check(FaceTemplateSet.decode(Data("junk".utf8), modelVersion: version).isEmpty, "模板：坏数据当没有")
        let nan = [FaceTemplate(embedding: [.nan, 1], modelVersion: version, enrolledAt: 1)]
        check(FaceTemplateSet.encode(nan, modelVersion: version) == nil, "模板：非有限数不编码")
        let many = (1...25).map { tpl(unit(Double($0)), Double($0)) }
        let kept = FaceTemplateSet.appending(many, to: [], modelVersion: version)
        check(kept.count == FaceTemplateSet.capacity && kept.last?.enrolledAt == 25, "模板：只留最近 20 条")
        check(FaceTemplateSet.nextEnrollmentSequence(after: a, modelVersion: version) == 3, "模板：录入序号接在最大值后面")
    }

    // --- 两道阈值、多人、版本
    do {
        // A 在 0°，B 在 40°（最近一次）：平均在 20°。0° 的脸对平均过线（cos20=0.94），对最近一次不过（cos40=0.77）
        let owner = PersonTemplates(id: "o", isOwner: true, templates: [tpl(unit(0), 1), tpl(unit(40), 2)])
        let m = FaceMatcher(people: [owner])
        if case .matched = m.match(unit(20), modelVersion: version) {} else { check(false, "比对：平均和最近一次都过线才认") }
        check(m.match(unit(0), modelVersion: version) == .mismatch, "比对：只过平均、没过最近一次，不认（两道阈值缺一不可）")
        check(m.match(unit(55), modelVersion: version) == .mismatch, "比对：只过最近一次、没过平均，不认")
        check(m.match(unit(90), modelVersion: version) == .mismatch, "比对：不像的脸不认")
        check(m.match(unit(20), modelVersion: "other-model") == .noReference, "比对：模型版本不同的模板不参与")
        let old = FaceMatcher(people: [PersonTemplates(id: "o", isOwner: true, templates: [tpl(unit(0), 1, "old-model")])])
        check(old.match(unit(0), modelVersion: version) == .noReference, "比对：旧版本的模板，新版本的脸只当没有参照")
        check(FaceMatcher(people: []).match(unit(0), modelVersion: version) == .noReference, "比对：没人录过")
        var bad = FaceMatchTuning(); bad.modelProfiles[version] = FaceModelProfile(modelVersion: version, similarityThreshold: 0, calibrated: false)
        let strict = FaceMatcher(people: [PersonTemplates(id: "o", isOwner: true, templates: [tpl(unit(0), 1)])], tuning: bad)
        check(strict.match(unit(0), modelVersion: version) == .mismatch, "比对：阈值不合法一律不认")
        bad.modelProfiles[version] = FaceModelProfile(modelVersion: version, similarityThreshold: .nan, calibrated: false)
        check(FaceMatcher(people: [], tuning: bad).tuning.similarityThreshold(for: version) == nil, "比对：NaN 阈值作废")
        check(FaceMatchTuning().similarityThreshold(for: "unlisted") == 0.6, "比对：没登记的版本沿用默认 0.6")

        let two = FaceMatcher(people: [PersonTemplates(id: "a", isOwner: true, templates: [tpl(unit(0), 1)]),
                                       PersonTemplates(id: "b", isOwner: false, templates: [tpl(unit(60), 1)])])
        check(two.match(unit(2), modelVersion: version) == .matched(id: "a", score: FaceMatcher.cosine(unit(2), unit(0))!), "比对：多人取最像的那位")
        check({ if case .matched(let id, _) = two.match(unit(58), modelVersion: version) { id == "b" } else { false } }(), "比对：认出另一位家人")
        let twins = FaceMatcher(people: [PersonTemplates(id: "a", isOwner: true, templates: [tpl(unit(0), 1)]),
                                         PersonTemplates(id: "b", isOwner: false, templates: [tpl(unit(1), 1)])])
        check(twins.match(unit(0.5), modelVersion: version) == .mismatch, "比对：两个人几乎一样时分不出，不认")
        check(two.isOwner("a") && !two.isOwner("b"), "比对：谁是主人")
    }

    // --- 谁在看：2 秒规则、1 秒迟滞、连续 2 帧、帧号去重
    do {
        let o = [tpl(unit(0), 1), tpl(unit(2), 2)]
        let matcher = FaceMatcher(people: [PersonTemplates(id: "o", isOwner: true, templates: o),
                                           PersonTemplates(id: "k", isOwner: false, templates: [tpl(unit(70), 1)])])
        var seq: UInt64 = 0
        func frame(_ t: Double, _ emb: [Float]?, width: Double = 0.3, gen: UInt64 = 1, sequence: UInt64? = nil) -> ViewerFrame {
            seq += 1
            return ViewerFrame(cameraID: "c", generation: gen, sequence: sequence ?? seq, capturedAt: t, modelVersion: version,
                               faces: [ViewerFrame.Face(widthFraction: width, embedding: emb)])
        }
        let none = { (t: Double) -> ViewerFrame in seq += 1; return ViewerFrame(cameraID: "c", generation: 1, sequence: seq, capturedAt: t, modelVersion: version, faces: []) }
        let me = unit(1), stranger = unit(135), mate = unit(70)
        var tr = ViewerTracker(matcher: matcher)

        tr.receive(frame(0, me))
        check(tr.viewer == .nobody, "谁在看：第一帧匹配不算（要连续 2 帧）")
        tr.receive(frame(0.25, me))
        check(tr.viewer == .nobody, "谁在看：认出后还要稳 1 秒才换（0.25 s 时还是没人）")
        tr.receive(frame(1.0, me))
        check(tr.viewer == .nobody, "谁在看：稳了 0.75 s 还不换")
        tr.receive(frame(1.25, me))
        check(tr.viewer == .owner("o"), "谁在看：稳满 1 秒换成主人")

        // 一帧误判不换人
        tr.receive(frame(1.5, stranger)); tr.receive(frame(1.75, me)); tr.receive(frame(2.0, me))
        check(tr.viewer == .owner("o"), "谁在看：偶尔一帧认错不换人")
        // 2 秒规则：认错连续 2 秒才算访客，再稳 1 秒才换
        var t = 10.0
        for _ in 0..<7 { tr.receive(frame(t, stranger)); t += 0.25 }   // 10.0 … 11.5
        check(tr.viewer == .owner("o"), "谁在看：认错不满 2 秒，保持原来的人")
        check(tr.contradictsOwner, "谁在看：不像主人的证据满 0.5 秒，个人内容的门先关")
        tr.receive(frame(12.0, stranger))   // 第 2.0 秒：结论变访客，开始数 1 秒
        check(tr.viewer == .owner("o"), "谁在看：2 秒时结论是访客，但还要稳 1 秒")
        tr.receive(frame(12.75, stranger))
        check(tr.viewer == .owner("o"), "谁在看：访客结论只稳了 0.75 s")
        tr.receive(frame(13.0, stranger))
        check(tr.viewer == .guest, "谁在看：认错 2 秒 + 稳 1 秒，换成访客")
        check(!tr.contradictsOwner, "谁在看：不是主人时没有「不像主人」的标记")
        // 认错中途主人回来：计时清零
        t = 20.0
        for _ in 0..<4 { tr.receive(frame(t, stranger)); t += 0.25 }
        tr.receive(frame(t, me)); t += 0.25; tr.receive(frame(t, me)); t += 0.25
        for _ in 0..<5 { tr.receive(frame(t, stranger)); t += 0.25 }   // 又一轮不满 2 秒的认错
        check(tr.viewer == .guest, "谁在看：主人回来过，认错的计时从头数")
        // 回到主人
        for _ in 0..<8 { tr.receive(frame(t, me)); t += 0.25 }
        check(tr.viewer == .owner("o"), "谁在看：访客走了主人坐回来，稳 1 秒后换回主人")
        // 其他家人
        for _ in 0..<8 { tr.receive(frame(t, mate)); t += 0.25 }
        check(tr.viewer == .known("k"), "谁在看：认出已登记的家人")
        // 没人：脸不见稳 1 秒
        tr.receive(none(t)); t += 0.5
        check(tr.viewer == .known("k"), "谁在看：脸刚不见，先保持")
        tr.receive(none(t)); t += 0.5; tr.receive(none(t)); t += 0.5; tr.receive(none(t))
        check(tr.viewer == .nobody, "谁在看：脸不见满 1 秒，换成没人")
        // 窄脸（路人）不算
        var tr2 = ViewerTracker(matcher: matcher)
        for i in 0..<8 { tr2.receive(frame(Double(i) * 0.25, me, width: 0.1)) }
        check(tr2.viewer == .nobody, "谁在看：宽度不到 0.18 的脸是路人，不算")
        // 特征算不出：当没人
        for i in 8..<16 { tr2.receive(frame(Double(i) * 0.25, nil)) }
        check(tr2.viewer == .nobody, "谁在看：没特征的脸不拿来认人")
        // 帧号去重
        var tr3 = ViewerTracker(matcher: matcher)
        tr3.receive(frame(0, me, sequence: 5)); tr3.receive(frame(0.25, me, sequence: 5))
        tr3.receive(frame(1.5, me, sequence: 4)); tr3.receive(frame(1.75, me, sequence: 5))
        check(tr3.viewer == .nobody, "谁在看：同号或更早的帧不重复计数")
        tr3.receive(frame(2.0, me, sequence: 6)); tr3.receive(frame(3.25, me, sequence: 7))
        check(tr3.viewer == .owner("o"), "谁在看：新帧号照常计数")
        // 换了一路相机：部分匹配清零
        var tr4 = ViewerTracker(matcher: matcher)
        tr4.receive(frame(0, me, gen: 1, sequence: 1)); tr4.receive(frame(0.25, me, gen: 2, sequence: 1))
        tr4.receive(frame(1.5, me, gen: 2, sequence: 2))
        check(tr4.viewer == .nobody, "谁在看：换了一路相机，连续匹配从头数")
        // 没有任何人录过：脸只会是访客
        var tr5 = ViewerTracker(matcher: FaceMatcher(people: []))
        for i in 0..<16 { tr5.receive(frame(Double(i) * 0.25, me)) }
        check(tr5.viewer == .guest, "谁在看：没人录过脸，有脸就是访客")
    }

    // --- 个人内容的门
    do {
        check(WhoIsLooking.gate(viewer: .owner("o"), contradictsOwner: false, requirePhone: false, phonePresent: nil), "个人内容：主人看着就开")
        check(!WhoIsLooking.gate(viewer: .owner("o"), contradictsOwner: true, requirePhone: false, phonePresent: nil), "个人内容：出现不像主人的证据就关")
        check(!WhoIsLooking.gate(viewer: .known("k"), contradictsOwner: false, requirePhone: false, phonePresent: true), "个人内容：别的家人看着不开")
        check(!WhoIsLooking.gate(viewer: .guest, contradictsOwner: false, requirePhone: false, phonePresent: true), "个人内容：访客不开")
        check(!WhoIsLooking.gate(viewer: .owner("o"), contradictsOwner: false, requirePhone: true, phonePresent: nil), "个人内容：要求 iPhone 却不知道在不在，关")
        check(WhoIsLooking.gate(viewer: .owner("o"), contradictsOwner: false, requirePhone: true, phonePresent: true), "个人内容：iPhone 在旁边才开")
    }

    // --- 录脸流程
    do {
        func quality(yaw: Double = 0, faces: Int = 1) -> FaceQualitySample {
            var q = FaceQualitySample(faceCount: faces, faceWidth: 0.3)
            q.yaw = yaw; q.pitch = 0; q.eyeOpenness = 0.3; q.captureQuality = 0.8; q.brightness = 0.5; q.centerOffset = 0.05; q.motion = 0.01
            return q
        }
        var s: UInt64 = 0
        func frame(_ t: Double, yaw: Double = 0, emb: [Float]? = unit(0), faces: Int = 1, gen: UInt64 = 1, ver: String? = nil) -> FaceEnrollmentFrame {
            s += 1
            return FaceEnrollmentFrame(cameraID: "c", generation: gen, sequence: s, capturedAt: t, quality: quality(yaw: yaw, faces: faces),
                                       modelVersion: ver ?? version, embedding: emb)
        }
        var f = FaceEnrollmentFlow(modelVersion: version)
        check(f.phase == .framing(hint: nil) && f.wantsCamera, "录脸：从取景开始")
        f.receive(frame(0)); f.receive(frame(0.3))
        check({ if case .framing = f.phase { true } else { false } }(), "录脸：画质门要连续 0.5 秒才过")
        f.receive(frame(0.6))
        check(f.phase == .collecting(front: 1, sideA: 0, sideB: 0), "录脸：画质过了开始收正脸")
        f.receive(frame(0.7))
        check(f.phase == .collecting(front: 1, sideA: 0, sideB: 0), "录脸：相隔不到 0.25 秒的帧不收")
        for i in 1...3 { f.receive(frame(0.6 + 0.3 * Double(i), emb: unit(Double(i)))) }
        check(f.phase == .collecting(front: 4, sideA: 0, sideB: 0) && f.asksToTurn, "录脸：正脸 4 帧收满，请对方转头")
        f.receive(frame(2.0, yaw: 0.3, emb: unit(25)))
        f.receive(frame(2.3, yaw: 0.3, emb: unit(26)))
        check(f.phase == .collecting(front: 4, sideA: 2, sideB: 0), "录脸：一侧的转头帧收 2 帧")
        f.receive(frame(2.6, yaw: 0.3, emb: unit(27)))
        check(f.phase == .collecting(front: 4, sideA: 2, sideB: 0), "录脸：同一侧收满后不再多收")
        f.receive(frame(2.9, yaw: -0.3, emb: unit(-25)))
        f.receive(frame(3.2, yaw: -0.3, emb: unit(-26)))
        check(f.phase == .saving, "录脸：两侧都收满，轮到写文件")
        let save = f.takeSave()
        check(save?.templates.count == 8 && save?.modelVersion == version, "录脸：共 8 条模板")
        check(save.map { Set($0.templates.map(\.enrolledAt)).count == 8 } == true, "录脸：录入序号各不相同")
        check(f.takeSave() == nil, "录脸：要写的那一组只交一次")
        f.didSave(true, total: 8)
        check(f.phase == .saved(total: 8) && f.progress == 1, "录脸：写好了")

        // 第二张脸 / 不一致 → 整轮重来
        var g = FaceEnrollmentFlow(modelVersion: version)
        g.receive(frame(0)); g.receive(frame(0.6)); g.receive(frame(0.9))
        g.receive(frame(1.2, faces: 2))
        check(g.phase == .framing(hint: .onlyOneFace) && g.restarts == 1, "录脸：冒出第二张脸，整轮重来并提示")
        var h = FaceEnrollmentFlow(modelVersion: version)
        h.receive(frame(0)); h.receive(frame(0.6)); h.receive(frame(0.9, emb: unit(90)))
        check(h.phase == .framing(hint: .holdStill) && h.lastRestart == .inconsistent, "录脸：正脸和第一帧不像，整轮重来")
        // 侧脸不像：只是不收
        var k = FaceEnrollmentFlow(modelVersion: version)
        k.receive(frame(0)); k.receive(frame(0.6))
        k.receive(frame(1.0, yaw: 0.3, emb: unit(100)))
        check(k.phase == .collecting(front: 1, sideA: 0, sideB: 0), "录脸：侧脸太不像就不收，也不重来")
        // 超时
        var tmo = FaceEnrollmentFlow(modelVersion: version)
        tmo.receive(frame(0)); tmo.receive(frame(0.6)); tmo.receive(frame(31, emb: unit(1)))
        check(tmo.phase == .ended(.timedOut), "录脸：30 秒没收够正脸，作废")
        var part = FaceEnrollmentFlow(modelVersion: version)
        part.receive(frame(0)); part.receive(frame(0.6))
        for i in 1...3 { part.receive(frame(0.6 + 0.3 * Double(i), emb: unit(Double(i)))) }
        part.receive(frame(31, emb: unit(1)))
        check(part.phase == .saving && part.takeSave()?.templates.count == 4, "录脸：正脸够了、侧脸没收齐，时限到了用已有的存")
        // 换相机 / 取消 / 不支持的模型
        var cam = FaceEnrollmentFlow(modelVersion: version)
        cam.receive(frame(0)); cam.receive(frame(0.3, gen: 2))
        check(cam.phase == .ended(.cameraLost), "录脸：相机换了或重开，作废")
        var cancel = FaceEnrollmentFlow(modelVersion: version)
        cancel.receive(frame(0)); cancel.end(.cancelled)
        check(cancel.phase == .ended(.cancelled) && !cancel.wantsCamera && cancel.takeSave() == nil, "录脸：取消后什么都不留")
        check(FaceEnrollmentFlow(modelVersion: "unlisted").phase == .ended(.unsupportedModel), "录脸：没有阈值的模型不录")
        // 版本不同的帧不收
        var ver = FaceEnrollmentFlow(modelVersion: version)
        ver.receive(frame(0)); ver.receive(frame(0.6, ver: "other")); ver.receive(frame(0.9, ver: "other"))
        check(ver.phase == .collecting(front: 0, sideA: 0, sideB: 0), "录脸：模型版本不同的帧不收")
    }

    // --- 画质门与被动线索
    do {
        var gate = FaceQualityGate(mode: .enrollment)
        var q = FaceQualitySample(faceCount: 1, faceWidth: 0.1)
        check(gate.rawHint(for: q) == .moveCloser, "画质：脸太小提示靠近")
        q.faceWidth = 0.7
        check(gate.rawHint(for: q) == .moveBack, "画质：录脸时脸太大提示离远")
        q.faceWidth = 0.3; q.yaw = 0.5
        check(gate.rawHint(for: q) == .lookAtCamera, "画质：录脸要正脸")
        q.yaw = 0; q.brightness = 0.05
        check(gate.rawHint(for: q) == .tooDark, "画质：太暗")
        q.brightness = 0.5
        check(gate.rawHint(for: q) == nil && !gate.evaluate(q, at: 0).passed && gate.evaluate(q, at: 0.6).passed, "画质：录脸档要连续 0.5 秒才过")
        var cues = FaceVetoCues()
        let face = FaceCueRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3)
        for _ in 0..<2 { cues.observe(FaceCueFrame(face: face, glareFraction: 0.1, rectangles: nil)) }
        check(cues.verdict == .noObjection, "线索：反光只有 2 帧不否决")
        cues.observe(FaceCueFrame(face: face, glareFraction: 0.1, rectangles: nil))
        check(cues.verdict == .veto(.glare), "线索：反光连续 3 帧否决")
        cues.observe(FaceCueFrame(face: face, glareFraction: 0, rectangles: nil))
        check(cues.verdict == .veto(.glare), "线索：否决锁存，好帧不撤销")
        let window = (0..<5).map { NoseParallaxSample(yaw: Double($0 - 2) * 0.15, noseOffset: tan(Double($0 - 2) * 0.15) * 0.5) }
        check(FaceParallax.isConfirmed(window: window), "线索：鼻子视差随转头变化，算有立体感")
        check(FaceCaptureSampling.stats(pixels: [250, 250, 250, 255, 250, 250, 250, 255])?.glareRatio == 1, "画质：近白像素算反光")
    }

    // --- 名册：上限、持久化、权限、删除
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homeplay-people-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func perms(_ url: URL) -> Int? { (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue }
        let r = PeopleRegistry(directory: dir, ownerName: { "Owner Test" })
        check(r.people.count == 1 && r.owner?.isOwner == true && r.owner?.name == "Owner Test", "名册：第 1 位是主人，名字取自系统用户名")
        for i in 1..<PeopleRegistry.maxPeople { _ = try? r.add(name: "Member\(i)") }
        check(r.people.count == 6 && !r.canAddPerson, "名册：最多 6 人")
        check({ do { _ = try r.add(name: "OneMore"); return false } catch { return (error as? PeopleError) == .limitReached } }(), "名册：第 7 个被拒绝")
        check({ do { _ = try r.add(name: "  "); return false } catch { return true } }(), "名册：空名字被拒绝")
        check(Set(r.people.map(\.colorIndex)).count == 6, "名册：6 人的头像配色各不相同")
        let guestPerson = r.people[1]
        let ts = [tpl(unit(0), 1), tpl(unit(5), 2)]
        try? r.saveTemplates(ts, for: r.owner!.id)
        let tfile = dir.appendingPathComponent("templates-\(r.owner!.id).json")
        check(perms(tfile) == 0o600, "存储：模板文件权限 0600")
        check(perms(dir) == 0o700, "存储：目录权限 0700")
        check(perms(dir.appendingPathComponent("people.json")) == 0o600, "存储：名册文件权限 0600")
        check(r.templates(for: r.owner!.id) == ts && r.faceDataState(r.owner!.id) == .enrolled, "存储：模板读得回来")
        let r2 = PeopleRegistry(directory: dir, ownerName: { "Other" })
        check(r2.people == r.people && r2.templates(for: r.owner!.id) == ts, "存储：重开后名册和模板都在，主人名字不被覆盖")
        check(r2.matcherInput().count == 1 && r2.matcherInput()[0].isOwner, "存储：只有录过脸的人进比对器")
        check({ do { try r.remove(r.owner!.id); return false } catch { return (error as? PeopleError) == .isOwner } }(), "名册：主人删不掉")
        try? r.saveTemplates(ts, for: guestPerson.id)
        try? r.remove(guestPerson.id)
        check(r.people.count == 5 && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("templates-\(guestPerson.id).json").path), "名册：删一个人，他的脸部数据一起删")
        if let old = FaceTemplateSet.encode([tpl(unit(0), 1, "old-model")], modelVersion: "old-model") {
            let id = r.people[1].id
            FileManager.default.createFile(atPath: dir.appendingPathComponent("templates-\(id).json").path, contents: old, attributes: [.posixPermissions: 0o600])
            check(r.faceDataState(id) == .staleModel && r.templates(for: id).isEmpty, "存储：旧模型版本的模板不参与，提示重新录制")
        }
        let removed = r.deleteAllFaceData()
        check(removed >= 2 && !r.hasAnyFaceData && r.templates(for: r.owner!.id).isEmpty && r.people.count == 5, "存储：删除所有脸部数据，名册留着")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("templates-") || $0.hasPrefix(".tmp-") }
        check(leftovers.isEmpty, "存储：目录里没有残留的模板文件")
        try? "[1,2".write(to: dir.appendingPathComponent("people.json"), atomically: true, encoding: .utf8)
        let r3 = PeopleRegistry(directory: dir, ownerName: { "Rebuilt" })
        check(r3.people.count == 1 && r3.owner?.name == "Rebuilt", "名册：名册文件坏了，重建主人，不猜")
        check(Person(id: "x", name: "  alice", colorIndex: 0, isOwner: false).initial == "A", "头像：取名字的第一个字")
    }

    // --- Vision 特征：几何，再在合成图上真跑一次
    do {
        let crop = PeopleVisionEmbedder.crop(boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.25), imageSize: CGSize(width: 640, height: 480), eyeLineAngle: 0.1)
        check(crop != nil && abs(crop!.side - 128 * 1.3) < 0.01, "嵌入：裁切外扩 1.3 倍")
        check(PeopleVisionEmbedder.crop(boundingBox: CGRect(x: 0, y: 0, width: 0.01, height: 0.01), imageSize: CGSize(width: 640, height: 480), eyeLineAngle: 0) == nil, "嵌入：太小的脸不裁")
        check(!PeopleVisionEmbedder.poseAcceptable(yaw: 0.8, pitch: 0) && PeopleVisionEmbedder.poseAcceptable(yaw: 0.3, pitch: 0.1), "嵌入：头太偏不给特征")
        check(PeopleVisionEmbedder.l2Normalized([3, 4]) == [0.6, 0.8] && PeopleVisionEmbedder.l2Normalized([0, 0]) == nil, "嵌入：L2 归一化")
        if PeopleVisionEmbedder.isSupported {
            let img = CIImage(color: CIColor(red: 0.8, green: 0.6, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
            let v = PeopleVisionEmbedder().embed(image: img, crop: PeopleVisionEmbedder.Crop(center: CGPoint(x: 320, y: 240), side: 200, angle: 0))
            check(v != nil && (v?.count ?? 0) > 0, "嵌入：Vision 特征在合成图上跑得起来")
            if let v { check(abs(v.reduce(0) { $0 + $1 * $1 } - 1) < 1e-3, "嵌入：输出已归一化") }
        }
    }
}

// 通話與 Siri（體驗改善計劃 §五）：回音消除開關、Siri 按住說話、來電卡電話鍵
import AVFoundation
import Foundation
import Session

func runPhoneSuites() {
    suite("phone-aec") {
        expect(MicUplink.wantsVoiceProcessing(audioType: "telephony", environment: [:]), "100/telephony → voice processing")
        expect(MicUplink.wantsVoiceProcessing(audioType: "speechRecognition", environment: [:]), "100/speechRecognition → voice processing")
        expect(!MicUplink.wantsVoiceProcessing(audioType: "default", environment: [:]), "100/default → raw mic")
        expect(!MicUplink.wantsVoiceProcessing(audioType: nil, environment: [:]), "no audioType → raw mic")
        expect(!MicUplink.wantsVoiceProcessing(audioType: "telephony", environment: ["HOMEPLAY_NO_AEC": "1"]),
               "HOMEPLAY_NO_AEC=1 turns it off")
        // 引擎沒起之前：下行不接手，播放器照舊自己放
        let mic = MicUplink(codec: .pcm, key: Data(count: 32), payloadType: 100, sampleRate: 24000,
                            frameMs: 20, bitrate: 48000, host: "127.0.0.1", port: 9,
                            voiceProcessing: true, downlinkRate: 24000, downlinkChannels: 1)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 480)!
        buf.frameLength = 480
        expect(mic.voiceProcessing && !mic.playDownlink(buf), "voice-processing mic declines downlink before its engine runs")
        expect(mic.description.contains("回音消除"), "mic description says echo cancellation is on")
    }

    suite("phone-siri-hold") {
        expect(SiriAction.parse(#"{"type":"siri"}"#) == .click, "legacy siri message = click")
        expect(SiriAction.parse(#"{"type":"siri","action":"down"}"#) == .down, "siri down")
        expect(SiriAction.parse(#"{"type":"siri","action":"up"}"#) == .up, "siri up")
        var k = SiriKeyState()
        expect(k.press(.down, live: true) == [2], "live: key down → siriAction 2 only")
        expect(k.press(.up, live: true) == [3], "live: key up → siriAction 3")
        expect(k.press(.up, live: true) == [], "stray key up is ignored")
        expect(k.press(.click, live: true) == [2, 3], "click → 2 then 3")
        k = SiriKeyState()
        expect(k.press(.down, live: false) == [], "not live: down is held back")
        expect(k.becameLive() == [2], "live while still held → send down")
        expect(k.press(.up, live: true) == [3], "then release → up")
        k = SiriKeyState()
        _ = k.press(.down, live: false)
        _ = k.press(.up, live: false)
        expect(k.becameLive() == [2, 3], "released before live → one click on RECORD")
        expect(k.becameLive() == [], "pending is consumed once")
        k = SiriKeyState()
        _ = k.press(.up, live: false)
        expect(k.becameLive() == [], "up alone before live sends nothing")
    }

    suite("phone-telephony-hid") {
        expect(HID.telephonyButton(forPetMessage: #"{"type":"telephony","command":"answer"}"#) == .hookSwitch, "answer → hookSwitch")
        expect(HID.telephonyButton(forPetMessage: #"{"type":"telephony","command":"decline"}"#) == .drop, "decline → drop")
        expect(HID.telephonyButton(forPetMessage: #"{"type":"telephony","command":"hangup"}"#) == .drop, "hang up → drop")
        expect(HID.telephonyButton(forPetMessage: #"{"type":"media","command":"answer"}"#) == nil, "other message types ignored")
        expect(HID.telephonyReport(HID.TelephonyButton.hookSwitch.rawValue) != HID.telephonyReport(0), "hookSwitch report differs from release")
        expect(HID.telephonyReport(HID.TelephonyButton.drop.rawValue) != HID.telephonyReport(HID.TelephonyButton.hookSwitch.rawValue),
               "drop and hookSwitch reports differ")
    }
}

import Testing
import Foundation
@testable import BrowserCore

@Suite struct MediaSessionTests {
    @Test func parsesAReport() throws {
        let json = #"{"title":"Un titre","artist":"Quelqu'un","artwork":"https://x/y.jpg","position":12.5,"duration":200,"paused":false,"video":true,"pip":false}"#
        let info = try #require(MediaInfo.parse(json))
        #expect(info.title == "Un titre" && info.artist == "Quelqu'un" && info.hasVideo && !info.paused)
        #expect(info.progress == 12.5 / 200)
        #expect(info.artwork == "https://x/y.jpg")
    }

    @Test func nothingPlayingGivesNil() {
        #expect(MediaInfo.parse(#"{"none":true}"#) == nil)
        #expect(MediaInfo.parse("not json") == nil)
    }

    @Test func aLiveStreamHasNoProgress() {
        let live = MediaInfo(position: 5, duration: .infinity)
        #expect(live.isLive && live.progress == nil)
        #expect(MediaInfo(duration: 0).isLive)
        #expect(MediaPolicy.clock(5, live: true) == "direct")
    }

    @Test func shortSoundsAreNotWorthACard() {
        #expect(!MediaPolicy.isWorthShowing(MediaInfo(position: 1, duration: 3), playing: true))
        #expect(MediaPolicy.isWorthShowing(MediaInfo(position: 1, duration: 200), playing: true))
        #expect(MediaPolicy.isWorthShowing(MediaInfo(position: 50, duration: 200, paused: true), playing: false))   // paused midway: still there
        #expect(!MediaPolicy.isWorthShowing(MediaInfo(position: 0, duration: 200, paused: true), playing: false))   // never started
        #expect(MediaPolicy.isWorthShowing(MediaInfo(duration: .infinity), playing: true))
    }

    @Test func clockFormats() {
        #expect(MediaPolicy.clock(187) == "3:07")
        #expect(MediaPolicy.clock(3723) == "1:02:03")
        #expect(MediaPolicy.clock(.nan) == "direct")
    }

    @Test func readsBluetoothBatteryFromTheProfiler() {
        let json = """
        {"SPBluetoothDataType":[{"device_connected":[
          {"AirPods de Nolhan":{"device_minorType":"Headphones","device_batteryLevelLeft":"85%","device_batteryLevelRight":"80%","device_batteryLevelCase":"90%"}},
          {"Casque":{"device_batteryLevelMain":"55%"}},
          {"Clavier":{}}
        ],"device_not_connected":[{"Vieux":{"device_batteryLevelMain":"1%"}}]}]}
        """
        let devices = BluetoothAudioDevice.parse(profilerJSON: Data(json.utf8))
        #expect(devices.count == 3)
        let pods = devices.first { $0.name == "AirPods de Nolhan" }
        #expect(pods?.shownLevel == 80 && pods?.caseLevel == 90 && pods?.kind == "Headphones")
        #expect(devices.first { $0.name == "Casque" }?.shownLevel == 55)
        #expect(devices.first { $0.name == "Clavier" }?.shownLevel == nil)
        #expect(BluetoothAudioDevice.parse(profilerJSON: Data("x".utf8)).isEmpty)
    }

    @Test func speedCyclesThroughTheLevels() {
        #expect(MediaPolicy.nextRate(after: 1) == 1.25)
        #expect(MediaPolicy.nextRate(after: 2) == 0.5)                // after the fastest: back to the slowest
        #expect(MediaPolicy.nextRate(after: 1.1) == 1.25)             // a page set an odd speed
        #expect(MediaPolicy.nextRate(after: 0.3) == 0.5)
    }

    @Test func speedLabelsUseTheFrenchComma() {
        #expect(MediaPolicy.rateLabel(1) == "1×")
        #expect(MediaPolicy.rateLabel(1.25) == "1,25×")
        #expect(MediaPolicy.rateLabel(0.5) == "0,5×")
        #expect(MediaPolicy.rateLabel(2) == "2×")
    }

    @Test func aReportedSpeedIsKeptSane() throws {
        #expect(MediaInfo.parse(#"{"title":"t","duration":100,"rate":1.5}"#)?.rate == 1.5)
        #expect(MediaInfo.parse(#"{"title":"t","duration":100}"#)?.rate == 1)
        #expect(MediaInfo.parse(#"{"title":"t","duration":100,"rate":0}"#)?.rate == 1)
        #expect(MediaInfo.parse(#"{"title":"t","duration":100,"rate":999}"#)?.rate == 1)
    }
}

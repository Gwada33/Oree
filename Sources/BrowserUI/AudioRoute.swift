import Foundation
import CoreAudio
import BrowserCore

/// Where the sound goes right now (the Mac's speakers, AirPods, a headset…) and, for a Bluetooth device, its battery when it reports one.
///
/// The output comes from CoreAudio and follows changes at once. The battery is not exposed by a public API: it is read from
/// `system_profiler SPBluetoothDataType` (every two minutes while a card is on screen and on each change of output), which gives it for
/// AirPods and for headsets that report it. A device that does not report a battery simply shows none.
@MainActor
final class AudioRoute {
    struct Output: Equatable {
        var name: String
        var bluetooth: Bool
        /// SF Symbol for the device.
        var symbol: String
    }

    private(set) var output = Output(name: "Haut-parleurs", bluetooth: false, symbol: "speaker.wave.2")
    private(set) var batteries: [BluetoothAudioDevice] = []
    var onChange: (() -> Void)?
    private var started = false
    private var batteryTask: Task<Void, Never>?
    private var batteryGeneration = 0

    func start() {
        guard !started else { return }
        started = true
        refreshOutput()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshOutput() }
        }
    }

    /// "AirPods de Nolhan · 80 %" (battery only when known).
    var line: String {
        guard output.bluetooth, let level = battery?.shownLevel else { return output.name }
        return "\(output.name) · \(level) %"
    }

    var battery: BluetoothAudioDevice? { batteries.first { $0.name == output.name } }

    /// Reads the battery now and keeps reading while `isWanted()` stays true (the card is on screen with a Bluetooth output).
    func watchBattery(while isWanted: @escaping @MainActor () -> Bool) {
        guard output.bluetooth, batteryTask == nil else { return }
        batteryGeneration += 1
        let generation = batteryGeneration
        batteryTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, isWanted(), self.output.bluetooth {
                let devices = await Self.readBluetooth()
                guard !Task.isCancelled, generation == self.batteryGeneration else { return }   // another device since: these numbers are stale
                if devices != self.batteries { self.batteries = devices; self.onChange?() }
                try? await Task.sleep(for: .seconds(120))
            }
            // Only the latest loop may clear the handle (an older one finishing late must not forget the new one).
            if let self, generation == self.batteryGeneration { self.batteryTask = nil }
        }
    }

    private func refreshOutput() {
        let fresh = Self.currentOutput()
        guard fresh != output else { return }
        output = fresh
        batteries = []                // another device: what we knew is stale
        batteryGeneration += 1
        batteryTask?.cancel(); batteryTask = nil
        onChange?()
    }

    // MARK: CoreAudio

    private static func currentOutput() -> Output {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else {
            return Output(name: "Haut-parleurs", bluetooth: false, symbol: "speaker.wave.2")
        }
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfName: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &cfName)
        let name = (status == noErr ? cfName?.takeRetainedValue() as String? : nil) ?? "Haut-parleurs"
        var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportSize, &transport)
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        return Output(name: name, bluetooth: bluetooth, symbol: symbol(forName: name, bluetooth: bluetooth, builtIn: transport == kAudioDeviceTransportTypeBuiltIn))
    }

    nonisolated static func symbol(forName name: String, bluetooth: Bool, builtIn: Bool) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if bluetooth { return lower.contains("speaker") || lower.contains("enceinte") ? "hifispeaker" : "headphones" }
        return builtIn ? "laptopcomputer" : "speaker.wave.2"
    }

    private nonisolated static func readBluetooth() async -> [BluetoothAudioDevice] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                process.arguments = ["SPBluetoothDataType", "-json"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { continuation.resume(returning: []); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()    // read before waiting, or a full pipe blocks the tool
                process.waitUntilExit()
                continuation.resume(returning: BluetoothAudioDevice.parse(profilerJSON: data))
            }
        }
    }
}

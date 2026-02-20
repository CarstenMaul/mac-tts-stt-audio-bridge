import AppKit
import Foundation
import SwiftUI

private let kMagic: UInt32 = 0x53415242
private let kVersion: UInt32 = 1

/// Read-only monitor that peeks at ring buffer audio levels without consuming data.
private final class RingMonitor {
    private static let headerBytes = 24

    private var fd: Int32 = -1
    private var mapping: UnsafeMutableRawPointer?
    private var mappingSize: Int = 0
    private var channels: UInt32 = 0
    private var capacityFrames: UInt32 = 0

    deinit {
        close()
    }

    func open(name: String, channels: UInt32, capacityFrames: UInt32) -> Bool {
        close()

        guard !name.isEmpty, channels > 0, capacityFrames > 0 else { return false }

        var pathName = name
        if pathName.hasPrefix("/") { pathName.removeFirst() }
        pathName = pathName.replacingOccurrences(of: "/", with: "_")
        let backingFile = "/tmp/\(pathName).ring"

        let opened = Darwin.open(backingFile, O_RDONLY)
        guard opened >= 0 else { return false }

        let mapSize = Self.headerBytes + Int(channels) * Int(capacityFrames) * MemoryLayout<Float>.size
        let mapped = mmap(nil, mapSize, PROT_READ, MAP_SHARED, opened, 0)
        if mapped == MAP_FAILED {
            Darwin.close(opened)
            return false
        }

        fd = opened
        mapping = mapped
        mappingSize = mapSize
        self.channels = channels
        self.capacityFrames = capacityFrames
        return true
    }

    func close() {
        if let mapping {
            munmap(mapping, mappingSize)
            self.mapping = nil
        }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        mappingSize = 0
        channels = 0
        capacityFrames = 0
    }

    /// Peek at recent samples and return RMS level (0.0 to 1.0).
    func peekLevel(peekFrames: Int = 480) -> Float {
        guard let mapping, channels > 0, capacityFrames > 0 else { return 0 }

        let ptr = mapping.assumingMemoryBound(to: UInt32.self)
        let magic = ptr[0]
        guard magic == kMagic else { return 0 }

        let writeIndex = ptr[4]
        let readIndex = ptr[5]
        let available = writeIndex &- readIndex
        if available == 0 { return 0 }

        let framesToPeek = min(UInt32(peekFrames), min(available, capacityFrames))
        let dataPtr = mapping.advanced(by: Self.headerBytes)
            .bindMemory(to: Float.self, capacity: Int(channels * capacityFrames))

        var sumSq: Float = 0
        let totalChannels = Int(channels)
        let startFrame = writeIndex &- framesToPeek

        for frame in 0..<Int(framesToPeek) {
            let ringFrame = Int((startFrame &+ UInt32(frame)) % capacityFrames)
            let offset = ringFrame * totalChannels
            for ch in 0..<totalChannels {
                let sample = dataPtr[offset + ch]
                sumSq += sample * sample
            }
        }

        let count = Float(framesToPeek) * Float(totalChannels)
        let rms = sqrtf(sumSq / max(count, 1))
        return min(rms, 1.0)
    }

    /// Returns true if the ring header is valid and mapped.
    var isOpen: Bool {
        guard let mapping else { return false }
        let ptr = mapping.assumingMemoryBound(to: UInt32.self)
        return ptr[0] == kMagic
    }
}

@MainActor
final class CompanionViewModel: ObservableObject {
    enum EngineMode: String, CaseIterable, Identifiable {
        case apple
        case elevenlabs

        var id: String { rawValue }
    }

    @Published var host: String = "127.0.0.1"
    @Published var port: String = "8765"
    @Published var mode: EngineMode = .apple
    @Published var status: String = "Disconnected"
    @Published var inputText: String = ""
    @Published var logText: String = ""
    @Published var transcriptText: String = ""
    @Published var sttRunning: Bool = false
    @Published var sessionReady: Bool = false
    @Published var micFeedLevel: Float = 0
    @Published var speakerTapLevel: Float = 0

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var finalTranscriptLines: [String] = []
    private var partialLine: String = ""

    private let micFeedMonitor = RingMonitor()
    private let speakerTapMonitor = RingMonitor()

    init() {
        startLevelMonitoring()
    }

    func connect() {
        disconnect()

        guard let portInt = Int(port),
              let url = URL(string: "ws://\(host):\(portInt)")
        else {
            status = "Invalid host or port"
            return
        }

        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()

        status = "Connected"
        appendLog("[info] connected to \(url.absoluteString)")

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil

        if let socket {
            socket.cancel(with: .goingAway, reason: nil)
            self.socket = nil
        }

        sttRunning = false
        sessionReady = false
        status = "Disconnected"
    }

    func sendText() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let utteranceID = "u-\(Int(Date().timeIntervalSince1970 * 1000))"
        send(["type": "tts_start", "utterance_id": utteranceID])
        send(["type": "tts_chunk", "utterance_id": utteranceID, "text": trimmed])
        send(["type": "tts_flush", "utterance_id": utteranceID])

        appendLog("[tts] sent utterance \(utteranceID)")
    }

    func startSTT() {
        finalTranscriptLines.removeAll()
        partialLine = ""
        transcriptText = ""
        sttRunning = true

        send(["type": "start_stt", "stream_id": "s1", "language": "en-US"])
        appendLog("[stt] start requested")
    }

    func stopSTT() {
        sttRunning = false
        send(["type": "stop_stt", "stream_id": "s1"])
        appendLog("[stt] stop requested")
    }

    func applySessionConfig() {
        sessionReady = false
        send([
            "type": "configure_session",
            "mode": mode.rawValue,
            "stt_source": "virtual_speaker",
            "tts_target": "virtual_mic",
        ])
    }

    private func startLevelMonitoring() {
        _ = micFeedMonitor.open(
            name: "/virtual_audio_bridge_mic_feed",
            channels: 2,
            capacityFrames: 48000
        )
        _ = speakerTapMonitor.open(
            name: "/virtual_audio_bridge_speaker_tap",
            channels: 2,
            capacityFrames: 48000
        )

        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                guard let self else { break }
                let mic = self.micFeedMonitor.peekLevel()
                let spk = self.speakerTapMonitor.peekLevel()
                await MainActor.run {
                    self.micFeedLevel = mic
                    self.speakerTapLevel = spk
                }
            }
        }
    }

    private func send(_ object: [String: Any]) {
        guard let socket,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8)
        else {
            status = "Not connected"
            return
        }

        socket.send(.string(text)) { [weak self] error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.appendLog("[error] send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func receiveLoop() async {
        guard let socket else { return }

        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let text: String
                switch message {
                case .string(let s):
                    text = s
                case .data(let d):
                    text = String(data: d, encoding: .utf8) ?? ""
                @unknown default:
                    text = ""
                }

                if text.isEmpty { continue }
                handleIncomingJSON(text)
            } catch {
                appendLog("[error] receive failed: \(error.localizedDescription)")
                status = "Disconnected"
                sttRunning = false
                sessionReady = false
                break
            }
        }
    }

    private func handleIncomingJSON(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any]
        else {
            appendLog("[raw] \(text)")
            return
        }

        let type = (dict["type"] as? String) ?? ""

        switch type {
        case "ready":
            appendLog("[info] bridge ready")
            applySessionConfig()
        case "session_config_applied":
            let mode = (dict["mode"] as? String) ?? "unknown"
            sessionReady = true
            appendLog("[info] session mode applied: \(mode)")
        case "tts_status":
            let id = (dict["utterance_id"] as? String) ?? "?"
            let st = (dict["status"] as? String) ?? "?"
            let msg = (dict["message"] as? String) ?? ""
            appendLog("[tts] \(id) \(st) \(msg)")
        case "tts_alignment":
            break // silent
        case "stt_partial":
            partialLine = (dict["text"] as? String) ?? ""
            refreshTranscript()
        case "stt_final":
            if let text = dict["text"] as? String, !text.isEmpty {
                finalTranscriptLines.append(text)
            }
            partialLine = ""
            refreshTranscript()
        case "error", "engine_error":
            let code = (dict["code"] as? String) ?? "unknown"
            let message = (dict["message"] as? String) ?? ""
            appendLog("[error] \(code): \(message)")
        case "heartbeat", "engine_ready":
            break // silent
        default:
            appendLog("[event] \(type.isEmpty ? "raw" : type)")
        }
    }

    private func refreshTranscript() {
        var lines: [String] = []
        lines.append(contentsOf: finalTranscriptLines)
        if !partialLine.isEmpty {
            lines.append("... \(partialLine)")
        }
        transcriptText = lines.joined(separator: "\n")
    }

    private func appendLog(_ line: String) {
        if logText.isEmpty {
            logText = line
        } else {
            logText += "\n\(line)"
        }
    }
}

final class BridgeCompanionAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

struct AudioLevelBar: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 100, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * CGFloat(min(level * 5, 1.0))))
                }
            }
            .frame(height: 12)
            Text(String(format: "%.3f", level))
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 50, alignment: .leading)
        }
    }

    private var barColor: Color {
        let scaled = level * 5
        if scaled > 0.8 { return .red }
        if scaled > 0.5 { return .yellow }
        return .green
    }
}

struct ContentView: View {
    @StateObject private var viewModel = CompanionViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Connection row
            HStack(spacing: 8) {
                TextField("Host", text: $viewModel.host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                TextField("Port", text: $viewModel.port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)

                Picker("Mode", selection: $viewModel.mode) {
                    ForEach(CompanionViewModel.EngineMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Button("Connect") { viewModel.connect() }
                Button("Disconnect") { viewModel.disconnect() }
                Button("Apply Mode") { viewModel.applySessionConfig() }
            }

            HStack(spacing: 6) {
                Text("Status: \(viewModel.status)")
                    .font(.caption)
                if viewModel.sessionReady {
                    Text("Engine Ready")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            // Audio levels
            VStack(spacing: 4) {
                AudioLevelBar(label: "Mic Feed", level: viewModel.micFeedLevel)
                AudioLevelBar(label: "Speaker Tap", level: viewModel.speakerTapLevel)
            }
            .padding(.vertical, 4)

            // TTS input
            Text("TTS Input")
                .font(.headline)
            TextEditor(text: $viewModel.inputText)
                .frame(minHeight: 60, maxHeight: 80)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))

            // Buttons
            HStack {
                Button("Send TTS") { viewModel.sendText() }
                    .disabled(!viewModel.sessionReady)
                Spacer().frame(width: 20)
                Button(viewModel.sttRunning ? "Stop STT" : "Start STT") {
                    if viewModel.sttRunning {
                        viewModel.stopSTT()
                    } else {
                        viewModel.startSTT()
                    }
                }
                .disabled(!viewModel.sessionReady && !viewModel.sttRunning)
                .foregroundColor(viewModel.sttRunning ? .red : .primary)
                if viewModel.sttRunning {
                    Text("STT active")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            // STT Transcript
            HStack {
                Text("STT Transcript")
                    .font(.headline)
                Spacer()
                if !viewModel.transcriptText.isEmpty {
                    Button("Clear") {
                        viewModel.transcriptText = ""
                    }
                    .font(.caption)
                }
            }
            TextEditor(text: .constant(viewModel.transcriptText))
                .frame(minHeight: 100)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                    viewModel.sttRunning ? Color.green.opacity(0.6) : Color.gray.opacity(0.3),
                    lineWidth: viewModel.sttRunning ? 2 : 1
                ))

            // Log
            HStack {
                Text("Log")
                    .font(.headline)
                Spacer()
                if !viewModel.logText.isEmpty {
                    Button("Clear") {
                        viewModel.logText = ""
                    }
                    .font(.caption)
                }
            }
            TextEditor(text: .constant(viewModel.logText))
                .frame(minHeight: 120)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
        }
        .padding(14)
        .frame(minWidth: 920, minHeight: 720)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct BridgeCompanionApp: App {
    @NSApplicationDelegateAdaptor(BridgeCompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Bridge Companion") {
            ContentView()
        }
    }
}

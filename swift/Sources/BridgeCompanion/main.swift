import AppKit
import Foundation
import SwiftUI

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
    @Published var outputText: String = ""

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var finalTranscriptLines: [String] = []
    private var partialLine: String = ""

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
        appendOutput("[info] connected to \(url.absoluteString)")

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

        status = "Disconnected"
    }

    func sendText() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let utteranceID = "u-\(Int(Date().timeIntervalSince1970 * 1000))"
        send([
            "type": "tts_start",
            "utterance_id": utteranceID,
        ])
        send([
            "type": "tts_chunk",
            "utterance_id": utteranceID,
            "text": trimmed,
        ])
        send([
            "type": "tts_flush",
            "utterance_id": utteranceID,
        ])

        appendOutput("[tts] sent utterance \(utteranceID)")
    }

    func startSTT() {
        send([
            "type": "start_stt",
            "stream_id": "s1",
            "language": "en-US",
        ])
        appendOutput("[stt] start requested")
    }

    func stopSTT() {
        send([
            "type": "stop_stt",
            "stream_id": "s1",
        ])
        appendOutput("[stt] stop requested")
    }

    func applySessionConfig() {
        send([
            "type": "configure_session",
            "mode": mode.rawValue,
            "stt_source": "virtual_speaker",
            "tts_target": "virtual_mic",
        ])
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
                    self.appendOutput("[error] send failed: \(error.localizedDescription)")
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
                appendOutput("[error] receive failed: \(error.localizedDescription)")
                status = "Disconnected"
                break
            }
        }
    }

    private func handleIncomingJSON(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any]
        else {
            appendOutput("[raw] \(text)")
            return
        }

        let type = (dict["type"] as? String) ?? ""

        switch type {
        case "ready":
            appendOutput("[info] bridge ready")
            applySessionConfig()
        case "session_config_applied":
            let mode = (dict["mode"] as? String) ?? "unknown"
            appendOutput("[info] session mode applied: \(mode)")
        case "tts_status":
            let id = (dict["utterance_id"] as? String) ?? "?"
            let status = (dict["status"] as? String) ?? "?"
            let msg = (dict["message"] as? String) ?? ""
            appendOutput("[tts] \(id) \(status) \(msg)")
        case "tts_alignment":
            appendOutput("[tts] alignment event received")
        case "stt_partial":
            partialLine = (dict["text"] as? String) ?? ""
            refreshTranscriptOutput()
        case "stt_final":
            if let text = dict["text"] as? String, !text.isEmpty {
                finalTranscriptLines.append(text)
            }
            partialLine = ""
            refreshTranscriptOutput()
        case "error", "engine_error":
            let code = (dict["code"] as? String) ?? "unknown"
            let message = (dict["message"] as? String) ?? ""
            appendOutput("[error] \(code): \(message)")
        default:
            appendOutput("[event] \(type.isEmpty ? "raw" : type)")
        }
    }

    private func refreshTranscriptOutput() {
        var lines: [String] = []
        lines.append(contentsOf: finalTranscriptLines.map { "[final] \($0)" })
        if !partialLine.isEmpty {
            lines.append("[partial] \(partialLine)")
        }
        outputText = lines.joined(separator: "\n")
    }

    private func appendOutput(_ line: String) {
        if outputText.isEmpty {
            outputText = line
        } else {
            outputText += "\n\(line)"
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

struct ContentView: View {
    @StateObject private var viewModel = CompanionViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

                Button("Connect") {
                    viewModel.connect()
                }
                Button("Disconnect") {
                    viewModel.disconnect()
                }
                Button("Apply Mode") {
                    viewModel.applySessionConfig()
                }
            }

            Text("Status: \(viewModel.status)")
                .font(.caption)

            Text("Input")
                .font(.headline)
            TextEditor(text: $viewModel.inputText)
                .frame(minHeight: 100)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))

            HStack {
                Button("Send TTS") {
                    viewModel.sendText()
                }
                Button("Start STT") {
                    viewModel.startSTT()
                }
                Button("Stop STT") {
                    viewModel.stopSTT()
                }
            }

            Text("Output")
                .font(.headline)
            TextEditor(text: $viewModel.outputText)
                .frame(minHeight: 240)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
        }
        .padding(14)
        .frame(minWidth: 920, minHeight: 620)
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

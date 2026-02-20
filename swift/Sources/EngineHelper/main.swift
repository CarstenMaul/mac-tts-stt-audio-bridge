import AVFAudio
import Foundation
import Speech

import Darwin

private let kMagic: UInt32 = 0x53415242
private let kVersion: UInt32 = 1

private final class LineEmitter {
    private let lock = NSLock()

    func emit(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

private final class SharedMemoryAudioRing {
    private static let headerBytes = 24

    private var fd: Int32 = -1
    private var mapping: UnsafeMutableRawPointer?
    private var mappingSize: Int = 0
    private var channels: UInt32 = 0
    private var capacityFrames: UInt32 = 0
    private let lock = NSLock()

    deinit {
        close()
    }

    func open(name: String, create: Bool, channels: UInt32, capacityFrames: UInt32) -> Bool {
        close()

        guard !name.isEmpty, channels > 0, capacityFrames > 0 else {
            return false
        }

        var pathName = name
        if pathName.hasPrefix("/") {
            pathName.removeFirst()
        }
        pathName = pathName.replacingOccurrences(of: "/", with: "_")
        let backingFile = "/tmp/\(pathName).ring"

        let flags = create ? (O_CREAT | O_RDWR) : O_RDWR
        let opened = Darwin.open(backingFile, flags, S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH)
        guard opened >= 0 else {
            return false
        }
        // Force permissions regardless of umask so both the driver (_coreaudiod)
        // and user-space helper can read and write the ring.
        fchmod(opened, S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH)

        let mapSize = Self.headerBytes + Int(channels) * Int(capacityFrames) * MemoryLayout<Float>.size
        if ftruncate(opened, off_t(mapSize)) != 0 {
            Darwin.close(opened)
            return false
        }

        let mapped = mmap(nil, mapSize, PROT_READ | PROT_WRITE, MAP_SHARED, opened, 0)
        if mapped == MAP_FAILED {
            Darwin.close(opened)
            return false
        }

        fd = opened
        mapping = mapped
        mappingSize = mapSize
        self.channels = channels
        self.capacityFrames = capacityFrames

        if create || headerValue(at: 0) != kMagic || headerValue(at: 1) != kVersion ||
            headerValue(at: 2) != channels || headerValue(at: 3) != capacityFrames
        {
            memset(mapped, 0, mapSize)
            setHeaderValue(at: 0, value: kMagic)
            setHeaderValue(at: 1, value: kVersion)
            setHeaderValue(at: 2, value: channels)
            setHeaderValue(at: 3, value: capacityFrames)
            setHeaderValue(at: 4, value: 0)
            setHeaderValue(at: 5, value: 0)
        }

        return true
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }

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

    func write(interleavedFrames: [Float], sampleOffset: Int = 0, frameCount: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }

        guard let mapping, frameCount > 0, channels > 0, capacityFrames > 0 else {
            return 0
        }

        let writeIndex = headerValue(at: 4)
        let readIndex = headerValue(at: 5)
        let used = writeIndex &- readIndex
        let freeFrames = capacityFrames &- min(used, capacityFrames)
        let writable = min(UInt32(frameCount), freeFrames)
        if writable == 0 {
            return 0
        }

        let totalChannels = Int(channels)
        let dataPtr = mapping.advanced(by: Self.headerBytes).bindMemory(to: Float.self, capacity: Int(channels * capacityFrames))

        for frame in 0 ..< Int(writable) {
            let dstFrame = Int((writeIndex &+ UInt32(frame)) % capacityFrames)
            let srcOffset = sampleOffset + frame * totalChannels
            let dstOffset = dstFrame * totalChannels
            for ch in 0 ..< totalChannels {
                dataPtr[dstOffset + ch] = interleavedFrames[srcOffset + ch]
            }
        }

        setHeaderValue(at: 4, value: writeIndex &+ writable)
        return Int(writable)
    }

    func read(frameCount: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        guard let mapping, frameCount > 0, channels > 0, capacityFrames > 0 else {
            return []
        }

        let writeIndex = headerValue(at: 4)
        let readIndex = headerValue(at: 5)
        let available = min(writeIndex &- readIndex, capacityFrames)
        let readable = min(UInt32(frameCount), available)
        if readable == 0 {
            return []
        }

        let totalChannels = Int(channels)
        var output = [Float](repeating: 0, count: Int(readable) * totalChannels)
        let dataPtr = mapping.advanced(by: Self.headerBytes).bindMemory(to: Float.self, capacity: Int(channels * capacityFrames))

        for frame in 0 ..< Int(readable) {
            let srcFrame = Int((readIndex &+ UInt32(frame)) % capacityFrames)
            let srcOffset = srcFrame * totalChannels
            let dstOffset = frame * totalChannels
            for ch in 0 ..< totalChannels {
                output[dstOffset + ch] = dataPtr[srcOffset + ch]
            }
        }

        setHeaderValue(at: 5, value: readIndex &+ readable)
        return output
    }

    private func headerValue(at index: Int) -> UInt32 {
        guard let mapping else { return 0 }
        let ptr = mapping.assumingMemoryBound(to: UInt32.self)
        return ptr[index]
    }

    private func setHeaderValue(at index: Int, value: UInt32) {
        guard let mapping else { return }
        let ptr = mapping.assumingMemoryBound(to: UInt32.self)
        ptr[index] = value
    }
}

private struct EngineConfig {
    var sampleRateHz: Int = 48_000
    var channels: Int = 2
    var ringCapacityFrames: Int = 48_000

    var elevenApiKey: String = ""
    var elevenTtsVoiceID: String = ""
    var elevenTtsModelID: String = "eleven_flash_v2_5"
    var elevenTtsOutputFormat: String = "pcm_48000"
    var elevenSttModelID: String = "scribe_v2_realtime"
    var elevenSttLanguageCode: String = "en"

    var appleLocale: String = "en-US"
    var appleOnDeviceOnly: Bool = true

    var micFeedRingName: String = "/virtual_audio_bridge_mic_feed"
    var speakerTapRingName: String = "/virtual_audio_bridge_speaker_tap"
}

private final class EngineCoordinator {
    private let emitter = LineEmitter()
    private let stateQueue = DispatchQueue(label: "engine_helper.state")

    private var config = EngineConfig()
    private var sessionMode = "apple"
    private var sessionSttSource = "virtual_speaker"
    private var sessionTtsTarget = "virtual_mic"

    private var micRing = SharedMemoryAudioRing()
    private var speakerRing = SharedMemoryAudioRing()

    private var utteranceBuffers: [String: String] = [:]

    private var appleRecognizer: SFSpeechRecognizer?
    private var appleRecognitionTask: SFSpeechRecognitionTask?
    private var appleRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var appleCaptureWorkItem: DispatchWorkItem?
    private var appleSpeechAuthorized = false

    private var elevenSttSocket: URLSessionWebSocketTask?
    private var elevenSttSendWorkItem: DispatchWorkItem?
    private var elevenSttReceiveWorkItem: DispatchWorkItem?
    private var activeSttStreamID: String?

    private var elevenTtsWorkItems: [String: DispatchWorkItem] = [:]
    private var activeSynthesizer: AVSpeechSynthesizer?
    private var ttsConverter: AVAudioConverter?
    private var ttsConverterSourceFormat: AVAudioFormat?

    private var ttsPendingSamples: [Float] = []
    private var ttsPendingOffset: Int = 0
    private let ttsPendingLock = NSLock()
    private var ttsDrainTimer: DispatchSourceTimer?

    private var shouldExit = false

    func run() {
        // Read stdin on a background thread so the main RunLoop stays free
        // for AVSpeechSynthesizer and other framework callbacks.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while let line = readLine() {
                guard let object = parseJSON(line) else {
                    emitError(code: "invalid_json", message: "Failed to parse helper command")
                    continue
                }
                handle(command: object)
                if shouldExit {
                    break
                }
            }

            shutdown()
            CFRunLoopStop(CFRunLoopGetMain())
        }

        // Run the main RunLoop so AVSpeechSynthesizer callbacks are delivered.
        RunLoop.main.run()
    }

    private func parseJSON(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any]
        else {
            return nil
        }
        return dict
    }

    private func handle(command: [String: Any]) {
        let type = (command["type"] as? String) ?? ""

        switch type {
        case "engine_config":
            applyEngineConfig(command)
        case "session_config":
            applySessionConfig(command)
        case "tts_start":
            handleTtsStart(command)
        case "tts_chunk":
            handleTtsChunk(command)
        case "tts_flush":
            handleTtsFlush(command)
        case "tts_cancel":
            handleTtsCancel(command)
        case "start_stt":
            handleSttStart(command)
        case "stop_stt":
            handleSttStop(command)
        case "heartbeat":
            emitter.emit(["type": "engine_ready", "heartbeat": true])
        case "shutdown":
            shouldExit = true
        default:
            emitError(code: "unknown_command", message: "Unknown helper command type: \(type)")
        }
    }

    private func applyEngineConfig(_ command: [String: Any]) {
        var next = config

        if let audio = command["audio"] as? [String: Any] {
            next.sampleRateHz = audio["sample_rate_hz"] as? Int ?? next.sampleRateHz
            next.channels = audio["channels"] as? Int ?? next.channels
            next.ringCapacityFrames = audio["ring_capacity_frames"] as? Int ?? next.ringCapacityFrames
        }

        if let eleven = command["elevenlabs"] as? [String: Any] {
            next.elevenApiKey = eleven["api_key"] as? String ?? next.elevenApiKey
            if let tts = eleven["tts"] as? [String: Any] {
                next.elevenTtsVoiceID = tts["voice_id"] as? String ?? next.elevenTtsVoiceID
                next.elevenTtsModelID = tts["model_id"] as? String ?? next.elevenTtsModelID
                next.elevenTtsOutputFormat = tts["output_format"] as? String ?? next.elevenTtsOutputFormat
            }
            if let stt = eleven["stt"] as? [String: Any] {
                next.elevenSttModelID = stt["model_id"] as? String ?? next.elevenSttModelID
                next.elevenSttLanguageCode = stt["language_code"] as? String ?? next.elevenSttLanguageCode
            }
        }

        if let apple = command["apple"] as? [String: Any] {
            next.appleLocale = apple["locale"] as? String ?? next.appleLocale
            next.appleOnDeviceOnly = apple["on_device_only"] as? Bool ?? next.appleOnDeviceOnly
        }

        if let rings = command["rings"] as? [String: Any] {
            next.micFeedRingName = rings["mic_feed"] as? String ?? next.micFeedRingName
            next.speakerTapRingName = rings["speaker_tap"] as? String ?? next.speakerTapRingName
        }

        config = next

        let openedMic = micRing.open(
            name: next.micFeedRingName,
            create: true,
            channels: UInt32(next.channels),
            capacityFrames: UInt32(next.ringCapacityFrames)
        )
        let openedSpeaker = speakerRing.open(
            name: next.speakerTapRingName,
            create: true,
            channels: UInt32(next.channels),
            capacityFrames: UInt32(next.ringCapacityFrames)
        )

        if !openedMic || !openedSpeaker {
            emitError(code: "ring_open_failed", message: "Could not open mmap audio ring files")
            return
        }

        emitter.emit(["type": "engine_ready", "mode": sessionMode])
    }

    private func applySessionConfig(_ command: [String: Any]) {
        if let mode = command["mode"] as? String {
            sessionMode = mode
        }
        if let source = command["stt_source"] as? String {
            sessionSttSource = source
        }
        if let target = command["tts_target"] as? String {
            sessionTtsTarget = target
        }
    }

    private func handleTtsStart(_ command: [String: Any]) {
        guard let utteranceID = command["utterance_id"] as? String, !utteranceID.isEmpty else {
            emitError(code: "missing_utterance_id", message: "tts_start requires utterance_id")
            return
        }
        stateQueue.sync {
            utteranceBuffers[utteranceID] = ""
        }
        emitTtsStatus(utteranceID: utteranceID, status: "queued", message: "queued")
    }

    private func handleTtsChunk(_ command: [String: Any]) {
        guard let utteranceID = command["utterance_id"] as? String,
              let text = command["text"] as? String
        else {
            emitError(code: "invalid_tts_chunk", message: "tts_chunk requires utterance_id and text")
            return
        }

        stateQueue.sync {
            let existing = utteranceBuffers[utteranceID] ?? ""
            utteranceBuffers[utteranceID] = existing + text
        }
    }

    private func handleTtsFlush(_ command: [String: Any]) {
        guard let utteranceID = command["utterance_id"] as? String else {
            emitError(code: "invalid_tts_flush", message: "tts_flush requires utterance_id")
            return
        }

        let text = stateQueue.sync {
            utteranceBuffers.removeValue(forKey: utteranceID) ?? ""
        }

        if text.isEmpty {
            emitTtsStatus(utteranceID: utteranceID, status: "completed", message: "empty utterance")
            return
        }

        if sessionMode == "elevenlabs" {
            runElevenLabsTTS(utteranceID: utteranceID, text: text)
        } else {
            runAppleTTS(utteranceID: utteranceID, text: text)
        }
    }

    private func handleTtsCancel(_ command: [String: Any]) {
        guard let utteranceID = command["utterance_id"] as? String else {
            return
        }

        let workItem = stateQueue.sync { () -> DispatchWorkItem? in
            utteranceBuffers.removeValue(forKey: utteranceID)
            return elevenTtsWorkItems.removeValue(forKey: utteranceID)
        }

        workItem?.cancel()
        emitTtsStatus(utteranceID: utteranceID, status: "completed", message: "cancelled")
    }

    private func handleSttStart(_ command: [String: Any]) {
        let streamID = (command["stream_id"] as? String) ?? "stt-default"
        let language = (command["language"] as? String) ?? config.appleLocale

        if sessionMode == "elevenlabs" {
            startElevenLabsSTT(streamID: streamID, language: language)
        } else {
            startAppleSTT(streamID: streamID, language: language)
        }
    }

    private func handleSttStop(_ command: [String: Any]) {
        let streamID = (command["stream_id"] as? String) ?? activeSttStreamID ?? "stt-default"

        if sessionMode == "elevenlabs" {
            stopElevenLabsSTT(streamID: streamID)
        } else {
            stopAppleSTT(streamID: streamID)
        }
    }

    private func emitError(code: String, message: String) {
        emitter.emit([
            "type": "engine_error",
            "code": code,
            "message": message,
        ])
    }

    private func emitTtsStatus(utteranceID: String, status: String, message: String) {
        emitter.emit([
            "type": "tts_status",
            "utterance_id": utteranceID,
            "status": status,
            "message": message,
        ])
    }

    private func emitSttPartial(streamID: String, text: String) {
        emitter.emit([
            "type": "stt_partial",
            "stream_id": streamID,
            "text": text,
        ])
    }

    private func emitSttFinal(streamID: String, text: String) {
        emitter.emit([
            "type": "stt_final",
            "stream_id": streamID,
            "text": text,
        ])
    }

    private func writeTtsAudioToTarget(_ interleavedStereo: [Float]) {
        guard !interleavedStereo.isEmpty else { return }

        ttsPendingLock.lock()
        ttsPendingSamples.append(contentsOf: interleavedStereo)
        if ttsDrainTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
            timer.schedule(deadline: .now(), repeating: .milliseconds(5))
            timer.setEventHandler { [weak self] in
                self?.drainPendingSamples()
            }
            ttsDrainTimer = timer
            timer.resume()
        }
        ttsPendingLock.unlock()
    }

    private func drainPendingSamples() {
        ttsPendingLock.lock()
        defer { ttsPendingLock.unlock() }

        let remaining = ttsPendingSamples.count - ttsPendingOffset
        guard remaining > 0 else {
            ttsPendingSamples.removeAll(keepingCapacity: true)
            ttsPendingOffset = 0
            ttsDrainTimer?.cancel()
            ttsDrainTimer = nil
            return
        }

        let channels = max(config.channels, 1)
        let frameCount = remaining / channels
        guard frameCount > 0 else { return }

        let written: Int
        switch sessionTtsTarget {
        case "virtual_speaker":
            written = speakerRing.write(interleavedFrames: ttsPendingSamples, sampleOffset: ttsPendingOffset, frameCount: frameCount)
        case "both":
            let w1 = micRing.write(interleavedFrames: ttsPendingSamples, sampleOffset: ttsPendingOffset, frameCount: frameCount)
            let w2 = speakerRing.write(interleavedFrames: ttsPendingSamples, sampleOffset: ttsPendingOffset, frameCount: frameCount)
            written = min(w1, w2)
        default:
            written = micRing.write(interleavedFrames: ttsPendingSamples, sampleOffset: ttsPendingOffset, frameCount: frameCount)
        }

        if written > 0 {
            ttsPendingOffset += written * channels
        }

        // Compact when more than half consumed
        if ttsPendingOffset > ttsPendingSamples.count / 2 && ttsPendingOffset > 0 {
            ttsPendingSamples.removeFirst(ttsPendingOffset)
            ttsPendingOffset = 0
        }
    }

    private func sourceRingForSTT() -> SharedMemoryAudioRing {
        return sessionSttSource == "virtual_mic" ? micRing : speakerRing
    }

    private func runAppleTTS(utteranceID: String, text: String) {
        emitTtsStatus(utteranceID: utteranceID, status: "started", message: "apple tts started")

        let synthesizer = AVSpeechSynthesizer()
        activeSynthesizer = synthesizer
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: config.appleLocale)

        synthesizer.write(utterance) { [weak self] buffer in
            guard let self else { return }

            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                self.activeSynthesizer = nil
                self.emitTtsStatus(utteranceID: utteranceID, status: "completed", message: "apple tts completed")
                return
            }

            let converted = self.convertBufferToBridgeFormat(buffer: pcm)
            self.writeTtsAudioToTarget(converted)
        }
    }

    private func startAppleSTT(streamID: String, language: String) {
        stopAppleSTT(streamID: streamID)

        if !appleSpeechAuthorized {
            let semaphore = DispatchSemaphore(value: 0)
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                self?.appleSpeechAuthorized = (status == .authorized)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5)
        }

        guard appleSpeechAuthorized else {
            emitError(code: "speech_not_authorized", message: "Speech recognition authorization denied")
            return
        }

        let locale = Locale(identifier: language)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            emitError(code: "speech_locale_unsupported", message: "Could not create recognizer for locale \(language)")
            return
        }

        if config.appleOnDeviceOnly && !recognizer.supportsOnDeviceRecognition {
            emitError(code: "speech_on_device_unavailable", message: "On-device speech recognition unavailable")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = config.appleOnDeviceOnly

        appleRecognizer = recognizer
        appleRecognitionRequest = request
        activeSttStreamID = streamID

        appleRecognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    self.emitSttFinal(streamID: streamID, text: text)
                } else {
                    self.emitSttPartial(streamID: streamID, text: text)
                }
            }
            if let error {
                self.emitError(code: "apple_stt_error", message: error.localizedDescription)
            }
        }

        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem { [weak self] in
            guard let self, let workItem else { return }
            let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

            while !workItem.isCancelled {
                let ringFrames = self.sourceRingForSTT().read(frameCount: 480)
                if ringFrames.isEmpty {
                    usleep(20_000)
                    continue
                }

                let mono16k = Self.downmixAndResampleTo16k(interleavedStereo48k: ringFrames)
                if mono16k.isEmpty {
                    usleep(10_000)
                    continue
                }

                guard let pcm = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(mono16k.count)),
                      let channelData = pcm.floatChannelData
                else {
                    continue
                }
                pcm.frameLength = AVAudioFrameCount(mono16k.count)
                mono16k.withUnsafeBufferPointer { ptr in
                    channelData[0].update(from: ptr.baseAddress!, count: mono16k.count)
                }
                request.append(pcm)
            }
        }
        appleCaptureWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem!)
    }

    private func stopAppleSTT(streamID: String) {
        appleCaptureWorkItem?.cancel()
        appleCaptureWorkItem = nil

        appleRecognitionRequest?.endAudio()
        appleRecognitionTask?.cancel()
        appleRecognitionTask = nil
        appleRecognitionRequest = nil
        appleRecognizer = nil

        if activeSttStreamID == streamID {
            activeSttStreamID = nil
        }
    }

    private func runElevenLabsTTS(utteranceID: String, text: String) {
        if config.elevenApiKey.isEmpty {
            emitTtsStatus(utteranceID: utteranceID, status: "error", message: "ELEVENLABS_API_KEY missing")
            return
        }

        emitTtsStatus(utteranceID: utteranceID, status: "started", message: "elevenlabs tts started")

        let cfg = config
        var workItem: DispatchWorkItem?
        workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                let endpoint = "wss://api.elevenlabs.io/v1/text-to-speech/\(cfg.elevenTtsVoiceID)/stream-input"
                guard var components = URLComponents(string: endpoint) else {
                    throw NSError(domain: "engine_helper", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid elevenlabs tts endpoint"])
                }
                components.queryItems = [
                    URLQueryItem(name: "model_id", value: cfg.elevenTtsModelID),
                    URLQueryItem(name: "output_format", value: cfg.elevenTtsOutputFormat),
                ]
                guard let url = components.url else {
                    throw NSError(domain: "engine_helper", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid elevenlabs tts url"])
                }

                var request = URLRequest(url: url)
                request.setValue(cfg.elevenApiKey, forHTTPHeaderField: "xi-api-key")

                let socket = URLSession.shared.webSocketTask(with: request)
                socket.resume()

                try self.wsSendSync(socket, text: Self.serialize([
                    "text": " ",
                    "xi_api_key": cfg.elevenApiKey,
                    "voice_settings": [
                        "stability": 0.5,
                        "similarity_boost": 0.8,
                    ],
                ]))

                try self.wsSendSync(socket, text: Self.serialize([
                    "text": text,
                    "try_trigger_generation": true,
                ]))

                try self.wsSendSync(socket, text: Self.serialize([
                    "text": "",
                    "flush": true,
                ]))

                var sawFinal = false
                while !(workItem?.isCancelled ?? true) && !sawFinal {
                    let message = try self.wsReceiveSync(socket)
                    let textPayload: String
                    switch message {
                    case .string(let payload):
                        textPayload = payload
                    case .data(let data):
                        textPayload = String(data: data, encoding: .utf8) ?? ""
                    @unknown default:
                        textPayload = ""
                    }

                    guard let obj = self.parseJSON(textPayload) else {
                        continue
                    }

                    if let audioBase64 = obj["audio"] as? String,
                       let audioData = Data(base64Encoded: audioBase64)
                    {
                        let interleaved = Self.pcm16MonoToStereoFloat(audioData)
                        self.writeTtsAudioToTarget(interleaved)
                    }

                    if let alignment = obj["alignment"] as? [String: Any] {
                        let chars = alignment["characters"] as? [String] ?? []
                        let starts = alignment["character_start_times_seconds"] as? [Double] ?? []
                        let ends = alignment["character_end_times_seconds"] as? [Double] ?? []
                        let startsMs = starts.map { Int($0 * 1000.0) }
                        let endsMs = ends.map { Int($0 * 1000.0) }
                        self.emitter.emit([
                            "type": "tts_alignment",
                            "utterance_id": utteranceID,
                            "chars": chars,
                            "char_start_ms": startsMs,
                            "char_end_ms": endsMs,
                        ])
                    }

                    if let isFinal = obj["isFinal"] as? Bool, isFinal {
                        sawFinal = true
                    }
                }

                socket.cancel(with: .normalClosure, reason: nil)
                self.emitTtsStatus(utteranceID: utteranceID, status: "completed", message: "elevenlabs tts completed")
            } catch {
                self.emitTtsStatus(utteranceID: utteranceID, status: "error", message: error.localizedDescription)
            }

            _ = self.stateQueue.sync {
                self.elevenTtsWorkItems.removeValue(forKey: utteranceID)
            }
        }

        stateQueue.sync {
            elevenTtsWorkItems[utteranceID] = workItem
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem!)
    }

    private func startElevenLabsSTT(streamID: String, language: String) {
        stopElevenLabsSTT(streamID: streamID)

        if config.elevenApiKey.isEmpty {
            emitError(code: "missing_api_key", message: "ELEVENLABS_API_KEY missing for elevenlabs stt")
            return
        }

        guard var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime") else {
            emitError(code: "invalid_stt_url", message: "Could not create elevenlabs stt endpoint")
            return
        }

        components.queryItems = [
            URLQueryItem(name: "model_id", value: config.elevenSttModelID),
            URLQueryItem(name: "language_code", value: language.isEmpty ? config.elevenSttLanguageCode : language),
        ]

        guard let url = components.url else {
            emitError(code: "invalid_stt_url", message: "Could not create elevenlabs stt url")
            return
        }

        var request = URLRequest(url: url)
        request.setValue(config.elevenApiKey, forHTTPHeaderField: "xi-api-key")

        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()

        elevenSttSocket = socket
        activeSttStreamID = streamID

        var receiveWorkItem: DispatchWorkItem?
        receiveWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                while !(receiveWorkItem?.isCancelled ?? true) {
                    let message = try self.wsReceiveSync(socket)
                    let textPayload: String
                    switch message {
                    case .string(let payload):
                        textPayload = payload
                    case .data(let data):
                        textPayload = String(data: data, encoding: .utf8) ?? ""
                    @unknown default:
                        textPayload = ""
                    }
                    guard let obj = self.parseJSON(textPayload) else { continue }
                    self.processElevenLabsSttEvent(streamID: streamID, event: obj)
                }
            } catch {
                self.emitError(code: "elevenlabs_stt_receive", message: error.localizedDescription)
            }
        }

        var sendWorkItem: DispatchWorkItem?
        sendWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                while !(sendWorkItem?.isCancelled ?? true) {
                    let source = self.sourceRingForSTT().read(frameCount: 480)
                    if source.isEmpty {
                        usleep(20_000)
                        continue
                    }

                    let mono16k = Self.downmixAndResampleTo16k(interleavedStereo48k: source)
                    if mono16k.isEmpty {
                        continue
                    }

                    let pcmData = Self.floatMonoToPCM16(mono16k)
                    let payload = Self.serialize([
                        "audio_base_64": pcmData.base64EncodedString(),
                    ])
                    try self.wsSendSync(socket, text: payload)
                }
            } catch {
                self.emitError(code: "elevenlabs_stt_send", message: error.localizedDescription)
            }
        }

        elevenSttReceiveWorkItem = receiveWorkItem
        elevenSttSendWorkItem = sendWorkItem
        DispatchQueue.global(qos: .utility).async(execute: receiveWorkItem!)
        DispatchQueue.global(qos: .utility).async(execute: sendWorkItem!)
    }

    private func stopElevenLabsSTT(streamID: String) {
        elevenSttSendWorkItem?.cancel()
        elevenSttReceiveWorkItem?.cancel()
        elevenSttSendWorkItem = nil
        elevenSttReceiveWorkItem = nil

        if let socket = elevenSttSocket {
            socket.cancel(with: .normalClosure, reason: nil)
        }
        elevenSttSocket = nil

        if activeSttStreamID == streamID {
            activeSttStreamID = nil
        }
    }

    private func processElevenLabsSttEvent(streamID: String, event: [String: Any]) {
        let type = (event["type"] as? String) ?? (event["message_type"] as? String) ?? ""
        let transcript = (event["text"] as? String) ??
            (event["transcript"] as? String) ??
            ((event["payload"] as? [String: Any])?["text"] as? String) ?? ""

        if transcript.isEmpty {
            return
        }

        let lower = type.lowercased()
        if lower.contains("final") || lower.contains("commit") || lower.contains("complete") {
            emitSttFinal(streamID: streamID, text: transcript)
        } else {
            emitSttPartial(streamID: streamID, text: transcript)
        }
    }

    private func shutdown() {
        ttsPendingLock.lock()
        ttsDrainTimer?.cancel()
        ttsDrainTimer = nil
        ttsPendingSamples.removeAll()
        ttsPendingOffset = 0
        ttsPendingLock.unlock()
        ttsConverter = nil
        ttsConverterSourceFormat = nil

        let ttsWorkItems = stateQueue.sync { () -> [DispatchWorkItem] in
            let values = Array(elevenTtsWorkItems.values)
            elevenTtsWorkItems.removeAll()
            return values
        }

        ttsWorkItems.forEach { $0.cancel() }

        stopAppleSTT(streamID: activeSttStreamID ?? "stt-default")
        stopElevenLabsSTT(streamID: activeSttStreamID ?? "stt-default")

        micRing.close()
        speakerRing.close()
    }

    private static func serialize(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private func wsSendSync(_ socket: URLSessionWebSocketTask, text: String, timeout: TimeInterval = 10) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var sendError: Error?
        socket.send(.string(text)) { error in
            sendError = error
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw NSError(domain: "engine_helper", code: 2001, userInfo: [NSLocalizedDescriptionKey: "websocket send timeout"])
        }
        if let sendError {
            throw sendError
        }
    }

    private func wsReceiveSync(_ socket: URLSessionWebSocketTask, timeout: TimeInterval = 15) throws -> URLSessionWebSocketTask.Message {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<URLSessionWebSocketTask.Message, Error>?
        socket.receive { receiveResult in
            result = receiveResult
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw NSError(domain: "engine_helper", code: 2002, userInfo: [NSLocalizedDescriptionKey: "websocket receive timeout"])
        }
        guard let result else {
            throw NSError(domain: "engine_helper", code: 2003, userInfo: [NSLocalizedDescriptionKey: "websocket receive returned no result"])
        }
        switch result {
        case .success(let message):
            return message
        case .failure(let error):
            throw error
        }
    }

    private func convertBufferToBridgeFormat(buffer: AVAudioPCMBuffer) -> [Float] {
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!

        if buffer.format == targetFormat {
            return Self.readInterleaved(buffer: buffer)
        }

        // Cache the converter so resampler state is preserved across callbacks,
        // eliminating clicks at chunk boundaries.
        if ttsConverter == nil || ttsConverterSourceFormat != buffer.format {
            ttsConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
            ttsConverterSourceFormat = buffer.format
        }
        guard let converter = ttsConverter else {
            return []
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(max(1, Int(Double(buffer.frameLength) * ratio) + 64))
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            return []
        }

        var sourceConsumed = false
        var conversionError: NSError?

        _ = converter.convert(to: outBuffer, error: &conversionError) { _, status in
            if sourceConsumed {
                status.pointee = .noDataNow
                return nil
            }
            sourceConsumed = true
            status.pointee = .haveData
            return buffer
        }

        if conversionError != nil {
            return []
        }

        return Self.readInterleaved(buffer: outBuffer)
    }

    private static func readInterleaved(buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let channels = Int(buffer.format.channelCount)
        let samples = Int(buffer.frameLength) * channels

        guard let mData = buffer.audioBufferList.pointee.mBuffers.mData else {
            return []
        }

        let ptr = mData.bindMemory(to: Float.self, capacity: samples)
        return Array(UnsafeBufferPointer(start: ptr, count: samples))
    }

    private static func downmixAndResampleTo16k(interleavedStereo48k: [Float]) -> [Float] {
        if interleavedStereo48k.isEmpty {
            return []
        }

        let frameCount = interleavedStereo48k.count / 2
        if frameCount == 0 {
            return []
        }

        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0 ..< frameCount {
            let l = interleavedStereo48k[frame * 2]
            let r = interleavedStereo48k[frame * 2 + 1]
            mono[frame] = 0.5 * (l + r)
        }

        let sourceRate = 48_000.0
        let targetRate = 16_000.0
        let ratio = sourceRate / targetRate

        var out: [Float] = []
        out.reserveCapacity(max(1, Int(Double(mono.count) / ratio)))

        var position = 0.0
        while Int(position) < mono.count {
            let i = Int(position)
            let j = min(i + 1, mono.count - 1)
            let frac = Float(position - Double(i))
            out.append(mono[i] * (1.0 - frac) + mono[j] * frac)
            position += ratio
        }

        return out
    }

    private static func floatMonoToPCM16(_ mono: [Float]) -> Data {
        var data = Data(capacity: mono.count * 2)
        for sample in mono {
            let clipped = max(-1.0, min(1.0, sample))
            var s = Int16(clipped * Float(Int16.max))
            withUnsafeBytes(of: &s) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }

    private static func pcm16MonoToStereoFloat(_ data: Data) -> [Float] {
        let sampleCount = data.count / 2
        if sampleCount == 0 {
            return []
        }

        var out = [Float](repeating: 0, count: sampleCount * 2)
        data.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.bindMemory(to: Int16.self)
            for i in 0 ..< sampleCount {
                let value = Float(ptr[i]) / Float(Int16.max)
                out[i * 2] = value
                out[i * 2 + 1] = value
            }
        }
        return out
    }
}

private let coordinator = EngineCoordinator()
coordinator.run()

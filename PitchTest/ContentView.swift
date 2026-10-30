import SwiftUI
import AVFoundation
import UIKit

// Reads the engine status ten times a second. All the audio work is in the C++ engine (Native/pt_engine.mm).
final class EngineModel: ObservableObject {
    @Published var running = false
    @Published var error = ""
    @Published var s = PtStatus()
    @Published var startupInfo = ""
    @Published var recording = false
    @Published var takes: [Take] = []
    @Published var inputs: [AVAudioSessionPortDescription] = []
    @Published var chosenInputUID: String = UserDefaults.standard.string(forKey: "inputUID") ?? ""   // "" = the phone's own mic
    private var timer: Timer?

    init() {
        refreshTakes()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, options: [])   // so the list of inputs includes earbud / headset mics
        refreshInputs()
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshInputs()
        }
    }

    // ---- microphone choice: the phone's own mic, or the earbuds' / headset mic when one is plugged in ----
    func refreshInputs() {
        inputs = AVAudioSession.sharedInstance().availableInputs ?? []
    }

    func isChosen(_ port: AVAudioSessionPortDescription) -> Bool {
        if chosenInputUID.isEmpty { return port.portType == .builtInMic }
        return port.uid == chosenInputUID
    }

    // Applies the choice to the audio session. An unplugged choice falls back to the phone's own mic.
    private func applyInput() {
        let session = AVAudioSession.sharedInstance()
        let avail = session.availableInputs ?? []
        if !chosenInputUID.isEmpty, let p = avail.first(where: { $0.uid == chosenInputUID }) {
            try? session.setPreferredInput(p)
        } else if let builtIn = avail.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }

    // Switching the input restarts the audio engine (a running recording is stopped and saved first).
    func chooseInput(_ port: AVAudioSessionPortDescription) {
        let wasRunning = running
        if wasRunning { stop() }
        chosenInputUID = port.portType == .builtInMic ? "" : port.uid
        UserDefaults.standard.set(chosenInputUID, forKey: "inputUID")
        if wasRunning { start() } else { applyInput() }
        refreshInputs()
    }

    // ---- recording: <name>.wav (raw mic, 16-bit mono 48 kHz) + <name>.csv (one row per detector run) ----
    func recordingsDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func toggleRecord() {
        if recording {
            pt_record_stop()
            recording = false
            refreshTakes()
            return
        }
        guard running else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = recordingsDir().appendingPathComponent("take-" + f.string(from: Date())).path
        if pt_record_start(base) == 0 {
            recording = true
            error = ""
        } else {
            error = "could not start recording (no space or no permission?)"
        }
    }

    func refreshTakes() {
        let dir = recordingsDir()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [Take] = []
        for n in names where n.hasSuffix(".wav") {
            let base = String(n.dropLast(4))
            let wav = dir.appendingPathComponent(n)
            let csv = dir.appendingPathComponent(base + ".csv")
            let size = (try? FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int) ?? 0
            out.append(Take(id: base, wav: wav, csv: csv, wavBytes: size))
        }
        takes = out.sorted { $0.id > $1.id }
    }

    func deleteTake(_ t: Take) {
        try? FileManager.default.removeItem(at: t.wav)
        try? FileManager.default.removeItem(at: t.csv)
        refreshTakes()
    }

    // The phone's own mic by default (an earbud cable mic sits next to the earbuds and can pick the tone up); the
    // Microphone box lets you pick the earbuds' mic instead.
    private func preferBuiltInMic() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, options: [])
        try? session.setPreferredIOBufferDuration(pt_io_buffer_seconds())
        try? session.setActive(true)
        applyInput()
    }

    func start() {
        preferBuiltInMic()
        let r = pt_start()
        if r == 0 {
            // miniaudio sets its own IO buffer while starting, so ask again and then log what iOS really granted.
            try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(pt_io_buffer_seconds())
            startupInfo = sessionSnapshot(prefix: "startup")
            running = true
            error = ""
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                var st = PtStatus()
                pt_get_status(&st)
                self.s = st
            }
        } else {
            error = String(cString: pt_error())
        }
    }

    func stop() {
        if recording { toggleRecord() }
        timer?.invalidate()
        timer = nil
        pt_stop()
        running = false
    }

    // IO buffer + input/output latency as iOS reports them, in milliseconds.
    func deviceLatencyMs() -> (io: Double, input: Double, output: Double) {
        let s = AVAudioSession.sharedInstance()
        return (s.ioBufferDuration * 1000, s.inputLatency * 1000, s.outputLatency * 1000)
    }

    func sessionSnapshot(prefix: String) -> String {
        let d = deviceLatencyMs()
        return String(format: "%@: asked IO buffer %.1f ms, granted %.1f ms, input latency %.1f ms, output latency %.1f ms",
                      prefix, pt_io_buffer_seconds() * 1000, d.io, d.input, d.output)
    }

    // "latency: onset->found X ms, found->tone Y ms, total Z ms (avg, n)". Total adds the iOS session numbers
    // (input latency + output latency + IO buffer) to the engine's own onset->tone measurement.
    func latencyLine(_ s: PtStatus) -> String {
        if s.lat_n == 0 {
            return "latency: no measurement yet (unmute, stay quiet 0.1 s, then sing a note; missed \(s.lat_missed))"
        }
        let d = deviceLatencyMs()
        let device = d.io + d.input + d.output
        let total = Double(s.lat_of_avg_ms + s.lat_ft_avg_ms) + device
        return String(format: "latency: onset\u{2192}found %.1f ms, found\u{2192}tone %.1f ms, device %.1f ms, TOTAL %.1f ms (avg of %llu; last %.1f + %.1f; missed %llu)",
                      s.lat_of_avg_ms, s.lat_ft_avg_ms, device, total, s.lat_n, s.lat_of_last_ms, s.lat_ft_last_ms, s.lat_missed)
    }

    // The audio route as iOS reports it (which mic and which output are really in use).
    func routeInfo() -> String {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        var lines: [String] = []
        for p in route.inputs { lines.append("input: \(p.portName) [\(p.portType.rawValue)]") }
        for p in route.outputs { lines.append("output: \(p.portName) [\(p.portType.rawValue)]") }
        if let pi = session.preferredInput { lines.append("preferred input: \(pi.portName)") }
        let avail = (session.availableInputs ?? []).map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        lines.append("available inputs: \(avail)")
        lines.append(String(format: "session: %.0f Hz, IO buffer %.1f ms, input latency %.1f ms, output latency %.1f ms",
                            session.sampleRate, session.ioBufferDuration * 1000, session.inputLatency * 1000, session.outputLatency * 1000))
        lines.append(String(format: "phone volume: %.2f", session.outputVolume))
        return lines.joined(separator: "\n")
    }

    func events() -> [String] {
        var out: [String] = []
        for i in 0..<10 {
            var buf = [CChar](repeating: 0, count: 64)
            if pt_event(Int32(i), &buf, 64) == 0 { break }
            out.append(String(cString: buf))
        }
        return out
    }

    func report() -> String {
        let s = self.s
        var l: [String] = []
        l.append("PitchTest diagnostics")
        l.append(startupInfo)
        l.append(latencyLine(s))
        l.append(String(format: "analysis window %.1f ms, hop %.2f ms", s.window_ms, s.hop_ms))
        l.append("key \(text(s.key_name)), target \(text(s.target_name)), \(s.muted != 0 ? "MUTED" : "tone on"), level \(String(format: "%.0f", s.gain_db)) dBFS, release \(s.release_ms) ms, chromatic \(s.chromatic), tonic \(s.tonic)")
        l.append(String(format: "mic gate %.0f dBFS", s.gate_db))
        l.append(String(format: "now: %.1f Hz, %+.0f c, clarity %.2f, mic %.0f dBFS, valid %d", s.hz, s.cents, s.clarity, 20.0 * log10(Double(max(s.rms, 1e-6))), s.valid))
        l.append("detection: last \(s.det_last_us) us, avg \(s.det_avg_us) us, max \(s.det_max_us) us, chunk max \(s.chunk_max_us) us, over budget \(s.over_budget) of \(s.chunks)")
        l.append("windows with pitch \(s.valid_n), without \(s.invalid_n), found/lost changes \(s.flips)")
        l.append("target changes \(s.target_changes), tone on \(s.tone_on_events) times, off \(s.tone_off_events) times")
        l.append(String(format: "mic level averaged while tone playing %.1f dBFS, while silent %.1f dBFS", s.rms_db_tone_on, s.rms_db_tone_off))
        l.append(String(format: "callbacks %llu, frames per callback %u..%u, longest gap %.1f ms, late callbacks %llu", s.cb_count, s.cb_frames_min, s.cb_frames_max, s.cb_gap_max_ms, s.cb_late))
        l.append(String(format: "miniaudio buffer capacity (period x periods, NOT a latency): in %.1f ms, out %.1f ms", s.in_buf_ms, s.out_buf_ms))
        if s.leak_state == 3 {
            l.append(String(format: "LEAK TEST: mic with tone OFF %.1f dBFS, with tone ON %.1f dBFS, difference %.1f dB", s.leak_off_db, s.leak_on_db, s.leak_on_db - s.leak_off_db))
        } else if s.leak_state != 0 {
            l.append("LEAK TEST: running")
        } else {
            l.append("LEAK TEST: not run")
        }
        l.append(sessionSnapshot(prefix: "now"))
        l.append(routeInfo())
        l.append("recent events (newest first):")
        l.append(contentsOf: events())
        return l.joined(separator: "\n")
    }

    func copyReport() {
        UIPasteboard.general.string = report()
    }
}

struct Take: Identifiable {
    let id: String      // base file name, e.g. take-20261029-124300
    let wav: URL
    let csv: URL
    let wavBytes: Int
}

struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// The iOS share sheet: Save to Files, AirDrop, Mail, ...
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

private func text<T>(_ tuple: T) -> String {
    // C char arrays arrive in Swift as tuples of Int8; read them as a C string.
    return withUnsafeBytes(of: tuple) { raw -> String in
        let bytes = raw.bindMemory(to: UInt8.self)
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}

struct ContentView: View {
    @StateObject private var m = EngineModel()
    @State private var copied = false
    @State private var share: ShareItem?

    var body: some View {
        let s = m.s
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pitch trainer test").font(.title2).bold()
                Text("Wired headphones only. Keep the level low. It starts muted and quiet.")
                    .font(.footnote).foregroundColor(.secondary)

                Button(m.running ? "Stop" : "Start") { m.running ? m.stop() : m.start() }
                    .buttonStyle(.borderedProminent)
                if !m.error.isEmpty { Text(m.error).foregroundColor(.red) }

                GroupBox("Microphone") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(m.inputs, id: \.uid) { p in
                            Button((m.isChosen(p) ? "\u{2713} " : "") + p.portName + (p.portType == .builtInMic ? " (phone mic)" : " (\(p.portType.rawValue))")) {
                                m.chooseInput(p)
                            }.buttonStyle(.bordered)
                        }
                        if m.inputs.count < 2 {
                            Text("Only the phone mic is available. Plug in headphones with a mic to see them here.")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                        Text("Switching restarts the audio. After switching to an earbud mic, run the Leak test (stay silent) to check it does not hear the tone.")
                            .font(.footnote).foregroundColor(.secondary)
                        Text(m.routeInfo()).font(.footnote)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Record") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(m.recording ? "Recording ... tap to STOP" : "Record: off (tap to start)") { m.toggleRecord() }
                            .buttonStyle(.borderedProminent)
                            .tint(m.recording ? .red : .accentColor)
                            .disabled(!m.running)
                        if m.recording {
                            Text(String(format: "REC %.1f s   dropped samples: %llu", s.rec_seconds, s.rec_dropped))
                                .foregroundColor(.red)
                        } else if !m.running {
                            Text("Press Start first.").font(.footnote).foregroundColor(.secondary)
                        }
                        Text("Saves the raw microphone audio (.wav) and one row per detector run (.csv: time, Hz, clarity, level, found, target, cents, tone on).")
                            .font(.footnote).foregroundColor(.secondary)
                        ForEach(m.takes) { t in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(t.id).font(.system(.footnote, design: .monospaced))
                                    Text(String(format: "%.1f MB audio", Double(t.wavBytes) / 1_000_000)).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Share") { share = ShareItem(urls: [t.wav, t.csv]) }
                                Button("Delete", role: .destructive) { m.deleteTake(t) }
                            }.buttonStyle(.bordered)
                        }
                        if !m.takes.isEmpty {
                            Text("Also in the Files app: On My iPhone > PitchTest > Recordings.").font(.footnote).foregroundColor(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }

                if m.running {
                    GroupBox("Now") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Key: \(text(s.key_name))   Target: \(text(s.target_name))")
                            Text(String(format: "You sing: %.1f Hz  (%+.0f cents)", s.hz, s.cents))
                            Text(String(format: "Mic level: %.0f dBFS   clarity %.2f", 20.0 * log10(Double(max(s.rms, 1e-6))), s.clarity))
                            Text(s.valid != 0 ? "pitch found" : "no pitch")
                                .foregroundColor(s.valid != 0 ? .green : .secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Tone") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(format: "%@   level %.0f dBFS (cap -24)", s.muted != 0 ? "MUTED" : "tone ON", s.gain_db))
                            Text(String(format: "Mic gate: %.0f dBFS. Your voice must be louder than this; room sound quieter than it is ignored.", s.gate_db))
                                .font(.footnote)
                            HStack {
                                Button("More sensitive") { pt_gate_step(0) }
                                Button("Less sensitive") { pt_gate_step(1) }
                            }.buttonStyle(.bordered)
                            HStack {
                                Button(s.muted != 0 ? "Unmute" : "Mute") { pt_set_muted(s.muted != 0 ? 0 : 1) }
                                Button("Quieter") { pt_gain_step(0) }
                                Button("Louder") { pt_gain_step(1) }
                            }.buttonStyle(.bordered)
                            HStack {
                                Button("Release \u{2212}") { pt_release_step(0) }
                                Text("release hold \(s.release_ms) ms").frame(minWidth: 130)
                                Button("Release +") { pt_release_step(1) }
                            }.buttonStyle(.bordered)
                            HStack {
                                Button("Key \u{2212}") { pt_set_key_slot(s.key_slot - 1) }
                                Text(text(s.key_name)).frame(minWidth: 90)
                                Button("Key +") { pt_set_key_slot(s.key_slot + 1) }
                            }.buttonStyle(.bordered)
                            HStack {
                                Button(s.chromatic != 0 ? "Chromatic: ON" : "Chromatic: off") { pt_set_chromatic(s.chromatic != 0 ? 0 : 1) }
                                Button(s.tonic != 0 ? "Tonic: ON" : "Tonic: off") { pt_set_tonic(s.tonic != 0 ? 0 : 1) }
                            }.buttonStyle(.bordered)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Diagnostics (tap Copy report and send it)") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.latencyLine(s)).foregroundColor(.orange)
                            Text(String(format: "Window %.1f ms, hop %.2f ms; detector runs %llu", s.window_ms, s.hop_ms, s.chunks))
                            Text("Detection: avg \(s.det_avg_us) us, max \(s.det_max_us) us; callbacks over their period: \(s.over_budget)")
                            Text("Pitch found \(s.valid_n) windows, none \(s.invalid_n); found/lost changes: \(s.flips)")
                            Text("Target changes: \(s.target_changes); tone on \(s.tone_on_events) / off \(s.tone_off_events) times")
                            Text(String(format: "Mic level while tone plays %.1f dBFS, while silent %.1f dBFS", s.rms_db_tone_on, s.rms_db_tone_off))
                            Text(String(format: "Callbacks %llu, frames %u..%u, longest gap %.1f ms, late %llu", s.cb_count, s.cb_frames_min, s.cb_frames_max, s.cb_gap_max_ms, s.cb_late))
                            Text(String(format: "miniaudio buffer capacity (not a latency): in %.1f ms, out %.1f ms", s.in_buf_ms, s.out_buf_ms)).font(.footnote)
                            Text(m.startupInfo).font(.footnote)
                            Text(m.routeInfo()).font(.footnote)
                            if s.leak_state == 1 { Text("Leak test: STAY SILENT, tone off ...").foregroundColor(.orange) }
                            if s.leak_state == 2 { Text("Leak test: STAY SILENT, tone on ...").foregroundColor(.orange) }
                            if s.leak_state == 3 {
                                Text(String(format: "Leak test: mic tone OFF %.1f dBFS, tone ON %.1f dBFS, difference %.1f dB", s.leak_off_db, s.leak_on_db, s.leak_on_db - s.leak_off_db))
                                    .foregroundColor(.orange)
                            }
                            HStack {
                                Button("Leak test") { pt_leak_test() }
                                Button("Reset counters") { pt_reset_metrics() }
                                Button(copied ? "Copied" : "Copy report") {
                                    m.copyReport()
                                    copied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                                }
                            }.buttonStyle(.bordered)
                            Text("Leak test: stay silent with the earbuds in. It plays a 440 Hz tone at your current level for about 2 seconds, so keep the level low.")
                                .font(.footnote).foregroundColor(.secondary)
                            ForEach(m.events(), id: \.self) { e in
                                Text(e).font(.system(.footnote, design: .monospaced))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
        .sheet(item: $share) { item in ActivityView(items: item.urls) }
    }
}

import SwiftUI
import AVFoundation
import UIKit

// Reads the engine status ten times a second. All the audio work is in the C++ engine (Native/pt_engine.mm).
final class EngineModel: ObservableObject {
    @Published var running = false
    @Published var error = ""
    @Published var s = PtStatus()
    @Published var startupInfo = ""
    private var timer: Timer?

    // Earbuds with a mic in the cable make iOS use THAT mic, which sits next to the earbuds and can pick the tone
    // up (cable crosstalk or leakage). Prefer the phone's own built-in mic.
    private func preferBuiltInMic() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, options: [])
        try? session.setPreferredIOBufferDuration(pt_io_buffer_seconds())
        try? session.setActive(true)
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
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
    }
}

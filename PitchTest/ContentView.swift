import SwiftUI

// Reads the engine status ten times a second. All the audio work is in the C++ engine (Native/pt_engine.mm).
final class EngineModel: ObservableObject {
    @Published var running = false
    @Published var error = ""
    @Published var s = PtStatus()
    private var timer: Timer?

    func start() {
        let r = pt_start()
        if r == 0 {
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

    var body: some View {
        let s = m.s
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pitch trainer test").font(.title2).bold()
                Text("Wired headphones only. Keep them OUT of your ears until the level is low. It starts muted and quiet.")
                    .font(.footnote).foregroundColor(.secondary)

                Button(m.running ? "Stop" : "Start") { m.running ? m.stop() : m.start() }
                    .buttonStyle(.borderedProminent)
                if !m.error.isEmpty { Text(m.error).foregroundColor(.red) }

                if m.running {
                    GroupBox("Now") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Key: \(text(s.key_name))   Target: \(text(s.target_name))")
                            Text(String(format: "You sing: %.1f Hz  (%+.0f cents)", s.hz, s.cents))
                            Text(s.valid != 0 ? "pitch found" : "no pitch")
                                .foregroundColor(s.valid != 0 ? .green : .secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Speed (the 10 ms budget)") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Detection: last \(s.det_last_us) us, average \(s.det_avg_us) us, max \(s.det_max_us) us")
                            Text("Whole 10 ms chunk max: \(s.chunk_max_us) us   Over budget: \(s.over_budget) of \(s.chunks)")
                            Text(String(format: "Device buffers (reported): in %.1f ms, out %.1f ms", s.in_buf_ms, s.out_buf_ms))
                            Text("In: \(text(s.device_in))").font(.footnote)
                            Text("Out: \(text(s.device_out))").font(.footnote)
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
                                Button("Key \u{2212}") { pt_set_key_slot(s.key_slot - 1) }
                                Text(text(s.key_name)).frame(minWidth: 90)
                                Button("Key +") { pt_set_key_slot(s.key_slot + 1) }
                            }.buttonStyle(.bordered)
                            HStack {
                                Button("Release \u{2212}") { pt_release_step(0) }
                                Text("release hold \(s.release_ms) ms").frame(minWidth: 130)
                                Button("Release +") { pt_release_step(1) }
                            }.buttonStyle(.bordered)
                            HStack {
                                Button(s.chromatic != 0 ? "Chromatic: ON" : "Chromatic: off") { pt_set_chromatic(s.chromatic != 0 ? 0 : 1) }
                                Button(s.tonic != 0 ? "Tonic: ON" : "Tonic: off") { pt_set_tonic(s.tonic != 0 ? 0 : 1) }
                            }.buttonStyle(.bordered)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
    }
}

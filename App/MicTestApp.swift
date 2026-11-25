import SwiftUI
import AVFoundation
import UIKit

// Native background-microphone test.
// Checks: does the mic keep recording, does sound play and does the network work
// while the screen is locked or another app is open.

@main
struct MicTestApp: App {
    @StateObject private var tester = Tester()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tester)
        }
    }
}

struct VerdictLine: Identifiable {
    let id = UUID()
    let kind: String   // "ok", "warn", "bad", ""
    let text: String
}

struct Sample {
    let t: Double
    let rms: Float
    let seconds: Double
    let bg: Bool
}

struct Ping {
    let t: Double
    let ok: Bool
    let bg: Bool
}

final class Tester: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var running = false
    @Published var level: Float = 0
    @Published var elapsed: Double = 0
    @Published var status = "Не запущено"
    @Published var verdict: [VerdictLine] = []
    @Published var report = ""
    @Published var isPlaying = false
    @Published var copied = false

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let recordURL = FileManager.default.temporaryDirectory.appendingPathComponent("mic-test.caf")
    private var beepPlayer: AVAudioPlayer?
    private var playback: AVAudioPlayer?
    private var timers: [Timer] = []

    private var t0 = Date()
    private var isBackground = false
    private var bgStart: Double?
    private var bgSegments: [(Double, Double)] = []
    private var samples: [Sample] = []
    private var pings: [Ping] = []
    private var events: [(Double, String)] = []
    private var beepsBg = 0
    private var beepsBgOk = 0
    private var recordedSeconds = 0.0

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(screenLocked),
                       name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        nc.addObserver(self, selector: #selector(interruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(routeChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
    }

    private func now() -> Double { Date().timeIntervalSince(t0) }

    private func log(_ text: String) {
        guard running else { return }
        events.append((now(), text))
    }

    // MARK: - App state

    @objc private func didEnterBackground() {
        DispatchQueue.main.async {
            guard self.running else { return }
            self.isBackground = true
            self.bgStart = self.now()
            self.log("фон: приложение скрыто")
        }
    }

    @objc private func willEnterForeground() {
        DispatchQueue.main.async {
            guard self.running else { return }
            self.isBackground = false
            if let s = self.bgStart { self.bgSegments.append((s, self.now())) }
            self.bgStart = nil
            self.log("экран: приложение снова видно")
        }
    }

    @objc private func screenLocked() {
        DispatchQueue.main.async { self.log("экран заблокирован") }
    }

    @objc private func interruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .began {
                self.log("звук: система прервала аудио")
            } else {
                self.log("звук: прерывание закончилось")
                if self.running && !self.engine.isRunning {
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        try self.engine.start()
                        self.log("звук: запись перезапущена")
                    } catch {
                        self.log("звук: перезапуск не удался — \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    @objc private func routeChange(_ n: Notification) {
        let route = AVAudioSession.sharedInstance().currentRoute
        let ins = route.inputs.map { $0.portName }.joined(separator: ", ")
        let outs = route.outputs.map { $0.portName }.joined(separator: ", ")
        DispatchQueue.main.async { self.log("маршрут звука: вход [\(ins)], выход [\(outs)]") }
    }

    // MARK: - Start / stop

    func start() {
        copied = false
        status = "Запрашиваю микрофон…"
        let handler: (Bool) -> Void = { granted in
            DispatchQueue.main.async {
                if granted { self.begin() } else { self.status = "Нет доступа к микрофону: разреши в Настройках" }
            }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: handler)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(handler)
        }
    }

    private func begin() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            status = "Ошибка аудиосессии: \(error.localizedDescription)"
            return
        }

        samples = []; pings = []; events = []; bgSegments = []; bgStart = nil
        beepsBg = 0; beepsBgOk = 0; recordedSeconds = 0
        verdict = []; report = ""; isBackground = false
        t0 = Date()
        running = true
        log("старт, iOS \(UIDevice.current.systemVersion)")

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            status = "Микрофон недоступен"
            running = false
            return
        }

        try? FileManager.default.removeItem(at: recordURL)
        do {
            file = try AVAudioFile(forWriting: recordURL, settings: format.settings)
        } catch {
            file = nil
            log("файл записи не создан: \(error.localizedDescription)")
        }

        let sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            try? self.file?.write(from: buffer)
            let rms = Tester.rms(buffer)
            let secs = Double(buffer.frameLength) / sampleRate
            DispatchQueue.main.async { self.handle(rms: rms, seconds: secs) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            status = "Запись не запустилась: \(error.localizedDescription)"
            input.removeTap(onBus: 0)
            running = false
            return
        }

        do {
            beepPlayer = try AVAudioPlayer(data: Tester.beepWav())
            beepPlayer?.prepareToPlay()
        } catch {
            log("писк не подготовлен: \(error.localizedDescription)")
        }

        timers = [
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.beep() },
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.ping() },
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.elapsed = self.now()
            }
        ]
        status = "Идёт запись. Теперь заблокируй экран."
    }

    func stop() {
        guard running else { return }
        if let s = bgStart { bgSegments.append((s, now())) }
        bgStart = nil
        log("стоп")
        let duration = now()
        timers.forEach { $0.invalidate() }
        timers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        running = false
        level = 0
        status = "Готово"
        analyse(duration: duration)
    }

    private func handle(rms: Float, seconds: Double) {
        guard running else { return }
        samples.append(Sample(t: now(), rms: rms, seconds: seconds, bg: isBackground))
        recordedSeconds += seconds
        if !isBackground { level = rms }
    }

    private func beep() {
        guard let p = beepPlayer else { return }
        p.currentTime = 0
        let ok = p.play()
        let whereText = isBackground ? "в фоне" : "на экране"
        if isBackground {
            beepsBg += 1
            if ok { beepsBgOk += 1 }
        }
        log("писк \(whereText): \(ok ? "играет" : "НЕ играет")")
    }

    private func ping() {
        let t = now()
        let bg = isBackground
        guard let url = URL(string: "https://kostol023-svg.github.io/mic-test/?ping=\(Int(Date().timeIntervalSince1970))") else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        req.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            let ok = error == nil && ((response as? HTTPURLResponse)?.statusCode ?? 0) < 400
            DispatchQueue.main.async { self?.pings.append(Ping(t: t, ok: ok, bg: bg)) }
        }.resume()
    }

    // MARK: - Analysis

    private func analyse(duration: Double) {
        var lines: [VerdictLine] = []
        let bgTotal = bgSegments.reduce(0) { $0 + ($1.1 - $1.0) }
        let fgLevels = samples.filter { !$0.bg }.map { $0.rms }
        let baseline = Tester.median(fgLevels)
        let threshold = max(Float(0.01), baseline * 4)

        var segTexts: [String] = []
        var anyLoud = false
        var coverageSum = 0.0
        for (i, seg) in bgSegments.enumerated() {
            let inSeg = samples.filter { $0.t >= seg.0 && $0.t <= seg.1 }
            let covered = inSeg.reduce(0) { $0 + $1.seconds }
            let len = max(seg.1 - seg.0, 0.001)
            coverageSum += covered
            let peak = inSeg.map { $0.rms }.max() ?? 0
            if peak > threshold { anyLoud = true }
            var maxGap = 0.0
            for k in 1..<max(inSeg.count, 1) where k < inSeg.count {
                maxGap = max(maxGap, inSeg[k].t - inSeg[k - 1].t)
            }
            let ps = pings.filter { $0.t >= seg.0 && $0.t <= seg.1 }
            segTexts.append(String(format: "Фон №%ld: старт %.1f с, %.1f с, записано %ld%%, пик %.3f, макс. перерыв %.1f с, сеть %ld/%ld",
                                   i + 1, seg.0, len, Int(covered / len * 100), peak, maxGap,
                                   ps.filter { $0.ok }.count, ps.count))
        }

        if bgTotal < 5 {
            lines.append(VerdictLine(kind: "warn", text: String(format: "Приложение почти не было в фоне (%.1f с). Повтори: заблокируй экран хотя бы на 15–20 секунд.", bgTotal)))
        } else {
            let coverage = coverageSum / bgTotal
            if coverage > 0.85 && anyLoud {
                lines.append(VerdictLine(kind: "ok", text: "Микрофон в фоне работал: записано \(Int(coverage * 100))% фонового времени, твой голос слышен."))
            } else if coverage > 0.85 {
                lines.append(VerdictLine(kind: "warn", text: "Микрофон в фоне писал (\(Int(coverage * 100))% времени), но очень тихо. Проверь по записи, слышно ли, как ты считал."))
            } else {
                lines.append(VerdictLine(kind: "bad", text: "Микрофон в фоне вставал на паузу: записано только \(Int(coverage * 100))% фонового времени."))
            }
            if beepsBg > 0 {
                let kind = beepsBgOk == beepsBg ? "ok" : (beepsBgOk > 0 ? "warn" : "bad")
                lines.append(VerdictLine(kind: kind, text: "Звук в фоне: система разрешила \(beepsBgOk) из \(beepsBg) писков. Скажи, слышал ли ты их."))
            }
            let bgPings = pings.filter { $0.bg }
            if bgPings.isEmpty {
                lines.append(VerdictLine(kind: "warn", text: "Сеть в фоне не проверилась."))
            } else {
                let okN = bgPings.filter { $0.ok }.count
                let kind = okN == bgPings.count ? "ok" : (okN > 0 ? "warn" : "bad")
                lines.append(VerdictLine(kind: kind, text: "Интернет в фоне: прошло \(okN) из \(bgPings.count) запросов."))
            }
        }
        lines.append(VerdictLine(kind: "", text: String(format: "Записано всего %.1f с из %.1f с.", recordedSeconds, duration)))
        segTexts.forEach { lines.append(VerdictLine(kind: "", text: $0)) }
        verdict = lines

        var r: [String] = []
        r.append("НАТИВНЫЙ ТЕСТ МИКРОФОНА В ФОНЕ")
        r.append("iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)")
        r.append(String(format: "Длительность %.1f с, в фоне %.1f с, записано %.1f с", duration, bgTotal, recordedSeconds))
        r.append(String(format: "Тишина ~%.3f, порог %.3f", baseline, threshold))
        lines.forEach { r.append("[\($0.kind.isEmpty ? "-" : $0.kind)] \($0.text)") }
        r.append("--- события ---")
        events.forEach { r.append(String(format: "%.1f ", $0.0) + $0.1) }
        report = r.joined(separator: "\n")
    }

    // MARK: - Playback of the recording

    func togglePlayback() {
        if isPlaying {
            playback?.stop()
            isPlaying = false
            return
        }
        do {
            playback = try AVAudioPlayer(contentsOf: recordURL)
            playback?.delegate = self
            playback?.play()
            isPlaying = true
        } catch {
            status = "Запись не открылась: \(error.localizedDescription)"
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.isPlaying = false }
    }

    func copyReport() {
        UIPasteboard.general.string = report
        copied = true
    }

    // MARK: - Helpers

    static func rms(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData else { return 0 }
        let n = Int(b.frameLength)
        if n == 0 { return 0 }
        let p = ch[0]
        var s: Float = 0
        for i in 0..<n { s += p[i] * p[i] }
        return (s / Float(n)).squareRoot()
    }

    static func median(_ a: [Float]) -> Float {
        if a.isEmpty { return 0 }
        let s = a.sorted()
        return s[s.count / 2]
    }

    static func beepWav() -> Data {
        let sr = 22050
        let n = Int(Double(sr) * 0.25)
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
        for i in 0..<n {
            let env = min(1.0, Double(i) / 200.0, Double(n - i) / 200.0)
            let v = sin(2 * Double.pi * 880 * Double(i) / Double(sr)) * 0.5 * env * 32767
            var x = Int16(v).littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        return d
    }
}

struct ContentView: View {
    @EnvironmentObject var t: Tester

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Нативный тест микрофона в фоне")
                    .font(.title2).bold()

                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Нажми «Старт», разреши микрофон, скажи пару слов.")
                    Text("2. Заблокируй экран и секунд 20 считай вслух. Каждые 10 секунд будет писк.")
                    Text("3. Разблокируй, уйди в другое приложение и снова посчитай секунд 20.")
                    Text("4. Вернись, нажми «Стоп», послушай запись и скопируй результат.")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button { t.start() } label: {
                        Text("Старт").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(t.running)

                    Button { t.stop() } label: {
                        Text("Стоп").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!t.running)
                }

                ProgressView(value: Double(min(1, t.level * 8)))
                HStack {
                    Text(t.status)
                    Spacer()
                    Text("\(Int(t.elapsed)) с")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if !t.verdict.isEmpty {
                    Divider()
                    Text("Вердикт").font(.headline)
                    ForEach(t.verdict) { line in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(color(for: line.kind))
                                .frame(width: 10, height: 10)
                                .padding(.top, 5)
                            Text(line.text)
                        }
                    }

                    Button { t.togglePlayback() } label: {
                        Text(t.isPlaying ? "Остановить запись" : "Прослушать запись")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)

                    Button { t.copyReport() } label: {
                        Text(t.copied ? "Скопировано — вставь в чат с Claude" : "Скопировать результат для Claude")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    private func color(for kind: String) -> Color {
        switch kind {
        case "ok": return .green
        case "warn": return .orange
        case "bad": return .red
        default: return .gray
        }
    }
}

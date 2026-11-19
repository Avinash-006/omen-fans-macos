import AppKit
import IOKit
import SwiftUI

private struct FanError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct Reading {
    let cpu: UInt64
    let gpu: UInt64
    let mode: UInt64
    let canControl: Bool
}

private final class Bridge {
    private var connection: io_connect_t = 0

    func close() {
        if connection != 0 { IOServiceClose(connection) }
        connection = 0
    }

    func read() throws -> Reading {
        let values = try call(0, outputCount: 4)
        return Reading(cpu: values[0], gpu: values[1], mode: values[2], canControl: values[3] == 1)
    }

    func automatic() throws { _ = try call(1) }
    func apply(cpu: Int, gpu: Int) throws { _ = try call(2, inputs: [UInt64(cpu), UInt64(gpu)]) }
    func limits() throws -> [Int] { try call(4, outputCount: 2).map(Int.init) }
    func supportsSafeHandoff() -> Bool { (try? call(6, outputCount: 1).first) == 1 }
    func cpuTemperature() throws -> Double { Double(try call(5, outputCount: 1)[0]) }
    func renew() throws { _ = try call(3) }

    private func call(_ selector: UInt32, inputs: [UInt64] = [], outputCount: UInt32 = 0) throws -> [UInt64] {
        if connection == 0 {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("OmenFanBridge"))
            guard service != 0 else { throw FanError(message: "The OpenCore fan bridge is offline.") }
            defer { IOObjectRelease(service) }
            let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
            try check(result, "Couldn’t open the fan bridge")
        }
        var output = [UInt64](repeating: 0, count: Int(outputCount))
        var returnedCount = outputCount
        let result = inputs.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { buffer in
                IOConnectCallScalarMethod(connection, selector, input.baseAddress,
                                          UInt32(input.count), buffer.baseAddress, &returnedCount)
            }
        }
        try check(result, "The fan bridge returned an error")
        guard returnedCount == outputCount else { throw FanError(message: "Unexpected fan bridge response.") }
        return output
    }

    private func check(_ result: kern_return_t, _ description: String) throws {
        guard result == KERN_SUCCESS else {
            throw FanError(message: "\(description) (\(String(format: "0x%08x", UInt32(bitPattern: result)))).")
        }
    }
}

private final class TemperatureSensors {
    private var smc: io_connect_t = 0
    private var gpu: io_service_t = 0

    func read() -> (cpu: Double?, gpu: Double?) {
        let cpu = omen_cpu_temperature(&smc)
        if gpu == 0 {
            gpu = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVAccel"))
        }
        let stats = gpu == 0 ? nil : IORegistryEntryCreateCFProperty(
            gpu, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any]
        let temperature = (stats?["Temperature(C)"] as? NSNumber)?.doubleValue ?? .nan
        return ((1...125).contains(cpu) ? cpu : nil, (1...125).contains(temperature) ? temperature : nil)
    }

    deinit {
        if smc != 0 { IOServiceClose(smc) }
        if gpu != 0 { IOObjectRelease(gpu) }
    }
}

private enum Mode: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case fixed = "Fixed speed"
    case curve = "Fan curve"
    var id: Self { self }
}

private struct Point: Codable, Equatable {
    var degrees: Int
    var percent: Int
}

private let factoryCurve = [Point(degrees: 45, percent: 70), Point(degrees: 60, percent: 78),
                            Point(degrees: 74, percent: 92), Point(degrees: 84, percent: 100)]

private func curveSpeed(_ degrees: Double, points: [Point]) -> Int {
    guard let first = points.first, let last = points.last else { return 100 }
    if degrees <= Double(first.degrees) { return first.percent }
    for (left, right) in zip(points, points.dropFirst()) where degrees <= Double(right.degrees) {
        let progress = (degrees - Double(left.degrees)) / Double(right.degrees - left.degrees)
        return Int((Double(left.percent) + progress * Double(right.percent - left.percent)).rounded())
    }
    return last.percent
}

private final class FanModel: ObservableObject {
    @Published var tab: Mode = .automatic
    @Published var fixed: Double = 85
    @Published var points = factoryCurve
    @Published private(set) var active: Mode = .automatic
    @Published private(set) var reading: Reading?
    @Published private(set) var cpu: Double?
    @Published private(set) var gpu: Double?
    @Published private(set) var limits: [Int]?
    @Published private(set) var message: String?
    @Published private(set) var target: Int?
    @Published private(set) var thermalSafe = true
    @Published private(set) var safeHandoff = false
    @Published private(set) var handingOff = false
    @Published var visible = false

    private let bridge = Bridge()
    private let sensors = TemperatureSensors()
    private var runningCurve = factoryCurve
    private var fixedTarget = 85
    private var renewAt = 0.0
    private var attemptedLimits = false
    private var sleeping = false
    private let curveKey = "OmenFans.sharedCurve.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: curveKey),
           let saved = try? JSONDecoder().decode([Point].self, from: data),
           saved.count == factoryCurve.count,
           saved.allSatisfy({ (35...90).contains($0.degrees) && (70...100).contains($0.percent) }),
           zip(saved, saved.dropFirst()).allSatisfy({ $0.degrees < $1.degrees && $0.percent <= $1.percent }) {
            points = saved
        }
    }

    var hottest: Double? {
        guard let cpu, let gpu else { return nil }
        return max(cpu, gpu)
    }

    var canApply: Bool { canControl && (tab != .curve || hottest != nil) }
    private var canControl: Bool { safeHandoff && reading?.canControl == true && thermalSafe }
    var graphLimits: [Int] { limits ?? [5500, 5800] }

    func update() {
        guard !sleeping else { return }
        (cpu, gpu) = sensors.read()
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: thermalSafe = true
        default: thermalSafe = false
        }
        do {
            let wasOffline = reading == nil
            reading = try bridge.read()
            if wasOffline { message = nil }
            if reading?.canControl == true && !attemptedLimits {
                attemptedLimits = true
                safeHandoff = bridge.supportsSafeHandoff()
                if let values = try? bridge.limits(), values.count == 2, values.allSatisfy({ (2000...10000).contains($0) }) {
                    limits = values
                }
            }
            if cpu == nil && limits != nil { cpu = try? bridge.cpuTemperature() }
            let wasHandingOff = handingOff
            handingOff = reading?.mode == 2
            if handingOff {
                message = "Returning control to firmware. Allow up to two minutes."
            } else if wasHandingOff {
                message = nil
            } else if reading?.canControl != true {
                message = "Fan speed limits are unavailable."
            }
            guard active != .automatic else { return }
            guard reading?.mode == 1 else {
                active = .automatic
                target = nil
                message = "The fan override ended."
                return
            }
            guard canControl && (active != .curve || hottest != nil) else {
                automatic(reason: thermalSafe ? "Temperature sensor unavailable. Firmware has control." : "Thermal pressure detected. Firmware has control.")
                return
            }
            try drive()
        } catch {
            fail(error)
        }
    }

    func apply() {
        guard canApply, tab != .automatic else { return }
        message = nil
        active = tab
        fixedTarget = Int(fixed.rounded())
        runningCurve = points
        do {
            try drive(force: true)
            handingOff = false
            if tab == .curve, let data = try? JSONEncoder().encode(points) {
                UserDefaults.standard.set(data, forKey: curveKey)
            }
        } catch { fail(error) }
    }

    private func drive(force: Bool = false) throws {
        let requested = active == .fixed ? fixedTarget : curveSpeed(hottest ?? 125, points: runningCurve)
        let next = (cpu ?? 0) >= 90 || (gpu ?? 0) >= 83 ? 100 : requested
        let now = ProcessInfo.processInfo.systemUptime
        if force || next > (target ?? 0) || next <= (target ?? 0) - 2 {
            try bridge.apply(cpu: next, gpu: next)
            target = next
            renewAt = now + 25
        } else if now >= renewAt {
            try bridge.renew()
            renewAt = now + 25
        }
    }

    func automatic(reason: String? = nil) {
        active = .automatic
        target = nil
        message = reason
        guard safeHandoff else { return }
        do {
            try bridge.automatic()
            update()
        } catch { fail(error) }
    }

    func sleep() {
        if active != .automatic { automatic() }
        sleeping = true
        bridge.close()
    }

    func wake() {
        sleeping = false
        update()
    }

    private func fail(_ error: Error) {
        if active != .automatic { try? bridge.automatic() }
        active = .automatic
        target = nil
        reading = nil
        handingOff = false
        message = error.localizedDescription
        bridge.close()
    }

    func edit(_ index: Int, degrees: Int? = nil, percent: Int? = nil) {
        if let degrees {
            let low = index > 0 ? points[index - 1].degrees + 1 : 35
            let high = index < points.count - 1 ? points[index + 1].degrees - 1 : 90
            points[index].degrees = min(high, max(low, degrees))
        }
        if let percent {
            let low = index > 0 ? points[index - 1].percent : 70
            let high = index < points.count - 1 ? points[index + 1].percent : 100
            points[index].percent = min(high, max(low, percent))
        }
    }

    func resetCurve() { points = factoryCurve }
}

private let accent = Color(red: 0.98, green: 0.23, blue: 0.36)
private let gpuAccent = Color(red: 0.50, green: 0.47, blue: 0.98)

private struct FanPanel: View {
    @ObservedObject var model: FanModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let quit: () -> Void
    var resize: (CGSize) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            header
            HStack(spacing: 9) {
                sensor("CPU", icon: "cpu", temperature: model.cpu, rpm: model.reading?.cpu, color: accent)
                sensor("GPU", icon: "display", temperature: model.gpu, rpm: model.reading?.gpu, color: gpuAccent)
            }
            HStack(spacing: 3) {
                ForEach(Mode.allCases) { mode in
                    Button { model.tab = mode } label: {
                        Text(mode.rawValue).font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(model.tab == mode ? accent.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.tab == mode ? .isSelected : [])
                }
            }
            .padding(3)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
            .onChange(of: model.tab) { _, tab in
                if tab == .automatic && model.active != .automatic { model.automatic() }
            }
            if model.tab == .curve {
                curveEditor
            } else if model.tab == .fixed {
                slider
            } else {
                Label("Firmware adjusts both fans as needed.", systemImage: "shield.checkered")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 45, alignment: .leading)
            }
            if !model.safeHandoff, model.reading?.canControl == true {
                Label("Restart through OpenCore with bridge 1.0.3 to enable fan control.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = model.message {
                Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.tab != .automatic, (model.tab == .curve && model.hottest == nil) || !model.thermalSafe {
                Text(model.thermalSafe ? "Both temperature readings are needed for manual control." : "Firmware cooling is available while the system is hot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            footer
        }
        .padding(17)
        .frame(width: 406)
        .fixedSize(horizontal: true, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { resize(geometry.size) }
                    .onChange(of: geometry.size) { _, size in resize(size) }
            }
        }
    }

    private var header: some View {
        let rpm = max(model.reading?.cpu ?? 0, model.reading?.gpu ?? 0)
        return HStack(spacing: 11) {
            TimelineView(.animation(minimumInterval: 1.0 / 36, paused: reduceMotion || !model.visible || rpm == 0)) { tick in
                Image(systemName: "fan.fill")
                    .font(.system(size: 21, weight: .medium))
                    .rotationEffect(.degrees(reduceMotion || rpm == 0 ? 0 :
                        (tick.date.timeIntervalSinceReferenceDate * (85 + Double(rpm) / 35)).truncatingRemainder(dividingBy: 360)))
                    .foregroundStyle(accent)
                    .frame(width: 45, height: 45)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("OMEN Fans").font(.system(size: 22, weight: .semibold))
                Text(model.target.map { "Both fans · \($0)% target" } ?? "Cooling control")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(model.handingOff ? Color.orange : model.active == .automatic ? Color.green : accent).frame(width: 6, height: 6)
                Text(model.handingOff ? "Firmware handoff" : model.active.rawValue).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(.quaternary.opacity(0.65), in: Capsule())
        }
    }

    private func sensor(_ title: String, icon: String, temperature: Double?, rpm: UInt64?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(temperature.map { "\(Int($0.rounded()))°C" } ?? "— °C")
                .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(rpm.map { "\($0.formatted()) RPM" } ?? "— RPM")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(color.opacity(0.17)))
        .accessibilityElement(children: .combine)
    }

    private var slider: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Both fan speeds").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(model.fixed))%").font(.subheadline.monospacedDigit())
            }
            Slider(value: $model.fixed, in: 70...100, step: 1).tint(accent).accessibilityLabel("Both fan speeds")
            HStack { Text("70%"); Spacer(); Text("100%") }.font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var curveEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("CPU", systemImage: "circle.fill").foregroundStyle(accent)
                Label("GPU", systemImage: "circle.fill").foregroundStyle(gpuAccent)
                Spacer()
                Text(model.limits == nil ? "Estimated RPM targets" : "RPM targets")
                    .foregroundStyle(.secondary)
            }.font(.caption2.weight(.medium))
            CurveGraph(points: model.points, limits: model.graphLimits, temperature: model.hottest)
                .frame(height: 130)
                .accessibilityLabel("Fan speed targets in RPM by temperature in Celsius.")
            HStack {
                Text("Points use the hotter sensor.").foregroundStyle(.secondary)
                Spacer()
                Button("Reset points", action: model.resetCurve).buttonStyle(.plain).foregroundStyle(accent)
            }.font(.caption)
            ForEach(model.points.indices, id: \.self) { index in
                let point = model.points[index]
                HStack {
                    Text("Point \(index + 1)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    pointControl("\(point.degrees) °C", label: "Point \(index + 1) temperature") { adjustment in
                        model.edit(index, degrees: point.degrees + adjustment)
                    }
                    pointControl("\(point.percent)%", label: "Point \(index + 1) speed") { adjustment in
                        model.edit(index, percent: point.percent + adjustment)
                    }
                }.font(.caption)
            }
        }
    }

    private func pointControl(_ value: String, label: String, change: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            Button { change(-1) } label: {
                Image(systemName: "minus").frame(width: 23, height: 23).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Decrease \(label)")
            Text(value).monospacedDigit().frame(width: 37)
            Button { change(1) } label: {
                Image(systemName: "plus").frame(width: 23, height: 23).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Increase \(label)")
        }
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack {
            Button("Quit", action: quit).buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
            if model.active != .automatic {
                Button("Return to automatic") { model.tab = .automatic; model.automatic() }
            }
            if model.tab != .automatic {
                Button(model.tab == .curve ? "Apply curve" : "Apply speed", action: model.apply)
                    .buttonStyle(.borderedProminent).tint(accent).disabled(!model.canApply)
            }
        }
    }
}

private struct CurveGraph: View {
    let points: [Point]
    let limits: [Int]
    let temperature: Double?

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 43, y: 7, width: size.width - 58, height: size.height - 25)
            let low = min(limits[0] * 7 / 10, limits[1] * 7 / 10) / 1000 * 1000
            let high = (max(limits[0], limits[1]) + 999) / 1000 * 1000
            func xy(_ degrees: Double, _ rpm: Double) -> CGPoint {
                CGPoint(x: plot.minX + (degrees - 35) / 55 * plot.width,
                        y: plot.maxY - (rpm - Double(low)) / Double(high - low) * plot.height)
            }
            let grid = Color.secondary.opacity(0.2)
            for rpm in stride(from: low, through: high, by: 1000) {
                let y = xy(35, Double(rpm)).y
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y))
                line.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(line, with: .color(grid))
                context.draw(Text(rpm.formatted()).font(.system(size: 9)).foregroundStyle(Color.secondary),
                             at: CGPoint(x: plot.minX - 5, y: y), anchor: .trailing)
            }
            for degrees in [35, 50, 65, 80, 90] {
                context.draw(Text("\(degrees)°").font(.system(size: 9)).foregroundStyle(Color.secondary),
                             at: CGPoint(x: xy(Double(degrees), 0).x, y: plot.maxY + 10))
            }
            if let temperature, (35...90).contains(temperature) {
                let x = xy(temperature, 0).x
                var cursor = Path()
                cursor.move(to: CGPoint(x: x, y: plot.minY))
                cursor.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(cursor, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
            for (limit, color) in zip(limits, [accent, gpuAccent]) {
                let values = [Point(degrees: 35, percent: points[0].percent)] + points +
                    [Point(degrees: 90, percent: points[points.count - 1].percent)]
                let locations = values.map { xy(Double($0.degrees), Double(Int((Double($0.percent * limit) / 10000).rounded()) * 100)) }
                var line = Path()
                line.addLines(locations)
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                for location in locations.dropFirst().dropLast() {
                    context.fill(Path(ellipseIn: CGRect(x: location.x - 3, y: location.y - 3, width: 6, height: 6)), with: .color(color))
                }
            }
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = FanModel()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let icon = NSImage(systemSymbolName: "fan", accessibilityDescription: "OMEN Fans")
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.title = icon == nil ? "Fans" : ""
        item.button?.toolTip = "OMEN Fans"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        let panel = FanPanel(model: model, quit: { NSApp.terminate(nil) }, resize: { [weak self] size in
            DispatchQueue.main.async {
                guard let self, size.width > 0, size.height > 0, self.popover.contentSize != size else { return }
                self.popover.contentSize = size
            }
        })
        let host = NSHostingController(rootView: panel)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        popover.behavior = .transient
        popover.delegate = self
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(thermalChanged), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        let timer = Timer(timeInterval: 2, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        model.update()
        if CommandLine.arguments.contains("--show"), let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(self); return }
        model.update()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func tick() { if model.visible || model.handingOff || model.active != .automatic { model.update() } }
    @objc private func thermalChanged() { DispatchQueue.main.async { [weak self] in self?.tick() } }
    @objc private func willSleep() { model.sleep() }
    @objc private func didWake() { model.wake() }
    func popoverDidShow(_ notification: Notification) { model.visible = true }
    func popoverDidClose(_ notification: Notification) { model.visible = false }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); model.sleep() }
}

if CommandLine.arguments.dropFirst() == ["--probe"] {
    let bridge = Bridge()
    let sensors = TemperatureSensors()
    let temperature = sensors.read()
    let gpuTemp = temperature.gpu.map { String(format: "%.1f °C", $0) } ?? "unavailable"
    do {
        let reading = try bridge.read()
        let cpu = temperature.cpu ?? (try? bridge.cpuTemperature())
        let cpuTemp = cpu.map { String(format: "%.1f °C", $0) } ?? "unavailable"
        print("CPU temperature: \(cpuTemp) · GPU temperature: \(gpuTemp)")
        if let limits = try? bridge.limits() { print("Fan limits: \(limits) RPM") }
        print("CPU: \(reading.cpu) RPM, GPU: \(reading.gpu) RPM, mode: \(reading.mode), adjustable: \(reading.canControl)")
        bridge.close()
        exit(reading.canControl && cpu != nil && temperature.gpu != nil ? 0 : 2)
    } catch {
        bridge.close()
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()

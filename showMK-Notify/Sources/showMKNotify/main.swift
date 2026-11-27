import AppKit
import Foundation

// MARK: - 数据模型

struct Peripheral {
    enum Kind: String {
        case mouse = "鼠标"
        case keyboard = "键盘"

        var symbol: String {
            switch self {
            case .mouse: return "computermouse"
            case .keyboard: return "keyboard"
            }
        }
    }

    let name: String
    let address: String
    let kind: Kind
    let connected: Bool

    var id: String { address.isEmpty ? "name:\(name)" : address }
}

/// 一次连接状态变化，供悬浮提示使用。
struct HudEvent {
    enum Kind {
        case connected
        case disconnected
        case radioOff
        case radioOn
    }

    let kind: Kind
    let slot: Peripheral.Kind?
    let deviceName: String

    var title: String {
        switch kind {
        case .connected: return "\(slot?.rawValue ?? "设备")已连接"
        case .disconnected: return "\(slot?.rawValue ?? "设备")已断开"
        case .radioOff: return "蓝牙已关闭"
        case .radioOn: return "蓝牙已开启"
        }
    }

    var detail: String {
        switch kind {
        case .connected, .disconnected: return deviceName
        case .radioOff: return "鼠标与键盘暂时不可用"
        case .radioOn: return "正在重新检测设备"
        }
    }

    /// 蓝牙总状态符号。`bluetooth`/`bluetooth.slash` 在 macOS 12.4 与当前系统均缺失，
    /// 改用两台机器上都存在的 antenna 等价符号，避免 HUD 图标空白。
    private static let radioOnSymbol = "antenna.radiowaves.left.and.right"
    private static let radioOffSymbol = "antenna.radiowaves.left.and.right.slash"

    /// 首选符号；`.fill` 在部分 SF Symbols 版本不可用，需回退到基础符号。
    var symbolName: String {
        switch kind {
        case .connected: return (slot?.symbol ?? Self.radioOnSymbol) + ".fill"
        case .disconnected: return slot?.symbol ?? Self.radioOnSymbol
        case .radioOff: return Self.radioOffSymbol
        case .radioOn: return Self.radioOnSymbol
        }
    }

    var fallbackSymbolName: String {
        switch kind {
        case .connected: return slot?.symbol ?? Self.radioOnSymbol
        default: return symbolName
        }
    }

    var tintColor: NSColor {
        switch kind {
        case .connected, .radioOn: return .controlAccentColor
        case .disconnected, .radioOff: return .secondaryLabelColor
        }
    }
}

// MARK: - 采样：只读 system_profiler，无需任何隐私授权

enum Sampler {
    enum Radio: String {
        case on = "开"
        case off = "关"
        case unknown = "未知"
    }

    struct Result {
        var devices: [Peripheral] = []
        var radio: Radio = .unknown
    }

    static func sample() -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return Result() }
        return Result(devices: parse(text), radio: radioState(text))
    }

    static func radioState(_ text: String) -> Radio {
        if text.contains("State: Off") || text.contains("Not available") { return .off }
        if text.contains("State: On") { return .on }
        return .unknown
    }

    /// 解析 `system_profiler SPBluetoothDataType` 的文本输出。
    static func parse(_ text: String) -> [Peripheral] {
        var result: [Peripheral] = []
        var connectedSection = false
        var inDevice = false
        var name = ""
        var address = ""
        var kind: Peripheral.Kind?

        func flush() {
            defer {
                inDevice = false
                name = ""
                address = ""
                kind = nil
            }
            guard inDevice, !name.isEmpty, let kind = kind else { return }
            result.append(
                Peripheral(name: name, address: address, kind: kind, connected: connectedSection)
            )
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indent = line.prefix(while: { $0 == " " }).count

            switch indent {
            case 6:
                flush()
                connectedSection = (trimmed == "Connected:")
            case 10 where trimmed.hasSuffix(":"):
                flush()
                inDevice = true
                name = String(trimmed.dropLast())
            case 14...:
                if trimmed.hasPrefix("Minor Type:") {
                    let value = trimmed.dropFirst("Minor Type:".count)
                        .trimmingCharacters(in: .whitespaces)
                    if value == "Keyboard" { kind = .keyboard }
                    if value == "Mouse" { kind = .mouse }
                } else if trimmed.hasPrefix("Address:") {
                    address = trimmed.dropFirst("Address:".count)
                        .trimmingCharacters(in: .whitespaces)
                }
            default:
                break
            }
        }
        flush()
        return result
    }
}

// MARK: - 菜单栏图标

enum Icon {
    static func make(
        mouse: Peripheral?,
        keyboard: Peripheral?,
        boundKinds: [Peripheral.Kind]
    ) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let gap: CGFloat = 5
        var parts: [(image: NSImage, alpha: CGFloat)] = []

        for kind in boundKinds {
            let device = (kind == .mouse) ? mouse : keyboard
            let connected = device?.connected == true
            let fillSymbol = kind.symbol + (connected ? ".fill" : "")
            let baseImage = NSImage(systemSymbolName: fillSymbol, accessibilityDescription: kind.rawValue)
                ?? NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.rawValue)
            guard let image = baseImage?.withSymbolConfiguration(config) else { continue }
            parts.append((image, connected ? 1.0 : 0.35))
        }

        guard !parts.isEmpty else {
            let fallback = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "状态未知")
            return fallback ?? NSImage(size: NSSize(width: 14, height: 14))
        }

        let height = parts.map { $0.image.size.height }.max() ?? 16
        let contentWidth = parts.map { $0.image.size.width }.reduce(0, +)
            + gap * CGFloat(parts.count - 1)

        let canvas = NSImage(
            size: NSSize(width: contentWidth.rounded(.up), height: height),
            flipped: false
        ) { _ in
            var x: CGFloat = 0
            for part in parts {
                let y = (height - part.image.size.height) / 2
                part.image.draw(
                    in: NSRect(x: x, y: y, width: part.image.size.width, height: part.image.size.height),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: part.alpha
                )
                x += part.image.size.width + gap
            }
            return true
        }
        canvas.isTemplate = true
        return canvas
    }
}

// MARK: - 悬浮提示窗口

final class HudRowView: NSView {
    init(frame: NSRect, event: HudEvent) {
        super.init(frame: frame)

        let config = NSImage.SymbolConfiguration(pointSize: 36, weight: .medium)
        let image = (NSImage(systemSymbolName: event.symbolName, accessibilityDescription: nil)
                     ?? NSImage(systemSymbolName: event.fallbackSymbolName, accessibilityDescription: nil))?
            .withSymbolConfiguration(config)
        let imageView = NSImageView(frame: NSRect(x: 0, y: 12, width: 54, height: 54))
        imageView.image = image
        imageView.contentTintColor = event.tintColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)

        let title = NSTextField(labelWithString: event.title)
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        title.textColor = .labelColor
        title.frame = NSRect(x: 69, y: 39, width: frame.width - 69, height: 27)
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)

        let detail = NSTextField(labelWithString: event.detail)
        detail.font = .systemFont(ofSize: 17)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 69, y: 10, width: frame.width - 69, height: 24)
        detail.lineBreakMode = .byTruncatingTail
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 底部居中的无边框毛玻璃提示，行为参考系统音量/HUD 提示：
/// 淡入、短暂停留、淡出；新事件替换当前内容而不叠加窗口。
final class HudPresenter {
    private enum Layout {
        static let width: CGFloat = 480
        static let rowHeight: CGFloat = 78
        static let gap: CGFloat = 12
        static let padding: CGFloat = 24
        static let bottomInset: CGFloat = 64
        /// 相对屏幕可见高度上移的比例（10%）
        static let upwardRatio: CGFloat = 0.10
        static let visibleSeconds: TimeInterval = 2.6
    }

    private var panel: NSPanel?
    private var dismissTimer: Timer?

    func present(_ events: [HudEvent]) {
        guard !events.isEmpty else { return }
        let rows = Array(events.prefix(2))

        dismissTimer?.invalidate()
        dismissTimer = nil

        let frame = Self.frame(rowCount: rows.count)
        if panel == nil {
            let newPanel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            // 关闭窗口级直角阴影：NSPanel 按矩形 frame 投影，会从内容圆角外露出直角线条。
            // 阴影改由 contentView 的圆角 layer 承载（见 contentView），随圆角形状投射。
            newPanel.hasShadow = false
            newPanel.level = .floating
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            newPanel.ignoresMouseEvents = true
            panel = newPanel
        }
        guard let panel = panel else { return }

        panel.setFrame(frame, display: false)
        panel.contentView = Self.contentView(for: rows, size: frame.size)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        let timer = Timer(timeInterval: Layout.visibleSeconds, repeats: false) {
            [weak self, weak panel] _ in
            guard let panel = panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
            self?.dismissTimer = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    private static func frame(rowCount: Int) -> NSRect {
        let height = Layout.padding * 2
            + Layout.rowHeight * CGFloat(rowCount)
            + Layout.gap * CGFloat(max(0, rowCount - 1))
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: screen.midX - Layout.width / 2,
            y: screen.minY + Layout.bottomInset + screen.height * Layout.upwardRatio,
            width: Layout.width,
            height: height
        )
    }

    private static func contentView(for events: [HudEvent], size: NSSize) -> NSView {
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 21
        effect.layer?.masksToBounds = true
        // 圆角阴影：由内容层按圆角路径投射，避免 NSPanel 直角矩形阴影从圆角外露出。
        // shadowOffset 用负 y（AppKit 坐标系下向上为正），使阴影落在卡片下方。
        effect.layer?.shadowColor = NSColor.black.withAlphaComponent(0.45).cgColor
        effect.layer?.shadowOffset = CGSize(width: 0, height: -6)
        effect.layer?.shadowRadius = 18
        effect.layer?.shadowOpacity = 1
        effect.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: size),
            cornerWidth: 21,
            cornerHeight: 21,
            transform: nil
        )

        for (index, event) in events.enumerated() {
            let y = size.height - Layout.padding - Layout.rowHeight
                - CGFloat(index) * (Layout.rowHeight + Layout.gap)
            let row = HudRowView(
                frame: NSRect(
                    x: Layout.padding,
                    y: y,
                    width: size.width - Layout.padding * 2,
                    height: Layout.rowHeight
                ),
                event: event
            )
            effect.addSubview(row)
        }
        return effect
    }
}

// MARK: - 连接状态差分检测

/// 独立于 AppKit 的状态检测器，便于离线验证各种边界场景。
final class ConnectionDetector {
    struct Binding {
        let id: String
        let name: String
    }

    private struct LastEvent {
        let connected: Bool
        let date: Date
    }

    private let debounceSeconds: TimeInterval
    private let now: () -> Date
    private var previousRadio: Sampler.Radio?
    private var previousConnection: [String: Bool] = [:]
    private var lastEvent: [String: LastEvent] = [:]

    init(debounceSeconds: TimeInterval = 5, now: @escaping () -> Date = { Date() }) {
        self.debounceSeconds = debounceSeconds
        self.now = now
    }

    /// - Parameters:
    ///   - radio: 本次采样的蓝牙总状态
    ///   - devices: 本次采样的完整设备列表
    ///   - binding: 返回当前绑定的稳定 id 与名称；未绑定返回 nil
    /// - Returns: 本次需要提示的事件，可能为空
    func detect(
        radio: Sampler.Radio,
        devices: [Peripheral],
        binding: (Peripheral.Kind) -> Binding?
    ) -> [HudEvent] {
        guard let previousRadio = previousRadio else {
            self.previousRadio = radio
            rebuildBaseline(radio: radio, devices: devices, binding: binding)
            return []
        }

        if previousRadio != radio {
            self.previousRadio = radio
            var events: [HudEvent] = []
            if radio == .off {
                events.append(HudEvent(kind: .radioOff, slot: nil, deviceName: ""))
            } else if previousRadio == .off && radio == .on {
                events.append(HudEvent(kind: .radioOn, slot: nil, deviceName: ""))
            }
            rebuildBaseline(radio: radio, devices: devices, binding: binding)
            return events
        }

        // 采样失败或蓝牙未开启：视为未知，不把「暂时看不到」当成断开
        guard radio == .on, !devices.isEmpty else { return [] }

        var events: [HudEvent] = []
        for kind in [Peripheral.Kind.mouse, .keyboard] {
            guard let bound = binding(kind) else { continue }
            let matched = devices.first { $0.id == bound.id && $0.kind == kind }
                ?? devices.first { $0.name == bound.name && $0.kind == kind }

            // 设备整台消失（关机或切走）视为断开；从未见过的绑定不提示
            let connected = matched?.connected ?? false
            guard previousConnection[bound.id] != nil else {
                previousConnection[bound.id] = connected
                continue
            }
            guard previousConnection[bound.id] != connected else { continue }

            if let last = lastEvent[bound.id],
               last.connected == connected,
               now().timeIntervalSince(last.date) < debounceSeconds {
                previousConnection[bound.id] = connected
                continue
            }
            lastEvent[bound.id] = LastEvent(connected: connected, date: now())
            previousConnection[bound.id] = connected
            events.append(HudEvent(
                kind: connected ? .connected : .disconnected,
                slot: kind,
                deviceName: matched?.name ?? bound.name
            ))
        }
        return events
    }

    /// 绑定改变时重置基线，避免把新设备的当前状态误判为一次变化。
    func reset() {
        previousRadio = nil
        previousConnection.removeAll()
        lastEvent.removeAll()
    }

    private func rebuildBaseline(
        radio: Sampler.Radio,
        devices: [Peripheral],
        binding: (Peripheral.Kind) -> Binding?
    ) {
        previousConnection.removeAll()
        guard radio == .on else { return }
        for kind in [Peripheral.Kind.mouse, .keyboard] {
            guard let bound = binding(kind) else { continue }
            let matched = devices.first { $0.id == bound.id && $0.kind == kind }
                ?? devices.first { $0.name == bound.name && $0.kind == kind }
            previousConnection[bound.id] = matched?.connected ?? false
        }
    }
}

// MARK: - 菜单栏应用

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Key {
        static let mouseID = "monitoredMouseID"
        static let mouseName = "monitoredMouseName"
        static let keyboardID = "monitoredKeyboardID"
        static let keyboardName = "monitoredKeyboardName"
        static let hudEnabled = "hudNotificationEnabled"
    }

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var devices: [Peripheral] = []
    private var radio: Sampler.Radio = .unknown
    private var reading = false
    private var lastSignature = ""

    // 差分检测状态
    private let hud = HudPresenter()
    private let detector = ConnectionDetector()

    private let defaults = UserDefaults.standard
    private let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/showMK-Notify.log")

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        render()
        reload()

        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.reload()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        if CommandLine.arguments.contains("--test-hud") {
            hud.present(Self.demoEvents())
            log("测试提示已显示")
        }
    }

    // MARK: 采样

    private func reload() {
        guard !reading else { return }
        reading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Sampler.sample()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.reading = false
                self.apply(result)
            }
        }
    }

    private func apply(_ result: Sampler.Result) {
        devices = result.devices
        radio = result.radio
        bindDefaultsIfNeeded()

        // 先做变化检测，再更新菜单栏
        let events = detector.detect(radio: result.radio, devices: result.devices) { [weak self] kind in
            guard let self = self else { return nil }
            let idKey = kind == .mouse ? Key.mouseID : Key.keyboardID
            let nameKey = kind == .mouse ? Key.mouseName : Key.keyboardName
            guard let id = self.defaults.string(forKey: idKey), !id.isEmpty else { return nil }
            let name = self.defaults.string(forKey: nameKey) ?? kind.rawValue
            return ConnectionDetector.Binding(id: id, name: name)
        }
        if !events.isEmpty {
            if hudEnabled { hud.present(events) }
            for event in events { log("事件：\(event.title) \(event.detail)") }
        }

        let signature = "\(radio.rawValue)|"
            + result.devices.map { "\($0.id):\($0.connected)" }.joined(separator: " ")
            + "|mouse=\(defaults.string(forKey: Key.mouseID) ?? "-")"
            + "|kb=\(defaults.string(forKey: Key.keyboardID) ?? "-")"
        guard signature != lastSignature else { return }
        lastSignature = signature
        log(signature)
        render()
    }

    // MARK: 绑定

    private func monitored(_ kind: Peripheral.Kind) -> Peripheral? {
        monitored(kind, in: devices)
    }

    private func monitored(_ kind: Peripheral.Kind, in list: [Peripheral]) -> Peripheral? {
        let idKey = kind == .mouse ? Key.mouseID : Key.keyboardID
        let nameKey = kind == .mouse ? Key.mouseName : Key.keyboardName

        if let savedID = defaults.string(forKey: idKey),
           let match = list.first(where: { $0.id == savedID && $0.kind == kind }) {
            return match
        }
        // 重新配对后蓝牙地址可能变化，退回按名称匹配
        if let savedName = defaults.string(forKey: nameKey),
           let match = list.first(where: { $0.name == savedName && $0.kind == kind }) {
            return match
        }
        return nil
    }

    private func isBound(_ kind: Peripheral.Kind) -> Bool {
        let key = kind == .mouse ? Key.mouseID : Key.keyboardID
        return defaults.string(forKey: key)?.isEmpty == false
    }

    /// 弹窗提示是否开启，默认开启。
    private var hudEnabled: Bool {
        guard defaults.object(forKey: Key.hudEnabled) != nil else { return true }
        return defaults.bool(forKey: Key.hudEnabled)
    }

    private func bindDefaultsIfNeeded() {
        for kind in [Peripheral.Kind.mouse, .keyboard] where !isBound(kind) {
            let candidates = devices.filter { $0.kind == kind }
            guard let pick = candidates.first(where: { $0.connected }) ?? candidates.first else { continue }
            setMonitored(pick)
        }
    }

    private func setMonitored(_ device: Peripheral) {
        let idKey = device.kind == .mouse ? Key.mouseID : Key.keyboardID
        let nameKey = device.kind == .mouse ? Key.mouseName : Key.keyboardName
        defaults.set(device.id, forKey: idKey)
        defaults.set(device.name, forKey: nameKey)
        lastSignature = ""
        // 绑定改变后重置检测器，新设备的当前状态只作为基线，不产生提示
        detector.reset()
    }

    // MARK: 渲染

    private func render() {
        let mouse = monitored(.mouse)
        let keyboard = monitored(.keyboard)
        let boundKinds: [Peripheral.Kind] = [
            isBound(.mouse) ? .mouse : nil,
            isBound(.keyboard) ? .keyboard : nil,
        ].compactMap { $0 }

        statusItem.button?.image = Icon.make(
            mouse: mouse,
            keyboard: keyboard,
            boundKinds: boundKinds
        )
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = tooltip(mouse: mouse, keyboard: keyboard)
        statusItem.menu = buildMenu()
    }

    private func tooltip(mouse: Peripheral?, keyboard: Peripheral?) -> String {
        func line(_ kind: Peripheral.Kind, _ device: Peripheral?) -> String {
            if radio == .off { return "\(kind.rawValue)：蓝牙已关闭" }
            guard let device = device else { return "\(kind.rawValue)：未绑定" }
            return "\(kind.rawValue)：\(device.name)　\(device.connected ? "已连接" : "未连接")"
        }
        return line(.mouse, mouse) + "\n" + line(.keyboard, keyboard)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let settings = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()
        let binding = NSMenuItem(title: "绑定", action: nil, keyEquivalent: "")
        let bindingMenu = NSMenu()
        bindingMenu.addItem(deviceSubmenu(for: .mouse))
        bindingMenu.addItem(deviceSubmenu(for: .keyboard))
        binding.submenu = bindingMenu
        settingsMenu.addItem(binding)

        let popup = NSMenuItem(title: "弹窗提示", action: nil, keyEquivalent: "")
        let popupMenu = NSMenu()
        for enabled in [true, false] {
            let entry = NSMenuItem(
                title: enabled ? "开启" : "关闭",
                action: #selector(setHudEnabled(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = enabled
            entry.state = hudEnabled == enabled ? .on : .off
            popupMenu.addItem(entry)
        }
        popup.submenu = popupMenu
        settingsMenu.addItem(popup)

        settings.submenu = settingsMenu
        menu.addItem(settings)

        menu.addItem(.separator())
        let test = NSMenuItem(title: "测试提示效果", action: #selector(testHud), keyEquivalent: "t")
        test.target = self
        menu.addItem(test)
        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let quit = NSMenuItem(title: "退出", action: #selector(terminate), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func deviceSubmenu(for kind: Peripheral.Kind) -> NSMenuItem {
        let item = NSMenuItem(title: kind.rawValue, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let candidates = devices.filter { $0.kind == kind }
        let current = monitored(kind)

        if candidates.isEmpty {
            let empty = NSMenuItem(
                title: radio == .off ? "蓝牙已关闭" : "没有可用的\(kind.rawValue)",
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for device in candidates {
                let entry = NSMenuItem(
                    title: device.name + (device.connected ? "" : "（未连接）"),
                    action: #selector(selectDevice(_:)),
                    keyEquivalent: ""
                )
                entry.target = self
                entry.representedObject = device
                entry.state = (device.id == current?.id) ? .on : .off
                submenu.addItem(entry)
            }
        }

        item.submenu = submenu
        return item
    }

    static func demoEvents() -> [HudEvent] {
        [
            HudEvent(kind: .connected, slot: .mouse, deviceName: "示例鼠标"),
            HudEvent(kind: .disconnected, slot: .keyboard, deviceName: "示例键盘"),
        ]
    }

    // MARK: 动作

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? Peripheral else { return }
        setMonitored(device)
        render()
    }

    @objc private func setHudEnabled(_ sender: NSMenuItem) {
        guard let enabled = sender.representedObject as? Bool else { return }
        defaults.set(enabled, forKey: Key.hudEnabled)
        log("弹窗提示已\(enabled ? "开启" : "关闭")")
        render()
    }

    @objc private func testHud() {
        hud.present(Self.demoEvents())
        log("测试提示已显示")
    }

    @objc private func refreshNow() {
        lastSignature = ""
        reload()
    }

    @objc private func terminate() { NSApp.terminate(nil) }

    // MARK: 日志

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - 离线自检

private enum SelfTest {
    static func run() {
        var failures: [String] = []
        func check(_ name: String, _ actual: [String], _ expected: [String]) {
            if actual == expected {
                print("PASS  \(name)")
            } else {
                print("FAIL  \(name)  实际=\(actual) 预期=\(expected)")
                failures.append(name)
            }
        }

        let mouse = Peripheral(name: "Mouse", address: "AA", kind: .mouse, connected: true)
        let keyboard = Peripheral(name: "Keyboard", address: "BB", kind: .keyboard, connected: true)
        let bindings: [Peripheral.Kind: ConnectionDetector.Binding] = [
            .mouse: .init(id: mouse.id, name: mouse.name),
            .keyboard: .init(id: keyboard.id, name: keyboard.name),
        ]
        func binding(_ kind: Peripheral.Kind) -> ConnectionDetector.Binding? { bindings[kind] }
        func titles(_ events: [HudEvent]) -> [String] { events.map { $0.title } }

        // 首帧只建基线
        var detector = ConnectionDetector()
        let first = detector.detect(radio: .on, devices: [mouse, keyboard], binding: binding)
        check("首帧无提示", titles(first), [])

        // 鼠标连接 -> 断开
        var mouseOff = mouse
        mouseOff = Peripheral(name: mouse.name, address: mouse.address, kind: .mouse, connected: false)
        let off = detector.detect(radio: .on, devices: [mouseOff, keyboard], binding: binding)
        check("鼠标断开提示", titles(off), ["鼠标已断开"])

        // 同方向冷却期内重复断开不提示
        let repeated = detector.detect(radio: .on, devices: [mouseOff, keyboard], binding: binding)
        check("同方向去抖", titles(repeated), [])

        // 反向变化立即提示
        let backOn = detector.detect(radio: .on, devices: [mouse, keyboard], binding: binding)
        check("反向变化即时提示", titles(backOn), ["鼠标已连接"])

        // 设备整台消失视为断开，且与另一台同时变化时合帧
        let vanished = detector.detect(radio: .on, devices: [], binding: binding)
        check("采样空结果静默", titles(vanished), [])
        let bothGone = detector.detect(
            radio: .on,
            devices: [
                Peripheral(name: mouse.name, address: mouse.address, kind: .mouse, connected: false),
                Peripheral(name: keyboard.name, address: keyboard.address, kind: .keyboard, connected: false),
            ],
            binding: binding
        )
        check("双设备同时断开合帧", titles(bothGone), ["鼠标已断开", "键盘已断开"])

        // 蓝牙关闭只提示一次总状态，不逐设备提示
        detector = ConnectionDetector()
        _ = detector.detect(radio: .on, devices: [mouse, keyboard], binding: binding)
        let radioOff = detector.detect(radio: .off, devices: [], binding: binding)
        check("蓝牙关闭只提示总状态", titles(radioOff), ["蓝牙已关闭"])

        // 蓝牙恢复重建基线，不误报设备连接
        let radioOn = detector.detect(radio: .on, devices: [mouse, keyboard], binding: binding)
        check("蓝牙恢复重建基线", titles(radioOn), ["蓝牙已开启"])

        // 绑定变更重置后，当前状态作为基线
        let switched = ConnectionDetector.Binding(id: "NEW", name: "New Mouse")
        let afterSwitch = detector.detect(radio: .on, devices: [mouse, keyboard], binding: { kind in
            kind == .mouse ? switched : bindings[kind]
        })
        check("绑定变更不误报", titles(afterSwitch), [])

        if failures.isEmpty {
            print("自检全部通过")
            exit(0)
        }
        print("自检失败 \(failures.count) 项")
        exit(1)
    }
}

// MARK: - 入口

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
}

if CommandLine.arguments.contains("--dump") {
    let result = Sampler.sample()
    print("蓝牙：\(result.radio.rawValue)")
    if result.devices.isEmpty { print("未解析到键盘/鼠标设备") }
    for device in result.devices {
        print("\(device.kind.rawValue)\t\(device.connected ? "已连接" : "未连接")\t\(device.name)\t\(device.id)")
    }
    exit(0)
}

if CommandLine.arguments.contains("--render-icon") {
    let path = CommandLine.arguments.last == "--render-icon"
        ? "/tmp/icon_preview.png"
        : CommandLine.arguments.last!

    func tinted(_ image: NSImage) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
        out.unlockFocus()
        return out
    }

    func device(_ kind: Peripheral.Kind, _ connected: Bool) -> Peripheral {
        Peripheral(name: "示例", address: "x", kind: kind, connected: connected)
    }

    let cases: [(String, Peripheral?, Peripheral?, [Peripheral.Kind])] = [
        ("鼠标+键盘 均连接", device(.mouse, true), device(.keyboard, true), [.mouse, .keyboard]),
        ("键盘断开", device(.mouse, true), device(.keyboard, false), [.mouse, .keyboard]),
        ("鼠标断开", device(.mouse, false), device(.keyboard, true), [.mouse, .keyboard]),
        ("两者均断开", device(.mouse, false), device(.keyboard, false), [.mouse, .keyboard]),
        ("仅绑定鼠标", device(.mouse, true), nil, [.mouse]),
    ]

    let rowHeight: CGFloat = 34
    let icons = cases.map { Icon.make(mouse: $0.1, keyboard: $0.2, boundKinds: $0.3) }
    let maxWidth = icons.map { $0.size.width }.max() ?? 40
    let rowWidth = maxWidth + 210

    let canvas = NSImage(
        size: NSSize(width: rowWidth * 2, height: rowHeight * CGFloat(cases.count)),
        flipped: false
    ) { _ in
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: rowWidth * 2, height: rowHeight * CGFloat(cases.count)).fill()
        for (index, icon) in icons.enumerated() {
            let y = rowHeight * CGFloat(cases.count - index - 1) + (rowHeight - icon.size.height) / 2
            tinted(icon).draw(
                in: NSRect(x: 16, y: y, width: icon.size.width * 2, height: icon.size.height * 2)
            )
            let label = NSAttributedString(
                string: cases[index].0,
                attributes: [
                    .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 1),
                    .font: NSFont.systemFont(ofSize: 11),
                ]
            )
            label.draw(at: NSPoint(x: maxWidth * 2 + 40, y: y + 4))
        }
        return true
    }

    if let tiff = canvas.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("已生成预览：\(path)")
    }
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()

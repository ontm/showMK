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

    /// 蓝牙关闭时 system_profiler 不输出设备列表，需要区分「关蓝牙」与「没配对」。
    static func radioState(_ text: String) -> Radio {
        if text.contains("State: Off") || text.contains("Not available") { return .off }
        if text.contains("State: On") { return .on }
        return .unknown
    }

    /// 解析 `system_profiler SPBluetoothDataType` 的文本输出。
    /// 缩进约定：6 空格为连接分组（Connected / Not Connected），
    /// 10 空格为设备名，14 空格起为该设备属性（Minor Type / Address / …）。
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
            guard inDevice, !name.isEmpty, let kind else { return }
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

// MARK: - 菜单栏图标（SF Symbols 组合，模板图跟随深浅色与强调色）

enum Icon {
    /// 状态表达：已连接 = 实心符号 + 全不透明；未连接 = 线框符号 + 低透明度。
    /// 不使用勾/叉；形状与明暗两层信号都来自系统符号本身。
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
            // `.fill` availability varies by SF Symbols/macOS release; fall back to the base symbol.
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

// MARK: - 菜单栏应用

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Key {
        static let mouseID = "monitoredMouseID"
        static let mouseName = "monitoredMouseName"
        static let keyboardID = "monitoredKeyboardID"
        static let keyboardName = "monitoredKeyboardName"
    }

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var devices: [Peripheral] = []
    private var radio: Sampler.Radio = .unknown
    private var reading = false
    private var lastSignature = ""

    private let defaults = UserDefaults.standard
    private let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/BTStatusBar.log")

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
    }

    // MARK: 采样

    /// 采样放在后台队列，避免 system_profiler 偶发变慢时卡住菜单栏。
    private func reload() {
        guard !reading else { return }
        reading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Sampler.sample()
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                self.apply(result)
            }
        }
    }

    private func apply(_ result: Sampler.Result) {
        devices = result.devices
        radio = result.radio
        bindDefaultsIfNeeded()

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
        let idKey = kind == .mouse ? Key.mouseID : Key.keyboardID
        let nameKey = kind == .mouse ? Key.mouseName : Key.keyboardName

        if let savedID = defaults.string(forKey: idKey),
           let match = devices.first(where: { $0.id == savedID && $0.kind == kind }) {
            return match
        }
        // 重新配对后蓝牙地址可能变化，退回按名称匹配
        if let savedName = defaults.string(forKey: nameKey),
           let match = devices.first(where: { $0.name == savedName && $0.kind == kind }) {
            return match
        }
        return nil
    }

    private func isBound(_ kind: Peripheral.Kind) -> Bool {
        let key = kind == .mouse ? Key.mouseID : Key.keyboardID
        return defaults.string(forKey: key)?.isEmpty == false
    }

    /// 首次运行未绑定时，优先绑定当前已连接的设备，其次任意一台。
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
            guard let device else { return "\(kind.rawValue)：未绑定" }
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
        settings.submenu = settingsMenu
        menu.addItem(settings)

        menu.addItem(.separator())
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

    // MARK: 动作

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? Peripheral else { return }
        setMonitored(device)
        render()
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

// MARK: - 入口

// 调试用：`./BTStatusBar --dump` 直接打印采样结果后退出。
if CommandLine.arguments.contains("--dump") {
    let result = Sampler.sample()
    print("蓝牙：\(result.radio.rawValue)")
    if result.devices.isEmpty { print("未解析到键盘/鼠标设备") }
    for device in result.devices {
        print("\(device.kind.rawValue)\t\(device.connected ? "已连接" : "未连接")\t\(device.name)\t\(device.id)")
    }
    exit(0)
}

// 调试用：`./BTStatusBar --render-icon [输出路径]` 生成状态图标预览图。
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
let appDelegate = AppDelegate()          // 顶层常量强引用，避免 delegate 被释放
application.delegate = appDelegate
application.run()

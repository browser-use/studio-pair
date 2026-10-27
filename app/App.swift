import AppKit
import Foundation
import ServiceManagement

private struct Display: Decodable {
    let id: Int
    let uid: String
}
private struct AudioProcess: Decodable {
    let pid: Int
    let bundle: String
    let running: Int
}
private struct Inventory: Decodable {
    let default_output: Int
    let displays: [Display]
    let processes: [AudioProcess]
}

private final class SpeakerCard: NSView {
    let assignment = NSTextField(labelWithString: "Studio Display")
    init(side: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .centerX
        let symbol = NSImageView(image: NSImage(systemSymbolName: "display", accessibilityDescription: side)!)
        symbol.symbolConfiguration = .init(pointSize: 25, weight: .regular)
        let title = NSTextField(labelWithString: side)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        assignment.font = .systemFont(ofSize: 10)
        assignment.textColor = .secondaryLabelColor
        [symbol, title, assignment].forEach(stack.addArrangedSubview)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 118), heightAnchor.constraint(equalToConstant: 108),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func updateLayer() { layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.10).cgColor }
}

final class App: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private let engine = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/studio-pair-engine")
    private let runtime = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StudioPair")
    private var journal: URL { runtime.appendingPathComponent("journal.json") }
    private var enabled = true
    private var leftUID = ""
    private var phase = "Checking displays"
    private var active = false
    private var sleeping = false
    private var ending = false
    private var restoring = false
    private var needsRestore = false
    private var inspecting = false
    private var quitting = false
    private var backoff = 5.0
    private var nextAttempt = Date.distantPast
    private var lastEvent = Date()
    private var lastMeterLog = Date.distantPast
    private var lastWorkerState = ""
    private var lastFailure: String?
    private var anchorUID = ""
    private var inventory: Inventory?
    private var worker: Process?
    private var input: FileHandle?
    private var buffer = ""
    private var timer: Timer?
    private var appLock: FileHandle?
    private var observers: [NSObjectProtocol] = []
    private var lastPublished = Data()
    private var disableLoginOnStart = false
    private var quitForUpdate = false
    private var shouldShow = false

    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let stateLabel = NSTextField(labelWithString: "Checking displays")
    private let pairingSwitch = NSSwitch()
    private let loginButton = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let swapButton = NSButton()
    private let leftCard = SpeakerCard(side: "Left")
    private let rightCard = SpeakerCard(side: "Right")
    private let footerLabel = NSTextField(wrappingLabelWithString: "Volume keys control both displays.")

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["pairingEnabled": true])
        enabled = defaults.bool(forKey: "pairingEnabled")
        leftUID = defaults.string(forKey: "leftDisplayUID") ?? ""
        let args = CommandLine.arguments
        disableLoginOnStart = args.contains("--disable-login-and-quit")
        shouldShow = args.contains("--show")
        quitForUpdate = args.contains("--quit-for-update")
        do {
            try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let lockURL = runtime.appendingPathComponent("app.lock")
            if !FileManager.default.fileExists(atPath: lockURL.path) {
                FileManager.default.createFile(atPath: lockURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            appLock = try FileHandle(forUpdating: lockURL)
            guard flock(appLock!.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                let request = disableLoginOnStart ? "disable-login.request" : (quitForUpdate ? "quit.request" : "show.request")
                try Data().write(to: runtime.appendingPathComponent(request), options: .atomic)
                NSApp.terminate(nil)
                return
            }
        } catch { NSLog("Studio Pair could not open its runtime: %@", error.localizedDescription); NSApp.terminate(nil); return }
        log("app_start pid=\(getpid()) bundle=\(Bundle.main.bundleURL.path)")
        makeInterface()
        if disableLoginOnStart {
            enabled = false
            defaults.set(false, forKey: "pairingEnabled")
            setLogin(false)
            quitting = true
        } else if quitForUpdate { quitting = true }
        else if args.contains("--enable-login") { setLogin(true) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }; self.sleeping = true; self.stopWorker()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false; self?.nextAttempt = Date().addingTimeInterval(2)
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.spotify.client", let self = self else { return }
                if name == NSWorkspace.didTerminateApplicationNotification { self.stopWorker() }
                self.backoff = 5; self.nextAttempt = Date().addingTimeInterval(2)
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        // Recover a prior process before considering a new route.
        restore()
        if shouldShow { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPopover() } }
    }

    private func makeInterface() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "hifispeaker.2", accessibilityDescription: "Studio Pair")
        item.button?.image?.isTemplate = true
        item.button?.setAccessibilityLabel("Studio Pair")
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.animates = true
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 364))
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 17
        controller.view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 20)
        ])
        let title = NSTextField(labelWithString: "Studio Pair")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        stateLabel.font = .systemFont(ofSize: 12)
        stateLabel.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, stateLabel])
        heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 3
        stack.addArrangedSubview(heading)
        let pairLabel = NSTextField(labelWithString: "Stereo pairing")
        pairLabel.font = .systemFont(ofSize: 13, weight: .medium)
        pairingSwitch.target = self; pairingSwitch.action = #selector(togglePairing)
        pairingSwitch.setAccessibilityLabel("Stereo pairing")
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toggleRow = NSStackView(views: [pairLabel, spacer, pairingSwitch])
        stack.addArrangedSubview(toggleRow); toggleRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        swapButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Swap left and right")
        swapButton.bezelStyle = .recessed; swapButton.isBordered = false
        swapButton.target = self; swapButton.action = #selector(swapSides)
        swapButton.toolTip = "Swap left and right"
        swapButton.setAccessibilityLabel("Swap left and right")
        swapButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        swapButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let speakers = NSStackView(views: [leftCard, swapButton, rightCard]); speakers.spacing = 4
        stack.addArrangedSubview(speakers)
        footerLabel.font = .systemFont(ofSize: 11); footerLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(footerLabel)
        let divider = NSBox(); divider.boxType = .separator
        stack.addArrangedSubview(divider); divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        loginButton.target = self; loginButton.action = #selector(toggleLogin)
        loginButton.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(loginButton)
        let quit = NSButton(title: "Quit Studio Pair", target: self, action: #selector(quitApp))
        quit.isBordered = false; quit.font = .systemFont(ofSize: 11)
        retryButton.isBordered = false; retryButton.font = .systemFont(ofSize: 11)
        retryButton.target = self; retryButton.action = #selector(retry)
        let bottomSpacer = NSView(); bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [retryButton, bottomSpacer, quit])
        stack.addArrangedSubview(bottom); bottom.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        refresh()
    }

    @objc private func togglePopover() { popover.isShown ? popover.performClose(nil) : showPopover() }
    private func showPopover() {
        guard let button = item?.button else { return }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPopover(); return true }

    private func refresh() {
        guard item != nil else { return }
        let recovering = restoring || ending || needsRestore
        let text = recovering ? (needsRestore ? "Reconnect displays to restore audio" : "Restoring direct playback") : (!enabled ? "Off · direct playback" : phase)
        stateLabel.stringValue = text
        stateLabel.textColor = active ? .systemGreen : .secondaryLabelColor
        pairingSwitch.state = enabled ? .on : .off
        pairingSwitch.isEnabled = !quitting
        item.button?.toolTip = "Studio Pair · \(text)"
        item.button?.appearsDisabled = !enabled
        let swapped = !anchorUID.isEmpty && leftUID != anchorUID
        leftCard.assignment.stringValue = swapped ? "Display B" : "Display A"
        rightCard.assignment.stringValue = swapped ? "Display A" : "Display B"
        swapButton.isEnabled = inventory?.displays.count == 2 && !ending && !restoring
        footerLabel.stringValue = recovering ? "Finishing audio recovery…" : (enabled ? "Spotify · volume keys control both displays." : "Your normal audio output is restored.")
        retryButton.isHidden = active || !enabled
        let login = SMAppService.mainApp.status
        loginButton.state = login == .enabled ? .on : (login == .requiresApproval ? .mixed : .off)
        loginButton.title = login == .requiresApproval ? "Approve launch at login…" : "Launch at login"
        publish()
    }

    @objc private func togglePairing() {
        enabled = pairingSwitch.state == .on
        defaults.set(enabled, forKey: "pairingEnabled")
        lastFailure = nil; backoff = 5; nextAttempt = .distantPast
        if enabled { tryStart() } else { stopWorker() }
        refresh()
    }
    @objc private func swapSides() {
        guard let displays = inventory?.displays, displays.count == 2,
              let next = displays.first(where: { $0.uid != leftUID }) else { return }
        leftUID = next.uid
        defaults.set(leftUID, forKey: "leftDisplayUID")
        if worker != nil { try? input?.write(contentsOf: Data("swap\n".utf8)) }
        refresh()
    }
    @objc private func retry() { lastFailure = nil; backoff = 5; nextAttempt = .distantPast; tryStart() }
    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); return }
        setLogin(loginButton.state == .on)
    }
    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval { try SMAppService.mainApp.unregister() }
            log("login_status=\(SMAppService.mainApp.status.rawValue)")
        } catch { log("login_error=\(error.localizedDescription)"); phase = "Login setting needs attention" }
        refresh()
    }

    private func tick() {
        for (name, action) in [("stop.request", 0), ("disable-login.request", 1), ("show.request", 2), ("quit.request", 3)] {
            let file = runtime.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.removeItem(at: file)
                if action == 2 { showPopover() }
                else if action == 3 { NSApp.terminate(nil) }
                else {
                    enabled = false; defaults.set(false, forKey: "pairingEnabled")
                    if action == 1 { setLogin(false); NSApp.terminate(nil) }
                    else { stopWorker() }
                }
            }
        }
        if let p = worker, p.isRunning, Date().timeIntervalSince(lastEvent) > 15, !ending {
            lastFailure = "Audio worker stopped responding"
            log("watchdog_stop")
            stopWorker()
        }
        if worker == nil && Date() >= nextAttempt {
            if needsRestore { restore() } else { tryStart() }
        }
    }

    private func tryStart() {
        guard enabled && !sleeping && !quitting && !restoring && !needsRestore && !ending && worker == nil && !inspecting else { return }
        inspecting = true; nextAttempt = Date().addingTimeInterval(5)
        command(["inspect"]) { [weak self] code, data in
            guard let self = self else { return }; self.inspecting = false
            guard self.enabled && !self.sleeping && !self.quitting && self.worker == nil && !self.restoring && !self.needsRestore else { return }
            guard code == 0, let info = try? JSONDecoder().decode(Inventory.self, from: data) else {
                self.phase = "Waiting for audio devices"; self.nextAttempt = Date().addingTimeInterval(10); self.refresh(); return
            }
            self.inventory = info
            guard info.displays.count == 2 else { self.phase = "Connect both Studio Displays"; self.refresh(); return }
            guard let anchor = info.displays.first(where: { $0.id == info.default_output }) else {
                self.phase = "Waiting for Studio Display output"; self.refresh(); return
            }
            self.anchorUID = anchor.uid
            if !info.displays.contains(where: { $0.uid == self.leftUID }) {
                self.leftUID = anchor.uid; self.defaults.set(self.leftUID, forKey: "leftDisplayUID")
            }
            guard info.processes.contains(where: { ($0.bundle == "com.spotify.client" || $0.bundle.hasPrefix("com.spotify.client.")) && $0.running != 0 }) else {
                self.phase = "Ready · waiting for Spotify"; self.refresh(); return
            }
            self.startWorker()
        }
    }

    private func startWorker() {
        guard worker == nil && !restoring && !needsRestore && enabled && !sleeping && !quitting else { return }
        ending = false; active = false; lastFailure = nil; buffer = ""; lastWorkerState = ""; lastEvent = Date()
        let p = Process(); let out = Pipe(); let stdin = Pipe()
        p.executableURL = engine
        p.arguments = ["run", journal.path, "0", String(getpid()), "com.spotify.client", "0", leftUID == anchorUID ? "0" : "1"]
        p.standardOutput = out; p.standardError = out; p.standardInput = stdin
        input = stdin.fileHandleForWriting; worker = p
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { guard self?.worker === p else { return }; self?.consume(String(decoding: data, as: UTF8.self)) }
        }
        p.terminationHandler = { [weak self] p in DispatchQueue.main.async { self?.ended(p) } }
        do {
            try p.run(); log("worker_start pid=\(p.processIdentifier) continuous=true")
            phase = "Connecting Spotify"; refresh()
        } catch { log("worker_launch_error=\(error)"); worker = nil; input = nil; restore() }
    }

    private func consume(_ text: String) {
        buffer += text
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound]); buffer = String(buffer[range.upperBound...])
            guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let state = obj["state"] as? String else {
                if line.hasPrefix("Studio Pair:") { lastFailure = line; log(line) }
                continue
            }
            lastEvent = Date()
            if state != lastWorkerState || Date().timeIntervalSince(lastMeterLog) >= 60 {
                log(line); lastMeterLog = Date(); lastWorkerState = state
            }
            if state == "playing" { active = true; phase = "Stereo active"; backoff = 5 }
            else if state == "warming" { phase = "Waiting for music" }
            refresh()
        }
    }

    private func stopWorker() {
        guard let p = worker else { restore(); return }
        if ending { return }
        ending = true; active = false; phase = "Restoring direct playback"; refresh()
        try? input?.write(contentsOf: Data("stop\n".utf8))
        if p.isRunning { p.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
    }
    private func ended(_ p: Process) {
        guard worker === p else { return }
        log("worker_exit=\(p.terminationStatus)")
        if p.terminationStatus != 0 && !ending { backoff = min(60, backoff * 2) }
        worker = nil; input = nil; active = false
        restore()
    }
    private func restore() {
        guard !restoring else { return }
        restoring = true; active = false; refresh()
        command(["restore", journal.path]) { [weak self] code, data in
            guard let self = self else { return }
            self.restoring = false; self.ending = false
            self.needsRestore = code != 0
            self.log("restore_exit=\(code) \(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
            if code != 0 { self.phase = "Reconnect displays to restore audio"; self.nextAttempt = Date().addingTimeInterval(15) }
            else { self.phase = self.enabled ? "Ready · waiting for Spotify" : "Off · direct playback"; self.nextAttempt = Date().addingTimeInterval(self.backoff) }
            self.refresh()
            if self.quitting { NSApp.reply(toApplicationShouldTerminate: true); if self.disableLoginOnStart || self.quitForUpdate { NSApp.terminate(nil) } }
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true
        if worker != nil || restoring { stopWorker(); return .terminateLater }
        return .terminateNow
    }

    private func command(_ args: [String], done: @escaping (Int32, Data) -> Void) {
        let exe = engine
        DispatchQueue.global().async {
            let p = Process(); let out = Pipe()
            p.executableURL = exe; p.arguments = args; p.standardOutput = out; p.standardError = out
            do {
                try p.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
                let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                DispatchQueue.main.async { done(p.terminationStatus, data) }
            } catch { DispatchQueue.main.async { done(-1, Data(error.localizedDescription.utf8)) } }
        }
    }
    private func log(_ line: String) {
        let path = runtime.appendingPathComponent("events.log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path), let bytes = attrs[.size] as? NSNumber, bytes.intValue > 1_048_576 {
            let old = runtime.appendingPathComponent("events.previous.log")
            try? FileManager.default.removeItem(at: old); try? FileManager.default.moveItem(at: path, to: old)
        }
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let f = try? FileHandle(forWritingTo: path) {
            _ = try? f.seekToEnd(); try? f.write(contentsOf: Data((ISO8601DateFormatter().string(from: Date()) + " " + line + "\n").utf8)); try? f.close()
        }
    }
    private func publish() {
        let status: [String: Any] = ["version": 2, "enabled": enabled, "phase": phase, "active": active,
            "workerPID": worker?.processIdentifier ?? 0, "appPID": getpid(), "loginStatus": SMAppService.mainApp.status.rawValue,
            "bundlePath": Bundle.main.bundleURL.path, "leftDisplayUID": leftUID, "anchorUID": anchorUID,
            "restoring": restoring, "sleeping": sleeping, "lastFailure": lastFailure ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]), data != lastPublished else { return }
        lastPublished = data
        let path = runtime.appendingPathComponent("status.json")
        try? data.write(to: path, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

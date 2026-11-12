import AppKit

/// The helper owns the screen mutation and outlives an app crash long enough to undo it.
final class DisplayMode {
    private let defaults = UserDefaults.standard
    private let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/studio-pair-display")
    private var guardian: Process?
    private var ownerPipe: Pipe?
    private var restoring = false
    private var paused = false
    private var retryAfter = Date.distantPast
    private var buffer = ""
    var changed: (() -> Void)?
    private(set) var status = "MacBook screen on"
    var enabled: Bool {
        get { defaults.bool(forKey: "studioDisplaysOnly") }
        set { defaults.set(newValue, forKey: "studioDisplaysOnly"); retryAfter = .distantPast; tick() }
    }
    var supported: Bool { SPDisplayControlAvailable() }
    private var ownedID: UInt32 { UInt32(clamping: defaults.integer(forKey: "ownedBuiltinDisplayID")) }

    func start() { recover() }

    func suspend(_ value: Bool) { paused = value; tick() }
    func stop() { paused = true; closeOwner(); if guardian == nil { recover() } }

    func tick() {
        if !enabled || paused {
            closeOwner()
            if guardian == nil { recover() }
            if ownedID == 0 { update("MacBook screen on") }
            return
        }
        guard !restoring, guardian == nil, Date() >= retryAfter else { return }
        guard ownedID == 0 else { recover(); return }
        guard supported else { update("Screen control unavailable on this macOS"); return }
        guard SPStudioDisplayCount() >= 2 else { update("Connect both Studio Displays"); return }
        let id = SPBuiltinDisplay()
        guard id != 0, SPDisplayActive(id) else { update("MacBook screen already off"); return }
        // Persist ownership before changing hardware so a restart can recover it.
        defaults.set(Int(id), forKey: "ownedBuiltinDisplayID")
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = helper; process.arguments = ["--watch", String(id)]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guardian = process; ownerPipe = input; buffer = ""
        update("Turning MacBook screen off…")
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self, self.guardian === process else { return }
                self.buffer += String(decoding: data, as: UTF8.self)
                if self.buffer.contains("off\n") { self.update("MacBook screen off · 2 Studio Displays") }
            }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.guardian === process else { return }
                self.guardian = nil; self.ownerPipe = nil
                self.retryAfter = Date().addingTimeInterval(5)
                self.recover()
            }
        }
        do { try process.run(); try? input.fileHandleForReading.close() }
        catch { guardian = nil; ownerPipe = nil; retryAfter = Date().addingTimeInterval(30); recover() }
    }

    private func closeOwner() {
        try? ownerPipe?.fileHandleForWriting.close()
        ownerPipe = nil
    }

    private func recover() {
        guard ownedID != 0, !restoring, guardian == nil else { return }
        let id = ownedID
        restoring = true; update("Restoring MacBook screen…")
        let process = Process()
        process.executableURL = helper; process.arguments = ["--restore", String(id)]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                self.restoring = false
                if process.terminationStatus == 0 {
                    self.defaults.removeObject(forKey: "ownedBuiltinDisplayID")
                    self.update("MacBook screen on")
                } else {
                    self.retryAfter = Date().addingTimeInterval(5)
                    self.update("Screen restore needs retry")
                }
            }
        }
        do { try process.run() }
        catch { restoring = false; retryAfter = Date().addingTimeInterval(30); update("Screen helper unavailable") }
    }

    private func update(_ text: String) {
        guard status != text else { return }
        status = text; changed?()
    }
}

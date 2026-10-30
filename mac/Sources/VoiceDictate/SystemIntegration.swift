import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

// MARK: - Paste

/// Pastes transcripts one at a time: clipboard -> Cmd+V -> short gap so the target app
/// has read the clipboard before it changes again. Transcripts that arrive during the gap
/// are joined and pasted together. Afterwards your previous clipboard is put back, unless
/// something else changed the clipboard in the meantime.
@MainActor
final class Paster {
    private static let pasteGap = 0.2          // let the target app read the clipboard
    private static let restoreDelay = 1.5
    private static let maxSnapshotBytes = 20_000_000

    private enum Item { case text(String), enter }
    private var queue: [Item] = []
    private var busy = false
    private var saved: [NSPasteboardItem]?
    private var ourChangeCount = -1
    private var restoreWork: DispatchWorkItem?
    private var autoPaste = true
    private var restoreClipboard = true

    func deliver(_ text: String, autoPaste: Bool, restoreClipboard: Bool) {
        self.autoPaste = autoPaste
        self.restoreClipboard = restoreClipboard
        queue.append(.text(text))
        if !busy { pasteNext() }
    }

    /// Presses Return after any text still waiting to be pasted.
    func pressEnter() {
        queue.append(.enter)
        if !busy { pasteNext() }
    }

    private func pasteNext() {
        guard let first = queue.first else { busy = false; scheduleRestore(); return }
        busy = true
        if case .enter = first {
            queue.removeFirst()
            if AXIsProcessTrusted() { Self.pressKey(CGKeyCode(kVK_Return), flags: []) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteGap) { [weak self] in self?.pasteNext() }
            return
        }
        // Join the text waiting before the next Enter into one paste.
        var parts: [String] = []
        while case .text(let t)? = queue.first { parts.append(t); queue.removeFirst() }
        let text = parts.joined(separator: " ")

        let pb = NSPasteboard.general
        let canPaste = autoPaste && AXIsProcessTrusted()
        restoreWork?.cancel()
        // Snapshot whatever the user has on the clipboard now (anything not written by us).
        if restoreClipboard && canPaste && pb.changeCount != ourChangeCount {
            saved = Self.snapshot(pb)
        }
        pb.clearContents()
        pb.setString(text + " ", forType: .string)
        ourChangeCount = pb.changeCount

        if canPaste { Self.pressCmdV() }
        else if autoPaste { Log.warn("[Paste] No Accessibility permission; text left on the clipboard") }
        if !canPaste { saved = nil }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteGap) { [weak self] in
            self?.pasteNext()
        }
    }

    private func scheduleRestore() {
        guard saved != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.busy else { return }
            let pb = NSPasteboard.general
            if pb.changeCount == self.ourChangeCount, let items = self.saved, !items.isEmpty {
                pb.clearContents()
                pb.writeObjects(items)
            }
            self.saved = nil
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay, execute: work)
    }

    /// Copies the clipboard's items. Skips restoring huge clipboards (e.g. big images).
    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem]? {
        var total = 0
        var items: [NSPasteboardItem] = []
        for item in pb.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            var any = false
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > maxSnapshotBytes {
                    Log.info("[Paste] Clipboard too large to restore; leaving the transcript on it")
                    return nil
                }
                copy.setData(data, forType: type)
                any = true
            }
            if any { items.append(copy) }
        }
        return items
    }

    private static func pressCmdV() { pressKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand) }

    private static func pressKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - F5 / Dictation key

/// Catches the MacBook's microphone (F5 / Dictation) key and swallows it so Apple
/// Dictation doesn't open. The key arrives as keyDown/keyUp with keycode 176.
/// The tap runs on its own thread so a busy main thread can never stall typing.
final class MicKeyMonitor {
    static let dictationKeyCode: Int64 = 176

    var onPress: (() -> Void)?
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    }

    /// Creates the tap if it doesn't exist or has died (e.g. Accessibility was revoked and re-granted).
    @discardableResult
    func start() -> Bool {
        if isActive { return true }
        stop()
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: micKeyCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
            else { ready.signal(); return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let rl = CFRunLoopGetCurrent()
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.lock.lock()
            self.tap = tap; self.source = source; self.runLoop = rl
            self.lock.unlock()
            ok = true
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "vd.mic-key"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        if ok { Log.info("[Key] Listening for the F5 / Dictation key") }
        return ok
    }

    func stop() {
        lock.lock()
        let (tap, source, rl) = (self.tap, self.source, self.runLoop)
        self.tap = nil; self.source = nil; self.runLoop = nil
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let rl {
            if let source { CFRunLoopRemoveSource(rl, source, .commonModes) }
            CFRunLoopStop(rl)
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let tap = self.tap; lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp,
              event.getIntegerValueField(.keyboardEventKeycode) == Self.dictationKeyCode else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { self.onPress?() }
        }
        return nil  // swallow down, repeats and up so Dictation / Siri never see it
    }
}

private func micKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<MicKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}

// MARK: - Permissions

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

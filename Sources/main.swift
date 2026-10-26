// LayoutFixer — notices words typed in the wrong keyboard layout (English <-> Persian),
// shows a small popup near the cursor, and on Tab retypes them and switches the layout.

import Cocoa
import Carbon
import ApplicationServices

// MARK: - Keyboard layouts

/// Marks events we post ourselves so the tap ignores them.
let injectedMarker: Int64 = 0x4C46_4958 // "LFIX"

struct Layout {
    let source: TISInputSource
    let id: String
    let lang: String // "en" or "fa"
    let keyData: Data

    var displayName: String { lang == "fa" ? "فارسی" : "English" }

    /// The character this layout produces for a physical key.
    func character(keyCode: UInt16, shift: Bool) -> String? {
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        let status = keyData.withUnsafeBytes { raw -> OSStatus in
            UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!,
                           keyCode, UInt16(kUCKeyActionDown), modifiers,
                           UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                           &dead, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
    guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? T
}

func makeLayout(_ source: TISInputSource) -> Layout? {
    guard let id: String = property(source, kTISPropertyInputSourceID),
          let data: Data = property(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let langs: [String] = property(source, kTISPropertyInputSourceLanguages) ?? []
    guard let lang = langs.first.flatMap({ l -> String? in
        l.hasPrefix("fa") ? "fa" : l.hasPrefix("en") ? "en" : nil
    }) else { return nil }
    return Layout(source: source, id: id, lang: lang, keyData: data)
}

/// Enabled English and Persian keyboard layouts, one per language.
func enabledLayouts() -> [String: Layout] {
    let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
    let list = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
    var result: [String: Layout] = [:]
    for source in list {
        if let layout = makeLayout(source), result[layout.lang] == nil { result[layout.lang] = layout }
    }
    return result
}

func currentLayout() -> Layout? {
    makeLayout(TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue())
}

// MARK: - Dictionaries

/// Decides whether a word was typed on the wrong layout, in either direction.
/// A suggestion is only made when the other reading is a real word, so names, brands
/// and typos ("github", "teh") are left alone.
final class Dictionaries {
    /// Rank in the English frequency list (0 = most common).
    private var enRank: [String: Int] = [:]
    /// Rank in the Persian frequency list.
    private var faRank: [String: Int] = [:]
    /// Every English word we know, including rare ones from /usr/share/dict/words.
    private var enAll: Set<String> = []
    /// Only the most common Persian words count as a real reading; the long tail of the list is noisy.
    private let faLimit = 30000

    init(directory: URL) {
        enRank = Dictionaries.load(directory.appendingPathComponent("en_50k.txt"))
        faRank = Dictionaries.load(directory.appendingPathComponent("fa_50k.txt"))
        enAll = Set(enRank.keys)
        if let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) {
            for line in text.split(separator: "\n") { enAll.insert(line.lowercased()) }
        }
    }

    private static func load(_ url: URL) -> [String: Int] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var ranks: [String: Int] = [:]
        for (i, line) in text.split(separator: "\n").enumerated() {
            guard let word = line.split(separator: " ").first else { continue }
            let w = normalize(String(word))
            if ranks[w] == nil { ranks[w] = i }
        }
        return ranks
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "ي", with: "ی")
            .replacingOccurrences(of: "ك", with: "ک")
            .trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
    }

    private func persianRank(_ s: String) -> Int? {
        guard let r = faRank[Dictionaries.normalize(s)], r < faLimit else { return nil }
        return r
    }

    /// True when the word was typed on the wrong layout.
    /// `minLetters` guards against short words, which are often ambiguous (شد is "an" on English keys).
    func isMistake(typed: String, typedLang: String, converted: String, minLetters: Int = 3) -> Bool {
        if typedLang == "fa" {
            // Typed on Persian keys: the English reading must be a common English word,
            // and more common than the Persian word itself if the typed text is real Persian.
            let english = Dictionaries.normalize(converted)
            guard english.count >= minLetters, english.allSatisfy(\.isASCII), let en = enRank[english] else { return false }
            if let fa = persianRank(typed) { return en < fa }
            return true
        }
        // Typed on English keys: never touch a real English word, and only suggest Persian
        // when the Persian reading is a real Persian word. ", ; ' [ ]" are Persian letters on
        // English keys (و ک گ ج چ), so they can sit inside the word.
        let english = Dictionaries.normalize(typed)
        let persianKeys = Set(",;'[]")
        guard english.count >= minLetters, english.allSatisfy({ $0.isLetter || persianKeys.contains($0) }),
              english.contains(where: \.isLetter), !enAll.contains(english) else { return false }
        // don't, it's, ...
        if let stem = english.split(separator: "'").first, english.contains("'"), enAll.contains(String(stem)) { return false }
        return persianRank(converted) != nil
    }
}

// MARK: - Popup

final class Popup {
    private let panel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 54),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 9

        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingHead
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        panel.contentView = bg
    }

    var isVisible: Bool { panel.isVisible }

    func show(suggestion: String, target: String) {
        title.stringValue = suggestion
        hint.stringValue = "⇥ Tab: fix & switch to \(target)   ·   esc: ignore"
        panel.setContentSize(panel.contentView!.fittingSize)
        // Wait a moment so the app has drawn the space we just saw, then find the caret.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [self] in
            place()
            panel.orderFrontRegardless()
        }
    }

    func hide() { panel.orderOut(nil) }

    private func place() {
        let size = panel.frame.size
        let anchor = caretRect() ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            if origin.y < f.minY { origin.y = anchor.maxY + 6 }
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
        }
        panel.setFrameOrigin(origin)
    }

    /// Screen rect of the text cursor in the focused app, via the Accessibility API.
    private func caretRect() -> NSRect? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                            kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let el = element as! AXUIElement
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rv = rangeValue else { return nil }
        var range = CFRange()
        AXValueGetValue(rv as! AXValue, .cfRange, &range)
        if range.length == 0 && range.location > 0 { range = CFRange(location: range.location - 1, length: 1) }
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                        param, &boundsValue) == .success,
              let bv = boundsValue else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(bv as! AXValue, .cgRect, &rect)
        guard rect.width > 0 || rect.height > 0, let primary = NSScreen.screens.first else { return nil }
        // AX uses a top-left origin; Cocoa uses bottom-left.
        return NSRect(x: rect.minX, y: primary.frame.height - rect.maxY, width: rect.width, height: rect.height)
    }
}

// MARK: - Typing tracker

struct Key {
    let code: UInt16
    let shift: Bool
    let typed: String
}

final class Fixer {
    let dicts: Dictionaries
    let popup = Popup()
    var enabled = true

    private var word: [Key] = []
    /// The word finished just before `word`, if only a single space separates them.
    private var previous: [Key] = []
    /// Keystrokes from the first wrong word up to now, while the popup is showing.
    private var run: [Key] = []
    private var runLayoutID: String?
    private var runWords = 0
    private var hideTimer: Timer?

    init(dicts: Dictionaries) { self.dicts = dicts }

    func reset() {
        word.removeAll()
        previous.removeAll()
        run.removeAll()
        runLayoutID = nil
        runWords = 0
        hideTimer?.invalidate()
        popup.hide()
    }

    /// Returns false to swallow the event.
    func handle(_ event: CGEvent) -> Bool {
        guard enabled else { return true }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if !flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]) { reset(); return true }

        switch Int(code) {
        case kVK_Tab:
            if popup.isVisible && !run.isEmpty { apply(); return false }
            reset()
        case kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter, kVK_ForwardDelete,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            reset()
        case kVK_Delete:
            if !word.isEmpty { word.removeLast() }
            if !run.isEmpty {
                run.removeLast()
                if run.isEmpty { reset() } else { refreshPopup() }
            }
        case kVK_Space:
            let key = Key(code: code, shift: false, typed: " ")
            if !run.isEmpty { run.append(key) }
            finishWord(space: key)
        default:
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
            let typed = String(utf16CodeUnits: chars, count: length)
            guard !typed.isEmpty, typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { reset(); return true }
            let key = Key(code: code, shift: flags.contains(.maskShift), typed: typed)
            word.append(key)
            if !run.isEmpty { run.append(key); refreshPopup() }
        }
        return true
    }

    private func finishWord(space: Key) {
        let finished = word
        defer { word.removeAll(); previous = finished }
        guard !word.isEmpty, let current = currentLayout() else { return }

        if !run.isEmpty {
            // Already showing a suggestion: keep extending it, unless the user switched layouts.
            runWords += 1
            if current.id != runLayoutID || runWords > 12 { reset() } else { refreshPopup() }
            return
        }

        guard let other = enabledLayouts().values.first(where: { $0.lang != current.lang }) else { return }
        if looksWrong(word, current, other) {
            // A short word just before (like هد → "in") is usually part of the same mistake.
            let before = looksWrong(previous, current, other, minLetters: 1) ? previous + [space] : []
            run = before + word + [space]
            runLayoutID = current.id
            runWords = 1
            refreshPopup()
        }
    }

    private func looksWrong(_ keys: [Key], _ current: Layout, _ other: Layout, minLetters: Int = 3) -> Bool {
        !keys.isEmpty && dicts.isMistake(typed: keys.map(\.typed).joined(), typedLang: current.lang,
                                         converted: convert(keys, to: other), minLetters: minLetters)
    }

    private func targetLayout() -> Layout? {
        guard let current = currentLayout() else { return nil }
        return enabledLayouts().values.first(where: { $0.lang != current.lang })
    }

    private func convert(_ keys: [Key], to layout: Layout) -> String {
        keys.map { $0.code == UInt16(kVK_Space) ? " " : (layout.character(keyCode: $0.code, shift: $0.shift) ?? $0.typed) }
            .joined()
    }

    private func refreshPopup() {
        guard let target = targetLayout() else { return }
        popup.show(suggestion: convert(run, to: target).trimmingCharacters(in: .whitespaces),
                   target: target.displayName)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in self?.reset() }
    }

    private func apply() {
        guard let target = targetLayout() else { reset(); return }
        let text = convert(run, to: target)
        let deletes = run.reduce(0) { $0 + $1.typed.count }
        reset()
        TISSelectInputSource(target.source)
        // Post after the tap returns so the Tab is fully swallowed first.
        DispatchQueue.main.async {
            for _ in 0..<deletes { postKey(UInt16(kVK_Delete)) }
            for ch in text { postText(String(ch)) }
        }
    }
}

func post(_ event: CGEvent?) {
    event?.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
    event?.post(tap: .cgSessionEventTap)
}

func postKey(_ code: UInt16) {
    post(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
    post(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false))
}

func postText(_ text: String) {
    let utf16 = Array(text.utf16)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
        e?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        post(e)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var fixer: Fixer!
    var statusItem: NSStatusItem!
    var tap: CFMachPort?
    let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggle), keyEquivalent: "")
    let permissionItem = NSMenuItem(title: "Waiting for Accessibility permission…", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        fixer = Fixer(dicts: Dictionaries(directory: Bundle.main.resourceURL!))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = Bundle.main.image(forResource: "MenuBarIcon") {
            icon.isTemplate = true
            icon.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = icon
        } else {
            statusItem.button?.title = "⌨︎ف"
        }
        statusItem.button?.toolTip = "LayoutFixer"
        let menu = NSMenu()
        enabledItem.target = self
        enabledItem.state = .on
        menu.addItem(permissionItem)
        menu.addItem(enabledItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LayoutFixer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.fixer.reset()
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        startTapWhenTrusted()
    }

    func startTapWhenTrusted() {
        guard AXIsProcessTrusted(), installTap() else {
            permissionItem.isHidden = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startTapWhenTrusted() }
            return
        }
        permissionItem.isHidden = true
    }

    func installTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let app = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let tap = app.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            case .leftMouseDown, .rightMouseDown:
                app.fixer.reset()
            case .keyDown:
                if event.getIntegerValueField(.eventSourceUserData) != injectedMarker,
                   !app.fixer.handle(event) { return nil }
            default: break
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    @objc func toggle() {
        fixer.enabled.toggle()
        fixer.reset()
        enabledItem.state = fixer.enabled ? .on : .off
        statusItem.button?.appearsDisabled = !fixer.enabled
    }
}

// MARK: - Command-line test mode:  LayoutFixer --test "فاهس هدسفثشی"

func runTest(_ text: String, dictDir: URL) {
    let dicts = Dictionaries(directory: dictDir)
    let layouts = enabledLayouts()
    print("layouts:", layouts.map { "\($0.key)=\($0.value.id)" }.sorted().joined(separator: ", "))
    let isPersian = text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
    guard let from = layouts[isPersian ? "fa" : "en"], let to = layouts[isPersian ? "en" : "fa"] else {
        print("need both an English and a Persian layout enabled"); return
    }
    // Reverse map: character -> physical key in the source layout.
    var keyFor: [String: (UInt16, Bool)] = [:]
    for code in UInt16(0)..<128 { for shift in [false, true] {
        if let c = from.character(keyCode: code, shift: shift), keyFor[c] == nil { keyFor[c] = (code, shift) }
    }}
    for w in text.split(separator: " ") {
        let keys = w.map { ch -> Key in
            let (code, shift) = keyFor[String(ch)] ?? (0xFFFF, false)
            return Key(code: code, shift: shift, typed: String(ch))
        }
        let converted = keys.map { to.character(keyCode: $0.code, shift: $0.shift) ?? $0.typed }.joined()
        let mistake = dicts.isMistake(typed: String(w), typedLang: from.lang, converted: converted)
        let short = dicts.isMistake(typed: String(w), typedLang: from.lang, converted: converted, minLetters: 1)
        print("\(w) -> \(converted)  \(mistake ? "FIX" : short ? "fix-if-next-is-wrong" : "ok")")
    }
}

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--test" {
    runTest(args[2], dictDir: Bundle.main.resourceURL!)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

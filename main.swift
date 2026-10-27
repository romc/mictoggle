// MicToggle — кнопка play/pause наушников (и клавиатуры) → вкл/выкл микрофона на уровне системы.
// Приложение регистрируется в macOS как «текущий плеер» (MPRemoteCommandCenter), поэтому rcd
// отдаёт TogglePlayPause ему, а не запускает Музыку. Режим перехвата (UserDefaults "interceptMode"):
// call — только пока микрофоном пользуется какая-то программа (звонок), always, off.
// Опция "playKeySwitch": клавиша play на клавиатуре (CGEventTap, нужен «Универсальный доступ»):
// одно нажатие — как обычно (переотправляем синтетический play, его маршрутизирует rcd),
// N быстрых нажатий ("switchPresses", 2–4) — смена режима музыка ↔ разговор с голосом.
// Кнопка BT-наушников через event tap не идёт.
// Выключение = громкость входа 0 (+ mute, если устройство умеет); кронджоб «громкость на 100»
// громкость 0 не трогает. Сборка — build.sh. https://github.com/romc/mictoggle
// Микрофон: системный по умолчанию или выбранный в меню (UserDefaults "micName").
import Cocoa
import CoreAudio
import MediaPlayer
import ServiceManagement
import AVFoundation

let repoURL = "https://github.com/romc/mictoggle"

/// Метка наших синтетических событий play, чтобы event tap их пропускал.
let synthMark: Int64 = 0x4D69_6354

/// Имя выбранного микрофона; nil — системный по умолчанию.
var micName: String? {
    get { UserDefaults.standard.string(forKey: "micName") }
    set { UserDefaults.standard.set(newValue, forKey: "micName") }
}

// MARK: CoreAudio

func prop(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
}

func allDevices() -> [AudioDeviceID] {
    var a = prop(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceName(_ id: AudioDeviceID) -> String {
    var a = prop(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name) == noErr, let n = name else { return "" }
    return n.takeRetainedValue() as String
}

func hasInput(_ id: AudioDeviceID) -> Bool {
    var a = prop(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size > 0
}

func defaultInput() -> AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }
func defaultOutput() -> AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

func defaultDevice(_ sel: AudioObjectPropertySelector) -> AudioDeviceID? {
    var a = prop(sel)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
    return id
}

func inputDevices() -> [AudioDeviceID] { allDevices().filter(hasInput) }

func findMic() -> AudioDeviceID? {
    if let name = micName, let id = inputDevices().first(where: { deviceName($0) == name }) { return id }
    return defaultInput()
}

/// Элементы (master и каналы), у которых есть настраиваемое свойство на входе.
func settableElements(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
    [kAudioObjectPropertyElementMain, 1, 2].filter { el in
        var a = prop(sel, kAudioObjectPropertyScopeInput, el)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &a) && AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
    }
}

func getVolume(_ id: AudioDeviceID) -> Float? {
    guard let el = settableElements(id, kAudioDevicePropertyVolumeScalar).first else { return nil }
    var a = prop(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, el)
    var v: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
}

func setVolume(_ id: AudioDeviceID, _ v: Float) {
    for el in settableElements(id, kAudioDevicePropertyVolumeScalar) {
        var a = prop(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, el)
        var val = Float32(v)
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &val)
    }
}

func getMute(_ id: AudioDeviceID) -> Bool? {
    guard let el = settableElements(id, kAudioDevicePropertyMute).first else { return nil }
    var a = prop(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput, el)
    var m: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &m) == noErr ? m != 0 : nil
}

func setMute(_ id: AudioDeviceID, _ on: Bool) {
    for el in settableElements(id, kAudioDevicePropertyMute) {
        var a = prop(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput, el)
        var val: UInt32 = on ? 1 : 0
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &val)
    }
}

/// Устройство сейчас кем-то открыто (микрофон — звонок/запись, выход — что-то играет).
func isInUse(_ id: AudioDeviceID) -> Bool {
    var a = prop(kAudioDevicePropertyDeviceIsRunningSomewhere)
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr && v != 0
}

enum Mode: String, CaseIterable {
    case call, always, off
    var title: String {
        switch self {
        case .call: return "Только во время звонка"
        case .always: return "Всегда"
        case .off: return "Не перехватывать (музыка)"
        }
    }
}

var mode: Mode {
    get { Mode(rawValue: UserDefaults.standard.string(forKey: "interceptMode") ?? "") ?? .call }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "interceptMode") }
}

func isOff(_ id: AudioDeviceID) -> Bool {
    (getVolume(id).map { $0 < 0.005 } ?? false) || (getMute(id) ?? false)
}

// MARK: App

final class App: NSObject, NSApplicationDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var saved: Float = 1.0
    var hud: NSPanel?

    let micMenu = NSMenu()
    let modeMenu = NSMenu()
    var claimed = false
    var targets: [(MPRemoteCommand, Any)] = []
    let loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
    let playKeyItem = NSMenuItem(title: "Play на клавиатуре: смена режима", action: #selector(togglePlayKey), keyEquivalent: "")
    var tap: CFMachPort?
    let pressesMenu = NSMenu()
    var presses = 0
    var pressTimer: Timer?
    let speech = AVSpeechSynthesizer()

    var switchPresses: Int {
        get { let v = UserDefaults.standard.integer(forKey: "switchPresses"); return (2...4).contains(v) ? v : 3 }
        set { UserDefaults.standard.set(newValue, forKey: "switchPresses") }
    }

    var playKeySwitch: Bool {
        get { UserDefaults.standard.bool(forKey: "playKeySwitch") }
        set { UserDefaults.standard.set(newValue, forKey: "playKeySwitch") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Вкл/выкл микрофон", action: #selector(toggle), keyEquivalent: "").target = self
        let micItem = NSMenuItem(title: "Микрофон", action: nil, keyEquivalent: "")
        micItem.submenu = micMenu
        menu.addItem(micItem)
        let modeItem = NSMenuItem(title: "Кнопка наушников", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
        menu.addItem(withTitle: "Перехватить кнопку снова", action: #selector(reclaim), keyEquivalent: "").target = self
        playKeyItem.target = self
        menu.addItem(playKeyItem)
        let pressesItem = NSMenuItem(title: "Смена режима клавишей play", action: nil, keyEquivalent: "")
        pressesItem.submenu = pressesMenu
        menu.addItem(pressesItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "О программе", action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        status.menu = menu

        update()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.update()
            self?.ensureTap()
        }
        ensureTap()
    }

    func commands() -> [MPRemoteCommand] {
        let cc = MPRemoteCommandCenter.shared()
        return [cc.togglePlayPauseCommand, cc.playCommand, cc.pauseCommand]
    }

    /// Нужно ли сейчас держать кнопку (по режиму и занятости микрофона).
    func wantClaim() -> Bool {
        switch mode {
        case .always: return true
        case .off: return false
        case .call: return findMic().map(isInUse) ?? false
        }
    }

    var started = false

    var outBusy = false
    var micBusy = false

    func update() {
        let want = wantClaim()
        if want != claimed {
            want ? claim() : release()
            if started { announce() }
        }
        started = true
        // Другой плеер (Яндекс Музыка, голосовое в Telegram), начав играть, забирает кнопку себе и
        // держит её и после паузы. Забираем назад, когда звук затих и когда начинается звонок.
        let out = defaultOutput().map(isInUse) ?? false
        let mic = findMic().map(isInUse) ?? false
        if claimed && ((outBusy && !out) || (!micBusy && mic)) { reassert() }
        outBusy = out
        micBusy = mic
        refresh()
    }

    /// Переход в «играет» делает нас текущим плеером снова (просто .playing повторно — не делает).
    func reassert() {
        MPNowPlayingInfoCenter.default().playbackState = .paused
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard self?.claimed == true else { return }
            MPNowPlayingInfoCenter.default().playbackState = .playing
        }
    }

    /// Звук и надпись: чем теперь управляет кнопка наушников.
    func announce() {
        show(claimed ? "🎙 Meet mode" : "🎵 Music mode")
        let u = AVSpeechUtterance(string: claimed ? "Meet mode" : "Music mode")
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        speech.stopSpeaking(at: .immediate)
        speech.speak(u)
    }

    @objc func pickMode(_ item: NSMenuItem) {
        if let m = item.representedObject as? String, let v = Mode(rawValue: m) { mode = v }
        update()
    }

    @objc func pickMic(_ item: NSMenuItem) {
        micName = item.representedObject as? String
        refresh()
    }

    // MARK: клавиша play на клавиатуре

    @objc func togglePlayKey() {
        playKeySwitch.toggle()
        if playKeySwitch {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(opts) {
                show("Разрешите MicToggle в «Универсальном доступе»")
            }
        }
        ensureTap()
    }

    /// Создать/снять event tap по настройке (разрешение могут выдать позже — проверяем по таймеру).
    func ensureTap() {
        if !playKeySwitch {
            if let t = tap {
                CGEvent.tapEnable(tap: t, enable: false)
                CFMachPortInvalidate(t)
                tap = nil
            }
            return
        }
        if let t = tap {
            if !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        guard AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1) << 14 // NX_SYSDEFINED
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, ref in
            if event.getIntegerValueField(.eventSourceUserData) == synthMark { return Unmanaged.passUnretained(event) }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let ref = ref, let t = Unmanaged<App>.fromOpaque(ref).takeUnretainedValue().tap {
                    CGEvent.tapEnable(tap: t, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
            let key = (ns.data1 & 0xFFFF0000) >> 16
            let down = ((ns.data1 & 0xFF00) >> 8) == 0xA
            guard key == 16 else { return Unmanaged.passUnretained(event) } // NX_KEYTYPE_PLAY
            if down, let ref = ref {
                let app = Unmanaged<App>.fromOpaque(ref).takeUnretainedValue()
                DispatchQueue.main.async { app.playKeyPressed() }
            }
            return nil // съедаем и нажатие, и отпускание
        }, userInfo: me) else { return }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    /// Нажатие play на клавиатуре: N подряд — смена режима, меньше — обычные play.
    func playKeyPressed() {
        presses += 1
        pressTimer?.invalidate()
        if presses >= switchPresses {
            presses = 0
            switchMode()
            return
        }
        pressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let n = self.presses
            self.presses = 0
            for _ in 0..<n { self.postPlay() }
        }
    }

    /// Синтетический play (down+up) — rcd отправит его текущему плееру (нам или музыке).
    func postPlay() {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                              modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                              timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                              data1: (16 << 16) | (state << 8), data2: -1)?.cgEvent else { continue }
            ev.setIntegerValueField(.eventSourceUserData, value: synthMark)
            ev.post(tap: .cghidEventTap)
        }
    }

    @objc func pickPresses(_ item: NSMenuItem) {
        switchPresses = item.tag
    }

    /// Музыка ↔ разговор.
    func switchMode() {
        mode = claimed ? .off : .always
        update()
    }

    @objc func about() {
        let text = """
        Кнопка play/pause на наушниках (и клавиатуре) выключает и включает микрофон во всей \
        системе — в любой программе для звонков, даже если её окно свёрнуто.

        Meet mode — кнопка управляет микрофоном, Music mode — музыкой. Режим: меню «Кнопка \
        наушников» или N нажатий play на клавиатуре.

        """
        let credits = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(string: repoURL, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .link: URL(string: repoURL)!]))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            show("Не удалось: \(error.localizedDescription)")
        }
    }

    /// Стать «текущим плеером» — кнопка приходит нам.
    func claim() {
        claimed = true
        if targets.isEmpty {
            for cmd in commands() {
                cmd.isEnabled = true
                let t = cmd.addTarget { [weak self] _ in
                    DispatchQueue.main.async { self?.toggle() }
                    return .success
                }
                targets.append((cmd, t))
            }
        }
        refresh()
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    /// Отдать кнопку обратно музыке.
    func release() {
        claimed = false
        // isEnabled=false не помогает — rcd всё равно шлёт команды нам; снимаем обработчики целиком.
        for (cmd, t) in targets {
            cmd.removeTarget(t)
            cmd.isEnabled = false
        }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Вручную забрать кнопку назад, если её перехватил другой плеер.
    @objc func reclaim() {
        if mode == .off { mode = .always }
        claim()
        reassert()
    }

    func refresh() {
        guard let id = findMic() else {
            status.button?.title = "🎙?"
            return
        }
        let off = isOff(id)
        status.button?.title = (off ? "🔇" : "🎙") + (claimed ? "" : "♪")
        guard claimed else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: off ? "Микрофон ВЫКЛ" : "Микрофон ВКЛ",
            MPMediaItemPropertyArtist: deviceName(id),
        ]
    }

    @objc func toggle() {
        guard let id = findMic() else {
            show("🎙 микрофон не найден")
            return
        }
        if isOff(id) {
            setMute(id, false)
            setVolume(id, saved > 0.005 ? saved : 1.0)
            show("🎙 микрофон ВКЛ")
            NSSound(named: "Pop")?.play()
        } else {
            saved = getVolume(id) ?? 1.0
            setVolume(id, 0)
            setMute(id, true)
            show("🔇 микрофон ВЫКЛ")
            NSSound(named: "Bottle")?.play()
        }
        refresh()
    }

    func show(_ text: String) {
        hud?.close()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 28, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 48, height: label.frame.height + 28)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        label.frame.origin = NSPoint(x: 24, y: 14)
        bg.addSubview(label)
        panel.contentView = bg
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.minY + screen.height * 0.15))
        }
        panel.orderFrontRegardless()
        hud = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak panel] in
            panel?.close()
            if self?.hud === panel { self?.hud = nil }
        }
    }
}

extension App: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        micMenu.removeAllItems()
        let def = NSMenuItem(title: "Системный по умолчанию", action: #selector(pickMic(_:)), keyEquivalent: "")
        def.target = self
        def.state = micName == nil ? .on : .off
        micMenu.addItem(def)
        micMenu.addItem(.separator())
        for id in inputDevices() {
            let name = deviceName(id)
            let it = NSMenuItem(title: name, action: #selector(pickMic(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = name
            it.state = micName == name ? .on : .off
            micMenu.addItem(it)
        }
        modeMenu.removeAllItems()
        for m in Mode.allCases {
            let it = NSMenuItem(title: m.title, action: #selector(pickMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.rawValue
            it.state = mode == m ? .on : .off
            modeMenu.addItem(it)
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        playKeyItem.state = playKeySwitch ? .on : .off
        pressesMenu.removeAllItems()
        for n in 2...4 {
            let it = NSMenuItem(title: "\(n) нажатия подряд", action: #selector(pickPresses(_:)), keyEquivalent: "")
            it.target = self
            it.tag = n
            it.state = switchPresses == n ? .on : .off
            pressesMenu.addItem(it)
        }
        playKeyItem.title = "Play на клавиатуре: \(switchPresses)× — смена режима"
            + (playKeySwitch && !AXIsProcessTrusted() ? " (нет разрешения)" : "")
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

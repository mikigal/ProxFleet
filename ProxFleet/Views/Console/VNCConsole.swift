import CoreGraphics
import GameController
import Network
import ProxmoxConsole
import ProxmoxCore
import PVEKit
import SwiftUI
import UIKit

/// How fingers drive the guest's mouse.
enum VNCMouseMode: String, CaseIterable, Identifiable {
    /// The screen is a trackpad: a finger moves the pointer, taps click where it is. Precise, and the finger
    /// does not cover what it points at, which suits desktops such as Windows.
    case trackpad
    /// The pointer goes where the finger touches, like a touch screen.
    case touch

    var id: String { rawValue }
}

/// How much the console compresses the screen; Automatic saves data on cellular and other metered networks.
enum VNCQualitySetting: String, CaseIterable, Identifiable {
    case automatic, best, balanced, dataSaver

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .best: "Best Quality"
        case .balanced: "Balanced"
        case .dataSaver: "Data Saver"
        }
    }
}

/// A modifier of the key bar.
enum VNCModifier: CaseIterable, Identifiable {
    case control, alt, shift, windows

    var id: Self { self }

    var keysym: UInt32 {
        switch self {
        case .control: KeySym.control
        case .alt: KeySym.alt
        case .shift: KeySym.shift
        case .windows: KeySym.superKey
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .control: "Ctrl"
        case .alt: "Alt"
        case .shift: "Shift"
        case .windows: "Win"
        }
    }
}

/// A modifier is off, held for the next key, or locked until tapped again.
enum ModifierState {
    case off, once, locked
}

/// Drives a `VNCClient`: turns its framebuffer into images, and touches, pointers and keys into input.
@MainActor
@Observable
final class VNCConsoleModel {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case closed(String?)
    }

    private(set) var state: State = .idle
    private(set) var image: CGImage?
    private(set) var screenSize = CGSize.zero
    /// The guest's pointer shape and its hotspot, when the server sends one.
    private(set) var cursor: (image: CGImage, hotspot: CGPoint)?
    /// Where the pointer is, in screen pixels.
    private(set) var pointer = CGPoint.zero
    /// Whether the screen size is known, so the pointer has a place; it starts in the middle.
    private(set) var hasPointer = false
    /// Data received since connecting.
    private(set) var receivedBytes = 0
    private(set) var modifiers: [VNCModifier: ModifierState] = [:]
    var mouseMode: VNCMouseMode = .trackpad
    /// The console is shown full screen, over the screen it was opened from.
    @ObservationIgnored var isInFullScreen = false
    var qualitySetting: VNCQualitySetting = .automatic {
        didSet { Task { await applyQuality() } }
    }

    @ObservationIgnored private let guest: GuestReference
    @ObservationIgnored private let session: ProxmoxSession
    @ObservationIgnored private var client: VNCClient?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var statistics: Task<Void, Never>?
    @ObservationIgnored private var renderPending = false
    @ObservationIgnored private var buttons: UInt8 = 0
    @ObservationIgnored private var modifierTapped: [VNCModifier: Date] = [:]
    /// Key-bar modifiers pressed with a hardware key, released with it.
    @ObservationIgnored private var barModifiersByKey: [Int: [UInt32]] = [:]
    @ObservationIgnored private var isMeteredNetwork = false
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    /// Input goes through one queue so that keys and clicks reach the VM in the order they happened.
    @ObservationIgnored private var input: AsyncStream<Input>.Continuation?
    @ObservationIgnored private var inputWorker: Task<Void, Never>?

    private enum Input {
        case text(String, modifiers: [UInt32])
        case keys([UInt32])
        case key(UInt32, down: Bool)
        case scancode(UInt16, keysym: UInt32, down: Bool)
        case pointer(CGPoint, buttons: UInt8)
    }

    init(guest: GuestReference, session: ProxmoxSession) {
        self.guest = guest
        self.session = session
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let metered = path.isExpensive || path.isConstrained
            Task { @MainActor in
                guard let self, self.isMeteredNetwork != metered else { return }
                self.isMeteredNetwork = metered
                await self.applyQuality()
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    deinit {
        pathMonitor.cancel()
    }

    private var quality: VNCClient.Quality {
        switch qualitySetting {
        case .automatic: isMeteredNetwork ? .dataSaver : .balanced
        case .best: .best
        case .balanced: .balanced
        case .dataSaver: .dataSaver
        }
    }

    func connect() async {
        guard state != .connecting, state != .connected else { return }
        state = .connecting
        do {
            let client = try await VNCClient.open(guest, session: session, quality: quality)
            self.client = client
            state = .connected
            let (stream, continuation) = AsyncStream<Input>.makeStream()
            input = continuation
            inputWorker = Task {
                for await item in stream {
                    switch item {
                    case .text(let text, let modifiers):
                        for keysym in modifiers { await client.sendKey(keysym, down: true) }
                        await client.type(text)
                        for keysym in modifiers.reversed() { await client.sendKey(keysym, down: false) }
                    case .keys(let keysyms):
                        await client.sendCombination(keysyms)
                    case .key(let keysym, let down):
                        await client.sendKey(keysym, down: down)
                    case .scancode(let scancode, let keysym, let down):
                        await client.sendScancode(scancode, keysym: keysym, down: down)
                    case .pointer(let point, let buttons):
                        await client.sendPointer(x: Int(point.x), y: Int(point.y), buttons: buttons)
                    }
                }
            }
            listener = Task { [weak self] in
                do {
                    for try await event in client.events {
                        self?.handle(event)
                    }
                    self?.state = .closed(nil)
                } catch {
                    self?.state = .closed(error.localizedDescription)
                }
            }
            statistics = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.receivedBytes = await client.receivedBytes
                }
            }
        } catch {
            state = .closed(error.localizedDescription)
        }
    }

    func disconnect() {
        input?.finish()
        inputWorker?.cancel()
        listener?.cancel()
        statistics?.cancel()
        if let client { Task { await client.close() } }
        client = nil
        buttons = 0
        if state == .connected || state == .connecting { state = .idle }
    }

    func reconnect() async {
        disconnect()
        image = nil
        cursor = nil
        await connect()
    }

    private func applyQuality() async {
        await client?.setQuality(quality)
    }

    private func handle(_ event: VNCClient.Event) {
        switch event {
        case .updated:
            scheduleRender()
        case .resized(let width, let height):
            screenSize = CGSize(width: width, height: height)
            if !hasPointer || pointer.x >= screenSize.width || pointer.y >= screenSize.height {
                pointer = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
                hasPointer = true
            }
        case .cursor(let shape):
            cursor = Self.makeCursor(shape)
        case .bell, .clipboard:
            break
        }
    }

    /// Renders at most about 30 times per second; updates in between are merged.
    private func scheduleRender() {
        guard !renderPending, let client else { return }
        renderPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(33))
            let framebuffer = await client.framebuffer
            image = Self.makeImage(framebuffer)
            renderPending = false
        }
    }

    private static func makeImage(_ framebuffer: Framebuffer) -> CGImage? {
        guard framebuffer.width > 0, framebuffer.height > 0,
              let provider = CGDataProvider(data: Data(framebuffer.pixels) as CFData)
        else { return nil }
        return CGImage(
            width: framebuffer.width,
            height: framebuffer.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: framebuffer.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func makeCursor(_ shape: VNCCursor) -> (image: CGImage, hotspot: CGPoint)? {
        guard shape.width > 0, shape.height > 0, let provider = CGDataProvider(data: Data(shape.pixels) as CFData),
              let image = CGImage(
                width: shape.width, height: shape.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: shape.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }
        return (image, CGPoint(x: shape.hotspotX, y: shape.hotspotY))
    }

    // MARK: - Pointer

    /// Moves the pointer to a screen position, keeping held buttons.
    func move(to point: CGPoint) {
        guard screenSize.width > 0 else { return }
        pointer = CGPoint(x: min(max(0, point.x), screenSize.width - 1), y: min(max(0, point.y), screenSize.height - 1))
        hasPointer = true
        input?.yield(.pointer(pointer, buttons: buttons))
    }

    func move(by delta: CGVector) {
        move(to: CGPoint(x: pointer.x + delta.dx, y: pointer.y + delta.dy))
    }

    /// Presses and releases a button where the pointer is: 1 left, 2 middle, 4 right.
    func click(_ button: UInt8 = 1) {
        input?.yield(.pointer(pointer, buttons: buttons | button))
        input?.yield(.pointer(pointer, buttons: buttons))
    }

    func setButton(_ button: UInt8, down: Bool) {
        buttons = down ? buttons | button : buttons & ~button
        input?.yield(.pointer(pointer, buttons: buttons))
    }

    /// Turns the wheel: positive lines scroll the content down.
    func scroll(lines: Int) {
        let wheel: UInt8 = lines > 0 ? 16 : 8
        for _ in 0..<abs(lines) {
            input?.yield(.pointer(pointer, buttons: buttons | wheel))
            input?.yield(.pointer(pointer, buttons: buttons))
        }
    }

    // MARK: - Keys

    func type(_ text: String) {
        input?.yield(.text(text, modifiers: consumeModifiers()))
    }

    func press(_ keysym: UInt32) {
        input?.yield(.keys(consumeModifiers() + [keysym]))
    }

    /// A shortcut such as Ctrl+Alt+Delete, together with any modifiers of the key bar.
    func press(_ keysyms: [UInt32]) {
        let modifiers = consumeModifiers().filter { !keysyms.contains($0) }
        input?.yield(.keys(modifiers + keysyms))
    }

    /// Types the iPhone's clipboard, e.g. a password; works without an agent in the guest.
    func typeClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        input?.yield(.text(text, modifiers: []))
    }

    /// A key of a hardware keyboard, pressed or released, as a physical key when the server supports it.
    /// Modifiers of the key bar apply to it as well, e.g. Win on a keyboard without that key.
    func hardwareKey(usage: Int, keysym: UInt32, down: Bool) {
        let isModifier = (0xE0...0xE7).contains(usage)
        if down, !isModifier {
            let modifiers = consumeModifiers()
            barModifiersByKey[usage] = modifiers
            for modifier in modifiers { input?.yield(.key(modifier, down: true)) }
        }
        if let scancode = Scancode.forHIDUsage(usage) {
            input?.yield(.scancode(scancode, keysym: keysym, down: down))
        } else if keysym != 0 {
            input?.yield(.key(keysym, down: down))
        }
        if !down, let modifiers = barModifiersByKey.removeValue(forKey: usage) {
            for modifier in modifiers.reversed() { input?.yield(.key(modifier, down: false)) }
        }
    }

    /// Off → held for the next key; a second tap soon after locks it; a tap on a held or locked one turns it off.
    func tapModifier(_ modifier: VNCModifier) {
        let now = Date()
        switch modifiers[modifier] ?? .off {
        case .off:
            modifiers[modifier] = .once
        case .once:
            let isDoubleTap = modifierTapped[modifier].map { now.timeIntervalSince($0) < 0.4 } ?? false
            modifiers[modifier] = isDoubleTap ? .locked : .off
        case .locked:
            modifiers[modifier] = .off
        }
        modifierTapped[modifier] = now
    }

    private func consumeModifiers() -> [UInt32] {
        let active = VNCModifier.allCases.filter { (modifiers[$0] ?? .off) != .off }
        for modifier in active where modifiers[modifier] == .once {
            modifiers[modifier] = .off
        }
        return active.map(\.keysym)
    }
}

/// The VM screen with a key bar, embedded or full screen.
struct VNCConsoleView: View {
    @Bindable var model: VNCConsoleModel
    var isFullScreen = false
    /// Closes the full-screen console, which UIKit presents.
    var onExitFullScreen: (() -> Void)?
    @State private var isKeyboardActive = false
    @State private var showsGestures = false
    @State private var hasHardwareKeyboard = GCKeyboard.coalesced != nil
    @AppStorage("console.mouseMode") private var mouseMode = VNCMouseMode.trackpad
    @AppStorage("console.quality") private var quality = VNCQualitySetting.automatic
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                VNCScreen(model: model, mode: mouseMode)
                    .accessibilityIdentifier("vncScreen")
                overlay
            }
            VNCKeyBar(
                model: model,
                isKeyboardActive: $isKeyboardActive,
                capturesKeys: isKeyboardActive || (hasHardwareKeyboard && model.state == .connected),
                mouseMode: $mouseMode,
                quality: $quality,
                isFullScreen: isFullScreen,
                onShowGestures: { showsGestures = true }
            ) {
                if isFullScreen {
                    onExitFullScreen?()
                } else {
                    isKeyboardActive = false
                    let model = model
                    model.isInFullScreen = true
                    FullScreenConsole.present { close in
                        VNCConsoleView(model: model, isFullScreen: true) {
                            model.isInFullScreen = false
                            close()
                        }
                    }
                }
            }
        }
        .background(Color.black)
        .statusBarHidden(isFullScreen)
        .persistentSystemOverlays(isFullScreen ? .hidden : .automatic)
        .task { await model.connect() }
        .onAppear {
            model.mouseMode = mouseMode
            model.qualitySetting = quality
        }
        .onChange(of: mouseMode) { model.mouseMode = mouseMode }
        .onChange(of: quality) { model.qualitySetting = quality }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in hasHardwareKeyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in hasHardwareKeyboard = GCKeyboard.coalesced != nil }
        .sheet(isPresented: $showsGestures) {
            NavigationStack {
                VNCGesturesHelp(mode: mouseMode)
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.state {
        case .idle, .connecting:
            ProgressView("Connecting…")
                .tint(.white)
                .foregroundStyle(.white)
        case .connected:
            if model.image == nil {
                ProgressView().tint(.white)
            }
        case .closed(let message):
            ContentUnavailableView {
                Label("Console Closed", systemImage: "display")
            } description: {
                Text(message ?? String(localized: "The session ended."))
            } actions: {
                Button("Reconnect") { Task { await model.reconnect() } }
                    .buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
            .background(.black.opacity(0.85))
        }
    }
}

/// Keys the on-screen keyboard lacks, modifiers, shortcuts and the console's settings.
private struct VNCKeyBar: View {
    @Bindable var model: VNCConsoleModel
    @Binding var isKeyboardActive: Bool
    /// The invisible key view takes keys: for the on-screen keyboard, or whenever a hardware keyboard is connected.
    let capturesKeys: Bool
    @Binding var mouseMode: VNCMouseMode
    @Binding var quality: VNCQualitySetting
    let isFullScreen: Bool
    let onShowGestures: () -> Void
    let onToggleFullScreen: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggleFullScreen) {
                Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel(isFullScreen ? "Exit Full Screen" : "Full Screen")
            .accessibilityIdentifier("vnc.fullScreen")
            Button {
                isKeyboardActive.toggle()
            } label: {
                Image(systemName: isKeyboardActive ? "keyboard.chevron.compact.down" : "keyboard")
            }
            .accessibilityLabel(isKeyboardActive ? "Hide Keyboard" : "Show Keyboard")
            .accessibilityIdentifier("vnc.keyboard")
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    key("Esc", KeySym.escape)
                    key("Tab", KeySym.tab)
                    ForEach(VNCModifier.allCases) { modifier in
                        ModifierButton(modifier: modifier, state: model.modifiers[modifier] ?? .off) {
                            model.tapModifier(modifier)
                        }
                    }
                    key("←", KeySym.left, label: "Left Arrow")
                    key("↑", KeySym.up, label: "Up Arrow")
                    key("↓", KeySym.down, label: "Down Arrow")
                    key("→", KeySym.right, label: "Right Arrow")
                }
            }
            .scrollIndicators(.hidden)
            shortcutsMenu
            settingsMenu
        }
        .buttonStyle(.bordered)
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay {
            KeyInputView(isActive: capturesKeys, showsKeyboard: $isKeyboardActive, model: model)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
    }

    private func key(_ title: String, _ keysym: UInt32, label: LocalizedStringKey? = nil) -> some View {
        Button(title) { model.press(keysym) }
            .accessibilityLabel(label.map { Text($0) } ?? Text(verbatim: title))
    }

    private var shortcutsMenu: some View {
        Menu {
            Section {
                Button("Ctrl+Alt+Del") { model.press([KeySym.control, KeySym.alt, KeySym.delete]) }
                Button("Task Manager (Ctrl+Shift+Esc)") { model.press([KeySym.control, KeySym.shift, KeySym.escape]) }
                Button("Switch Window (Alt+Tab)") { model.press([KeySym.alt, KeySym.tab]) }
                Button("Close Window (Alt+F4)") { model.press([KeySym.alt, KeySym.function(4)]) }
                Button("Start Menu (Win)") { model.press([KeySym.superKey]) }
                Button("Run (Win+R)") { model.press([KeySym.superKey, UInt32(UInt8(ascii: "r"))]) }
                Button("Lock (Win+L)") { model.press([KeySym.superKey, UInt32(UInt8(ascii: "l"))]) }
                Button("Print Screen") { model.press([KeySym.printScreen]) }
            }
            Section {
                Button("Copy (Ctrl+C)") { model.press([KeySym.control, UInt32(UInt8(ascii: "c"))]) }
                Button("Paste (Ctrl+V)") { model.press([KeySym.control, UInt32(UInt8(ascii: "v"))]) }
                Button("Cut (Ctrl+X)") { model.press([KeySym.control, UInt32(UInt8(ascii: "x"))]) }
                Button("Undo (Ctrl+Z)") { model.press([KeySym.control, UInt32(UInt8(ascii: "z"))]) }
                Button("Select All (Ctrl+A)") { model.press([KeySym.control, UInt32(UInt8(ascii: "a"))]) }
            }
            Section {
                Menu("Function Keys") {
                    ForEach(1...12, id: \.self) { number in
                        Button("F\(number)") { model.press(KeySym.function(number)) }
                    }
                }
                Menu("Navigation Keys") {
                    Button("Home") { model.press(KeySym.home) }
                    Button("End") { model.press(KeySym.end) }
                    Button("Page Up") { model.press(KeySym.pageUp) }
                    Button("Page Down") { model.press(KeySym.pageDown) }
                    Button("Insert") { model.press(KeySym.insert) }
                    Button("Delete") { model.press(KeySym.delete) }
                }
                Button("Type Clipboard Text", systemImage: "doc.on.clipboard") { model.typeClipboard() }
                    .disabled(!UIPasteboard.general.hasStrings)
            }
        } label: {
            Image(systemName: "command")
        }
        .accessibilityLabel("Shortcuts")
        .accessibilityIdentifier("vnc.specialKeys")
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Mouse", selection: $mouseMode) {
                Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left").tag(VNCMouseMode.trackpad)
                Label("Touch", systemImage: "hand.tap").tag(VNCMouseMode.touch)
            }
            .accessibilityIdentifier("vnc.mouseMode")
            Picker("Quality", selection: $quality) {
                ForEach(VNCQualitySetting.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            Button("Gestures", systemImage: "questionmark.circle", action: onShowGestures)
            Section {
                Text("Data Used: \(Format.bytes(Int64(model.receivedBytes)))")
                Button("Reconnect", systemImage: "arrow.clockwise") { Task { await model.reconnect() } }
            }
        } label: {
            Image(systemName: mouseMode == .trackpad ? "rectangle.and.hand.point.up.left" : "hand.tap")
        }
        .accessibilityLabel("Console Settings")
        .accessibilityIdentifier("vnc.settings")
    }
}

/// Ctrl, Alt, Shift or Win: tinted while held for the next key, filled while locked.
private struct ModifierButton: View {
    let modifier: VNCModifier
    let state: ModifierState
    let action: () -> Void

    var body: some View {
        Group {
            if state == .locked {
                Button(action: action) { title }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { title }
                    .buttonStyle(.bordered)
                    .tint(state == .once ? .accentColor : nil)
            }
        }
        .accessibilityValue(state == .locked ? Text("Locked") : state == .once ? Text("On") : Text("Off"))
        .accessibilityHint("Applies to the next key. Tap twice to lock.")
    }

    private var title: some View {
        Text(modifier.title)
            .underline(state == .once)
    }
}

/// What the fingers do in each mouse mode.
private struct VNCGesturesHelp: View {
    let mode: VNCMouseMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section(mode == .trackpad ? "Trackpad" : "Touch") {
                if mode == .trackpad {
                    row("hand.point.up.left", "Move the pointer", "Slide one finger anywhere. Fast moves go further.")
                    row("hand.tap", "Click", "Tap. Tap twice quickly to double-click.")
                    row("hand.tap", "Right-click", "Tap with two fingers.")
                    row("hand.draw", "Drag", "Touch and hold until it clicks, then move.")
                } else {
                    row("hand.tap", "Click", "Tap where you want to click.")
                    row("hand.tap", "Right-click", "Touch and hold, or tap with two fingers.")
                    row("hand.draw", "Drag", "Slide one finger.")
                }
                row("arrow.up.and.down", "Scroll", mode == .trackpad ? "Slide two fingers." : "Slide two fingers, when not zoomed in.")
                row("arrow.up.left.and.arrow.down.right", "Zoom", mode == .trackpad ? "Pinch. The view follows the pointer." : "Pinch, then slide two fingers to look around.")
            }
            Section("Keyboard") {
                row("keyboard", "Modifiers", "Ctrl, Alt, Shift and Win apply to the next key. Tap one twice to lock it.")
                row("command", "Shortcuts", "Ctrl+Alt+Del, Alt+Tab and more are in the ⌘ menu, with Type Clipboard Text for passwords.")
                row("keyboard.badge.ellipsis", "Hardware keyboard", "Keys reach the guest as physical keys, so shortcuts and the guest's keyboard layout work. ⌘ is the Windows key.")
            }
            Section("Mouse and Trackpad") {
                row("computermouse", "Pointer", "On iPad, a mouse or trackpad moves the pointer directly, with right-click and scrolling.")
            }
        }
        .navigationTitle("Gestures")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func row(_ systemImage: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

/// An invisible view that takes keyboard input, from the on-screen keyboard or a hardware one.
private struct KeyInputView: UIViewRepresentable {
    let isActive: Bool
    @Binding var showsKeyboard: Bool
    let model: VNCConsoleModel

    func makeUIView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.model = model
        view.onResign = { showsKeyboard = false }
        return view
    }

    func updateUIView(_ view: KeyCaptureView, context: Context) {
        view.model = model
        if isActive, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !isActive, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

final class KeyCaptureView: UIView, UIKeyInput {
    var model: VNCConsoleModel?
    var onResign: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    /// Text from the on-screen keyboard. Hardware keys arrive as presses instead.
    func insertText(_ text: String) {
        model?.type(text)
    }

    func deleteBackward() {
        model?.press(KeySym.backspace)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        onResign?()
        return result
    }

    /// Every key of a hardware keyboard goes down and up separately, so the guest sees holds, repeats and shortcuts.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !send($0, down: true) }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !send($0, down: false) }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !send($0, down: false) }
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func send(_ press: UIPress, down: Bool) -> Bool {
        guard let key = press.key, let model else { return false }
        let usage = key.keyCode.rawValue
        let keysym = Self.keysym(for: key.keyCode) ?? key.charactersIgnoringModifiers.unicodeScalars.first.map(KeySym.character) ?? 0
        guard Scancode.forHIDUsage(usage) != nil || keysym != 0 else { return false }
        model.hardwareKey(usage: usage, keysym: keysym, down: down)
        return true
    }

    /// Keysyms for keys that do not type text, used when the server takes no scancodes.
    private static func keysym(for code: UIKeyboardHIDUsage) -> UInt32? {
        switch code {
        case .keyboardUpArrow: KeySym.up
        case .keyboardDownArrow: KeySym.down
        case .keyboardLeftArrow: KeySym.left
        case .keyboardRightArrow: KeySym.right
        case .keyboardEscape: KeySym.escape
        case .keyboardReturnOrEnter, .keypadEnter: KeySym.returnKey
        case .keyboardDeleteOrBackspace: KeySym.backspace
        case .keyboardTab: KeySym.tab
        case .keyboardHome: KeySym.home
        case .keyboardEnd: KeySym.end
        case .keyboardPageUp: KeySym.pageUp
        case .keyboardPageDown: KeySym.pageDown
        case .keyboardInsert: KeySym.insert
        case .keyboardDeleteForward: KeySym.delete
        case .keyboardPrintScreen: KeySym.printScreen
        case .keyboardLeftShift, .keyboardRightShift: KeySym.shift
        case .keyboardLeftControl, .keyboardRightControl: KeySym.control
        case .keyboardLeftAlt, .keyboardRightAlt: KeySym.alt
        case .keyboardLeftGUI, .keyboardRightGUI: KeySym.superKey
        case .keyboardF1: KeySym.function(1)
        case .keyboardF2: KeySym.function(2)
        case .keyboardF3: KeySym.function(3)
        case .keyboardF4: KeySym.function(4)
        case .keyboardF5: KeySym.function(5)
        case .keyboardF6: KeySym.function(6)
        case .keyboardF7: KeySym.function(7)
        case .keyboardF8: KeySym.function(8)
        case .keyboardF9: KeySym.function(9)
        case .keyboardF10: KeySym.function(10)
        case .keyboardF11: KeySym.function(11)
        case .keyboardF12: KeySym.function(12)
        default: nil
        }
    }
}

/// The remote screen in a scroll view, with the pointer drawn on top and gestures for the current mouse mode.
private struct VNCScreen: UIViewRepresentable {
    let model: VNCConsoleModel
    let mode: VNCMouseMode

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        context.coordinator.install(in: scrollView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.mode = mode
        if let image = model.image {
            coordinator.imageView.image = UIImage(cgImage: image)
        }
        coordinator.layout(in: scrollView)
        coordinator.updateCursor()
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
        var model: VNCConsoleModel
        var mode: VNCMouseMode = .trackpad {
            didSet { if mode != oldValue { modeChanged() } }
        }
        let imageView = UIImageView()
        private let cursorView = UIImageView()
        private weak var scrollView: UIScrollView?
        private var lastBounds = CGRect.zero
        private var lastImageSize = CGSize.zero
        private var lastCursor: CGImage?
        private var scrollRemainder: CGFloat = 0
        private var lastDragLocation = CGPoint.zero
        private var draggedButton: UInt8 = 1
        /// Whether a real mouse or trackpad drove the pointer last; then the guest's own pointer is enough.
        private var usesPointerDevice = false

        private let tap = UITapGestureRecognizer()
        private let twoFingerTap = UITapGestureRecognizer()
        private let longPress = UILongPressGestureRecognizer()
        private let drag = UIPanGestureRecognizer()
        private let twoFingerScroll = UIPanGestureRecognizer()
        private let hover = UIHoverGestureRecognizer()
        private let pointerClick = UITapGestureRecognizer()
        private let pointerRightClick = UITapGestureRecognizer()
        private let pointerDrag = UIPanGestureRecognizer()
        private let pointerScroll = UIPanGestureRecognizer()

        /// Pixels the pointer moves per point the finger moves, before acceleration.
        private static let trackpadSpeed: CGFloat = 1.2
        /// Points of two-finger or wheel movement per wheel step.
        private static let pointsPerLine: CGFloat = 22

        init(model: VNCConsoleModel) {
            self.model = model
        }

        func install(in scrollView: UIScrollView) {
            self.scrollView = scrollView
            imageView.contentMode = .scaleAspectFit
            imageView.isUserInteractionEnabled = true
            imageView.layer.magnificationFilter = .trilinear
            scrollView.addSubview(imageView)
            cursorView.isUserInteractionEnabled = false
            cursorView.layer.magnificationFilter = .nearest
            imageView.addSubview(cursorView)

            let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            let pointer = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]

            tap.addTarget(self, action: #selector(tapped(_:)))
            tap.allowedTouchTypes = fingers
            twoFingerTap.addTarget(self, action: #selector(twoFingerTapped(_:)))
            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.allowedTouchTypes = fingers
            longPress.addTarget(self, action: #selector(longPressed(_:)))
            longPress.minimumPressDuration = 0.35
            longPress.allowedTouchTypes = fingers
            drag.addTarget(self, action: #selector(dragged(_:)))
            drag.maximumNumberOfTouches = 1
            drag.allowedTouchTypes = fingers
            drag.delegate = self
            twoFingerScroll.addTarget(self, action: #selector(twoFingerScrolled(_:)))
            twoFingerScroll.minimumNumberOfTouches = 2
            twoFingerScroll.maximumNumberOfTouches = 2
            twoFingerScroll.allowedTouchTypes = fingers
            twoFingerScroll.delegate = self
            tap.require(toFail: longPress)

            hover.addTarget(self, action: #selector(hovered(_:)))
            pointerClick.addTarget(self, action: #selector(pointerClicked(_:)))
            pointerClick.allowedTouchTypes = pointer
            pointerClick.buttonMaskRequired = .primary
            pointerRightClick.addTarget(self, action: #selector(pointerRightClicked(_:)))
            pointerRightClick.allowedTouchTypes = pointer
            pointerRightClick.buttonMaskRequired = .secondary
            pointerDrag.addTarget(self, action: #selector(pointerDragged(_:)))
            pointerDrag.allowedTouchTypes = pointer
            pointerScroll.addTarget(self, action: #selector(pointerScrolled(_:)))
            pointerScroll.allowedScrollTypesMask = .all
            pointerScroll.allowedTouchTypes = []

            for recognizer in [tap, twoFingerTap, longPress, drag, twoFingerScroll, hover, pointerClick, pointerRightClick, pointerDrag, pointerScroll] {
                imageView.addGestureRecognizer(recognizer)
            }
            imageView.addInteraction(UIPointerInteraction(delegate: self))
            modeChanged()
        }

        private func modeChanged() {
            // The trackpad moves the view itself to follow the pointer; touch mode pans with two fingers.
            scrollView?.panGestureRecognizer.isEnabled = mode == .touch
            updateCursor()
        }

        // MARK: Layout

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            center(in: scrollView)
        }

        /// Fits the screen to the view at zoom 1, keeping its aspect ratio.
        func layout(in scrollView: UIScrollView) {
            let imageSize = model.screenSize
            guard imageSize.width > 0, scrollView.bounds.width > 0,
                  scrollView.bounds != lastBounds || imageSize != lastImageSize
            else { return }
            lastBounds = scrollView.bounds
            lastImageSize = imageSize
            scrollView.zoomScale = 1
            let scale = min(scrollView.bounds.width / imageSize.width, scrollView.bounds.height / imageSize.height)
            imageView.frame = CGRect(origin: .zero, size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale))
            scrollView.contentSize = imageView.frame.size
            center(in: scrollView)
            updateCursor()
        }

        private func center(in scrollView: UIScrollView) {
            let horizontal = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
            let vertical = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        }

        /// Screen pixels per point of the image view, before zooming.
        private var pixelsPerPoint: CGFloat {
            imageView.bounds.width > 0 ? model.screenSize.width / imageView.bounds.width : 1
        }

        /// Converts a point in the image view to screen pixels.
        private func remote(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * pixelsPerPoint, y: point.y * pixelsPerPoint)
        }

        /// Draws the pointer where the guest has it: its own shape when the server sends one, otherwise an arrow in
        /// trackpad mode, where it is the only feedback. A real mouse needs none: the guest draws its pointer.
        func updateCursor() {
            let showsCursor = model.state == .connected && model.hasPointer && (model.cursor != nil || mode == .trackpad) && !usesPointerDevice
            cursorView.isHidden = !showsCursor
            guard showsCursor, pixelsPerPoint > 0 else { return }
            let pointsPerPixel = 1 / pixelsPerPoint
            if let cursor = model.cursor {
                if cursor.image !== lastCursor {
                    cursorView.image = UIImage(cgImage: cursor.image)
                    lastCursor = cursor.image
                }
                let size = CGSize(width: CGFloat(cursor.image.width) * pointsPerPixel, height: CGFloat(cursor.image.height) * pointsPerPixel)
                cursorView.frame = CGRect(
                    x: (model.pointer.x - cursor.hotspot.x) * pointsPerPixel, y: (model.pointer.y - cursor.hotspot.y) * pointsPerPixel,
                    width: size.width, height: size.height
                )
            } else {
                if lastCursor != nil || cursorView.image == nil {
                    cursorView.image = UIImage(systemName: "cursorarrow", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))?
                        .withTintColor(.white, renderingMode: .alwaysOriginal)
                    lastCursor = nil
                }
                // An arrow of about 18 points at zoom 1, whose tip is the pointer.
                let size = CGSize(width: 14, height: 20)
                cursorView.frame = CGRect(origin: CGPoint(x: model.pointer.x * pointsPerPixel - 3, y: model.pointer.y * pointsPerPixel - 2), size: size)
                cursorView.layer.shadowColor = UIColor.black.cgColor
                cursorView.layer.shadowOpacity = 0.8
                cursorView.layer.shadowRadius = 1
                cursorView.layer.shadowOffset = .zero
            }
        }

        /// Keeps the pointer in view while zoomed in, with some room around it.
        private func followPointer() {
            guard let scrollView, scrollView.zoomScale > 1.01 else { return }
            let pointsPerPixel = 1 / pixelsPerPoint
            let point = imageView.convert(CGPoint(x: model.pointer.x * pointsPerPixel, y: model.pointer.y * pointsPerPixel), to: scrollView)
            let margin: CGFloat = 60
            scrollView.scrollRectToVisible(CGRect(x: point.x - margin, y: point.y - margin, width: margin * 2, height: margin * 2), animated: false)
        }

        private func pointerMoved() {
            updateCursor()
            if mode == .trackpad { followPointer() }
        }

        // MARK: Fingers

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            usesPointerDevice = false
            if mode == .touch {
                model.move(to: remote(recognizer.location(in: imageView)))
            }
            model.click()
            pointerMoved()
        }

        @objc func twoFingerTapped(_ recognizer: UITapGestureRecognizer) {
            usesPointerDevice = false
            if mode == .touch {
                model.move(to: remote(recognizer.location(in: imageView)))
            }
            model.click(4)
            pointerMoved()
        }

        @objc func longPressed(_ recognizer: UILongPressGestureRecognizer) {
            usesPointerDevice = false
            switch (mode, recognizer.state) {
            case (.touch, .began):
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                model.move(to: remote(recognizer.location(in: imageView)))
                model.click(4)
            case (.trackpad, .began):
                // Hold, then move: drags with the left button down.
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                lastDragLocation = recognizer.location(in: recognizer.view?.superview)
                model.setButton(1, down: true)
            case (.trackpad, .changed):
                let location = recognizer.location(in: recognizer.view?.superview)
                moveRelatively(by: CGVector(dx: location.x - lastDragLocation.x, dy: location.y - lastDragLocation.y), speed: 0)
                lastDragLocation = location
            case (.trackpad, .ended), (.trackpad, .cancelled), (.trackpad, .failed):
                model.setButton(1, down: false)
            default:
                break
            }
            pointerMoved()
        }

        @objc func dragged(_ recognizer: UIPanGestureRecognizer) {
            usesPointerDevice = false
            switch mode {
            case .trackpad:
                let translation = recognizer.translation(in: recognizer.view?.superview)
                let velocity = recognizer.velocity(in: recognizer.view?.superview)
                moveRelatively(by: CGVector(dx: translation.x, dy: translation.y), speed: hypot(velocity.x, velocity.y))
                recognizer.setTranslation(.zero, in: recognizer.view?.superview)
            case .touch:
                let point = remote(recognizer.location(in: imageView))
                switch recognizer.state {
                case .began:
                    model.move(to: point)
                    model.setButton(1, down: true)
                case .changed:
                    model.move(to: point)
                default:
                    model.move(to: point)
                    model.setButton(1, down: false)
                }
            }
            pointerMoved()
        }

        /// Moves the pointer like a laptop trackpad: finger points to screen pixels as seen, faster moves go further.
        private func moveRelatively(by translation: CGVector, speed: CGFloat) {
            let zoom = scrollView?.zoomScale ?? 1
            let acceleration = 1 + min(speed / 900, 2)
            let factor = Self.trackpadSpeed * pixelsPerPoint / zoom * acceleration
            model.move(by: CGVector(dx: translation.dx * factor, dy: translation.dy * factor))
        }

        @objc func twoFingerScrolled(_ recognizer: UIPanGestureRecognizer) {
            usesPointerDevice = false
            if mode == .touch, recognizer.state == .began {
                model.move(to: remote(recognizer.location(in: imageView)))
            }
            scroll(by: recognizer.translation(in: recognizer.view?.superview).y, ended: recognizer.state != .changed && recognizer.state != .began)
            recognizer.setTranslation(.zero, in: recognizer.view?.superview)
        }

        /// Natural scrolling: moving fingers up scrolls the content down.
        private func scroll(by points: CGFloat, ended: Bool) {
            scrollRemainder -= points
            let lines = Int(scrollRemainder / Self.pointsPerLine)
            if lines != 0 {
                model.scroll(lines: lines)
                scrollRemainder -= CGFloat(lines) * Self.pointsPerLine
            }
            if ended { scrollRemainder = 0 }
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            if recognizer === twoFingerScroll, mode == .touch {
                // Zoomed in, two fingers look around instead.
                return (scrollView?.zoomScale ?? 1) <= 1.01
            }
            return true
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Scrolling and pinching often start together; the pinch keeps zooming either way.
            recognizer === twoFingerScroll && other === scrollView?.pinchGestureRecognizer
        }

        // MARK: Mouse and trackpad

        @objc func hovered(_ recognizer: UIHoverGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            usesPointerDevice = true
            model.move(to: remote(recognizer.location(in: imageView)))
            updateCursor()
        }

        @objc func pointerClicked(_ recognizer: UITapGestureRecognizer) {
            usesPointerDevice = true
            model.move(to: remote(recognizer.location(in: imageView)))
            model.click()
        }

        @objc func pointerRightClicked(_ recognizer: UITapGestureRecognizer) {
            usesPointerDevice = true
            model.move(to: remote(recognizer.location(in: imageView)))
            model.click(4)
        }

        /// Drags with the button that started it: left, or right for context-menu drags.
        @objc func pointerDragged(_ recognizer: UIPanGestureRecognizer) {
            usesPointerDevice = true
            model.move(to: remote(recognizer.location(in: imageView)))
            switch recognizer.state {
            case .began:
                draggedButton = recognizer.buttonMask.contains(.secondary) ? 4 : 1
                model.setButton(draggedButton, down: true)
            case .ended, .cancelled, .failed:
                model.setButton(draggedButton, down: false)
            default:
                break
            }
        }

        @objc func pointerScrolled(_ recognizer: UIPanGestureRecognizer) {
            scroll(by: recognizer.translation(in: recognizer.view).y, ended: recognizer.state == .ended || recognizer.state == .cancelled)
            recognizer.setTranslation(.zero, in: recognizer.view)
        }

        /// Over the screen, the guest's pointer replaces the system one.
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
            .hidden()
        }
    }
}

/// Presents the console over everything, in a controller that may turn to landscape while the rest of the app
/// stays in portrait. SwiftUI's full-screen cover keeps the orientations of the screen below it.
@MainActor
enum FullScreenConsole {
    static func present<Content: View>(@ViewBuilder _ content: (_ close: @escaping () -> Void) -> Content) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = LandscapeHostingController(rootView: AnyView(EmptyView()))
        controller.rootView = AnyView(content { [weak controller] in
            OrientationLock.allowsLandscape = false
            controller?.dismiss(animated: true)
        }.tint(.accentColor))
        controller.modalPresentationStyle = .fullScreen
        OrientationLock.allowsLandscape = true
        top.present(controller, animated: true)
    }
}

private final class LandscapeHostingController: UIHostingController<AnyView> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

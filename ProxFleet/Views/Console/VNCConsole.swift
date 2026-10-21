import CoreGraphics
import ProxmoxConsole
import ProxmoxCore
import PVEKit
import SwiftUI
import UIKit

/// Drives a `VNCClient` and turns its framebuffer into images for the view.
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
    /// Modifiers latched from the key bar, applied to the next key and then released.
    var latchedControl = false
    var latchedAlt = false

    @ObservationIgnored private let guest: GuestReference
    @ObservationIgnored private let session: ProxmoxSession
    @ObservationIgnored private var client: VNCClient?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var renderPending = false
    @ObservationIgnored private var buttons: UInt8 = 0
    /// Input goes through one queue so that keys and clicks reach the VM in the order they happened.
    @ObservationIgnored private var input: AsyncStream<Input>.Continuation?
    @ObservationIgnored private var inputWorker: Task<Void, Never>?

    private enum Input {
        case text(String, modifiers: [UInt32])
        case keys([UInt32])
        case pointer(CGPoint, buttons: UInt8)
    }

    init(guest: GuestReference, session: ProxmoxSession) {
        self.guest = guest
        self.session = session
    }

    func connect() async {
        guard state != .connecting, state != .connected else { return }
        state = .connecting
        do {
            let client = try await VNCClient.open(guest, session: session)
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
        } catch {
            state = .closed(error.localizedDescription)
        }
    }

    func disconnect() {
        input?.finish()
        inputWorker?.cancel()
        listener?.cancel()
        if let client { Task { await client.close() } }
        client = nil
        if state == .connected || state == .connecting { state = .idle }
    }

    func reconnect() async {
        disconnect()
        image = nil
        await connect()
    }

    private func handle(_ event: VNCClient.Event) {
        switch event {
        case .updated:
            scheduleRender()
        case .resized(let width, let height):
            screenSize = CGSize(width: width, height: height)
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

    // MARK: - Input

    func click(at point: CGPoint, button: UInt8 = 1) {
        input?.yield(.pointer(point, buttons: 0))
        input?.yield(.pointer(point, buttons: button))
        input?.yield(.pointer(point, buttons: 0))
    }

    func drag(to point: CGPoint, ended: Bool) {
        buttons = ended ? 0 : 1
        input?.yield(.pointer(point, buttons: buttons))
    }

    func scroll(at point: CGPoint, up: Bool) {
        input?.yield(.pointer(point, buttons: up ? 8 : 16))
        input?.yield(.pointer(point, buttons: 0))
    }

    func type(_ text: String) {
        input?.yield(.text(text, modifiers: consumeModifiers()))
    }

    func press(_ keysym: UInt32) {
        input?.yield(.keys(consumeModifiers() + [keysym]))
    }

    func sendCtrlAltDelete() {
        input?.yield(.keys([KeySym.control, KeySym.alt, KeySym.delete]))
    }

    private func consumeModifiers() -> [UInt32] {
        var keys: [UInt32] = []
        if latchedControl { keys.append(KeySym.control) }
        if latchedAlt { keys.append(KeySym.alt) }
        latchedControl = false
        latchedAlt = false
        return keys
    }
}

/// The VM screen with touch input: tap to click, long press for a right click, drag to move with the button held.
struct VNCConsoleView: View {
    @Bindable var model: VNCConsoleModel
    var isFullScreen = false
    @State private var isKeyboardActive = false
    @State private var showsFullScreen = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                VNCScreen(model: model)
                    .accessibilityIdentifier("vncScreen")
                overlay
            }
            VNCKeyBar(model: model, isKeyboardActive: $isKeyboardActive, isFullScreen: isFullScreen) {
                if isFullScreen {
                    dismiss()
                } else {
                    isKeyboardActive = false
                    showsFullScreen = true
                }
            }
        }
        .background(Color.black)
        .statusBarHidden(isFullScreen)
        .task { await model.connect() }
        .fullScreenCover(isPresented: $showsFullScreen) {
            VNCConsoleView(model: model, isFullScreen: true)
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

/// Keys the on-screen keyboard lacks, and the button that shows the keyboard.
private struct VNCKeyBar: View {
    @Bindable var model: VNCConsoleModel
    @Binding var isKeyboardActive: Bool
    let isFullScreen: Bool
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
            key("Esc", KeySym.escape)
            key("Tab", KeySym.tab)
            Toggle("Ctrl", isOn: $model.latchedControl)
                .toggleStyle(.button)
            Toggle("Alt", isOn: $model.latchedAlt)
                .toggleStyle(.button)
            Spacer(minLength: 0)
            Menu {
                Button("Ctrl+Alt+Del") { model.sendCtrlAltDelete() }
                Divider()
                ForEach(1...12, id: \.self) { number in
                    Button("F\(number)") { model.press(KeySym.function(number)) }
                }
                Divider()
                Button("Arrow Up") { model.press(KeySym.up) }
                Button("Arrow Down") { model.press(KeySym.down) }
                Button("Arrow Left") { model.press(KeySym.left) }
                Button("Arrow Right") { model.press(KeySym.right) }
                Button("Home") { model.press(KeySym.home) }
                Button("End") { model.press(KeySym.end) }
                Button("Page Up") { model.press(KeySym.pageUp) }
                Button("Page Down") { model.press(KeySym.pageDown) }
                Button("Delete") { model.press(KeySym.delete) }
            } label: {
                Image(systemName: "command")
            }
            .accessibilityLabel("Special Keys")
            .accessibilityIdentifier("vnc.specialKeys")
        }
        .buttonStyle(.bordered)
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay {
            KeyInputView(isActive: $isKeyboardActive, model: model)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
    }

    private func key(_ title: String, _ keysym: UInt32) -> some View {
        Button(title) { model.press(keysym) }
    }
}

/// An invisible view that takes keyboard input, from the on-screen keyboard or a hardware one.
private struct KeyInputView: UIViewRepresentable {
    @Binding var isActive: Bool
    let model: VNCConsoleModel

    func makeUIView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.model = model
        view.onResign = { isActive = false }
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

    /// Keys of a hardware keyboard that do not produce text.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, let keysym = Self.keysym(for: key.keyCode) else { continue }
            model?.press(keysym)
            handled = true
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    private static func keysym(for code: UIKeyboardHIDUsage) -> UInt32? {
        switch code {
        case .keyboardUpArrow: KeySym.up
        case .keyboardDownArrow: KeySym.down
        case .keyboardLeftArrow: KeySym.left
        case .keyboardRightArrow: KeySym.right
        case .keyboardEscape: KeySym.escape
        case .keyboardHome: KeySym.home
        case .keyboardEnd: KeySym.end
        case .keyboardPageUp: KeySym.pageUp
        case .keyboardPageDown: KeySym.pageDown
        case .keyboardDeleteForward: KeySym.delete
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

/// The remote screen in a scroll view: pinch to zoom, two fingers to pan, one finger for the mouse.
private struct VNCScreen: UIViewRepresentable {
    let model: VNCConsoleModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2

        let imageView = context.coordinator.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.layer.magnificationFilter = .trilinear
        scrollView.addSubview(imageView)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        let drag = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drag(_:)))
        drag.maximumNumberOfTouches = 1
        tap.require(toFail: longPress)
        imageView.addGestureRecognizer(tap)
        imageView.addGestureRecognizer(longPress)
        imageView.addGestureRecognizer(drag)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.model = model
        let imageView = context.coordinator.imageView
        if let image = model.image {
            imageView.image = UIImage(cgImage: image)
        }
        context.coordinator.layout(in: scrollView)
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var model: VNCConsoleModel
        let imageView = UIImageView()
        private var lastBounds = CGRect.zero
        private var lastImageSize = CGSize.zero

        init(model: VNCConsoleModel) {
            self.model = model
        }

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
        }

        private func center(in scrollView: UIScrollView) {
            let horizontal = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
            let vertical = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        }

        /// Converts a point in the image view to framebuffer pixels.
        private func remote(_ point: CGPoint) -> CGPoint {
            let size = model.screenSize
            let bounds = imageView.bounds.size
            guard bounds.width > 0, bounds.height > 0 else { return .zero }
            return CGPoint(x: point.x / bounds.width * size.width, y: point.y / bounds.height * size.height)
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            model.click(at: remote(recognizer.location(in: imageView)))
        }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            model.click(at: remote(recognizer.location(in: imageView)), button: 4)
        }

        @objc func drag(_ recognizer: UIPanGestureRecognizer) {
            let point = remote(recognizer.location(in: imageView))
            switch recognizer.state {
            case .began, .changed: model.drag(to: point, ended: false)
            case .ended, .cancelled, .failed: model.drag(to: point, ended: true)
            default: break
            }
        }
    }
}

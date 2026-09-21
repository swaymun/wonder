import SwiftUI
import UIKit
import WonderPairing

enum ComputerInputMode: String, CaseIterable, Identifiable {
    case trackpad
    case directTouch
    var id: String { rawValue }
    var title: String { self == .trackpad ? "Trackpad" : "Direct touch" }
}

@MainActor
final class ComputerPointerState: ObservableObject {
    @Published private(set) var position = CGPoint(x: 0.5, y: 0.5)

    func move(to position: CGPoint) {
        guard self.position != position else { return }
        self.position = position
    }
}

/// The renderer and every input mode use the same aspect-fit, zoom and pan transform.
struct ComputerViewportTransform {
    let size: CGSize
    let content: CGRect
    let center: CGPoint

    init(size: CGSize, aspect: CGFloat, zoom: CGFloat, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.size = size
        let safeAspect = aspect.isFinite && aspect > 0 ? aspect : 16 / 9
        let width = max(1, min(size.width, size.height * safeAspect))
        let height = width / safeAspect
        let scale = zoom.isFinite ? min(max(zoom, 1), 3) : 1
        let halfX = min(max(size.width, 0) / (width * scale) / 2, 0.5)
        let halfY = min(max(size.height, 0) / (height * scale) / 2, 0.5)
        let x = center.x.isFinite ? min(max(center.x, halfX), 1 - halfX) : 0.5
        let y = center.y.isFinite ? min(max(center.y, halfY), 1 - halfY) : 0.5
        self.center = CGPoint(x: x, y: y)
        content = CGRect(x: size.width / 2 - x * width * scale,
                         y: size.height / 2 - y * height * scale,
                         width: width * scale, height: height * scale)
    }

    var renderOffset: CGSize {
        CGSize(width: content.midX - size.width / 2, height: content.midY - size.height / 2)
    }

    func location(for point: CGPoint) -> CGPoint {
        CGPoint(x: content.minX + point.x * content.width,
                y: content.minY + point.y * content.height)
    }

    // The host centers the source in its encoded frame. Scale that frame so
    // the source, rather than its padding, fills the shared content rectangle.
    func videoFrame(encodedAspect: CGFloat) -> CGRect {
        let aspect = encodedAspect.isFinite && encodedAspect > 0
            ? encodedAspect : content.width / content.height
        let width = max(content.width, content.height * aspect)
        let height = width / aspect
        return CGRect(x: content.midX - width / 2, y: content.midY - height / 2,
                      width: width, height: height)
    }

    func point(_ location: CGPoint, clamped: Bool = false) -> CGPoint? {
        guard size.width > 0, size.height > 0, location.x.isFinite, location.y.isFinite,
              clamped || content.contains(location) else { return nil }
        return CGPoint(x: min(max((location.x - content.minX) / content.width, 0), 1),
                       y: min(max((location.y - content.minY) / content.height, 0), 1))
    }

    func moving(_ point: CGPoint, by delta: CGSize) -> CGPoint {
        guard delta.width.isFinite, delta.height.isFinite else { return point }
        return CGPoint(x: min(max(point.x + delta.width / content.width, 0), 1),
                       y: min(max(point.y + delta.height / content.height, 0), 1))
    }

    func panning(by delta: CGSize) -> CGPoint {
        moving(center, by: CGSize(width: -delta.width, height: -delta.height))
    }
}

/// Only consecutive motion can be replaced. Clicks, keys, clipboard and release
/// form ordering barriers. Overflow fails control closed rather than dropping text.
struct ComputerInputBuffer {
    private(set) var batches: [[ComputerInputAction]] = []
    private let maximumActions = 64
    private let maximumBytes = 65_536

    mutating func append(_ actions: [ComputerInputAction]) -> Bool {
        guard !actions.isEmpty, actions.count <= 32 else { return false }
        if actions.count == 1, let last = batches.last, last.count == 1 {
            switch (last[0], actions[0]) {
            case let (.pointer(_, _, "move", previousButton), .pointer(_, _, "move", button)) where previousButton == button:
                batches[batches.count - 1] = actions
                return true
            case let (.scroll(x, y), .scroll(nextX, nextY)) where abs(x + nextX) <= 4_096 && abs(y + nextY) <= 4_096:
                batches[batches.count - 1] = [.scroll(deltaX: x + nextX, deltaY: y + nextY)]
                return true
            case let (.text(previous), .text(next)) where previous.unicodeScalars.count + next.unicodeScalars.count <= 4_096:
                guard batches.joined().reduce(0, { $0 + Self.cost($1) }) + next.utf8.count <= maximumBytes else { return false }
                batches[batches.count - 1] = [.text(previous + next)]
                return true
            default: break
            }
        }
        guard batches.reduce(0, { $0 + $1.count }) + actions.count <= maximumActions,
              batches.joined().reduce(0, { $0 + Self.cost($1) }) + actions.reduce(0, { $0 + Self.cost($1) }) <= maximumBytes else { return false }
        batches.append(actions)
        return true
    }

    mutating func popFirst() -> [ComputerInputAction]? {
        batches.isEmpty ? nil : batches.removeFirst()
    }

    mutating func removeAll() { batches.removeAll(keepingCapacity: false) }

    private static func cost(_ action: ComputerInputAction) -> Int {
        switch action {
        case .text(let text), .clipboard(_, .some(let text)): return 96 + text.utf8.count
        default: return 96
        }
    }
}

/// UITextView owns marked text. Nothing is sent until composition commits. A
/// bounded shadow of recently committed text makes replacement and deletion exact.
struct ComputerKeyboardComposition {
    private(set) var committed = ""
    mutating func reset() { committed = "" }

    mutating func update(_ text: String, hasMarkedText: Bool) -> [ComputerInputAction] {
        guard !hasMarkedText else { return [] }
        let before = Array(committed), after = Array(text)
        let prefix = zip(before, after).prefix(while: { $0.0 == $0.1 }).count
        var actions = Array(repeating: ComputerInputAction.key(key: "delete", phase: "press", modifiers: 0), count: before.count - prefix)
        var inserted = ""
        var insertedScalars = 0
        func flush() {
            if !inserted.isEmpty { actions.append(.text(inserted)); inserted = ""; insertedScalars = 0 }
        }
        for character in after.dropFirst(prefix) {
            if character == "\n" || character == "\t" {
                flush()
                actions.append(.key(key: character == "\n" ? "return" : "tab", phase: "press", modifiers: 0))
            } else {
                let scalarCount = character.unicodeScalars.count
                if insertedScalars + scalarCount > 4_096 { flush() }
                inserted.append(character)
                insertedScalars += scalarCount
            }
        }
        flush()
        committed = String(text.suffix(128))
        return actions
    }
}

struct ComputerNativeKeyboard: UIViewRepresentable {
    let presented: Bool
    let resetID: UInt64
    let onActions: ([ComputerInputAction]) -> Void
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> InputView { InputView() }
    func updateUIView(_ view: InputView, context: Context) {
        view.onActions = onActions
        view.onDismiss = onDismiss
        if view.resetID != resetID {
            view.resetID = resetID
            view.clearContext()
        }
        view.wantsKeyboard = presented
        view.updateFocus()
    }
    static func dismantleUIView(_ view: InputView, coordinator: ()) {
        view.onActions = nil
        view.onDismiss = nil
        view.wantsKeyboard = false
        view.resignFirstResponder()
        view.clearContext()
    }

    final class InputView: UITextView, UITextViewDelegate {
        var wantsKeyboard = false
        var resetID: UInt64 = 0
        var onActions: (([ComputerInputAction]) -> Void)?
        var onDismiss: (() -> Void)?
        private var composition = ComputerKeyboardComposition()
        private var editingInternally = false
        private var updatingMarkedText = false
        private var remotePresses = Set<UIPress>()

        init() {
            super.init(frame: .zero, textContainer: nil)
            delegate = self
            backgroundColor = .clear
            textColor = .clear
            tintColor = .clear
            isScrollEnabled = false
            autocapitalizationType = .none
            autocorrectionType = .no
            spellCheckingType = .no
            smartQuotesType = .no
            smartDashesType = .no
            smartInsertDeleteType = .no
            inputAssistantItem.leadingBarButtonGroups = []
            inputAssistantItem.trailingBarButtonGroups = []
            accessibilityLabel = "Keyboard for your Mac"
            accessibilityIdentifier = "computer-session-native-keyboard"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateFocus()
        }
        func updateFocus() {
            if wantsKeyboard {
                guard window != nil, !isFirstResponder else { return }
                // SwiftUI may call updateUIView during a view transaction.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.wantsKeyboard, self.window != nil, !self.isFirstResponder else { return }
                    self.becomeFirstResponder()
                }
            } else if isFirstResponder {
                resignFirstResponder()
                clearContext()
            }
        }
        func clearContext() {
            editingInternally = true
            super.unmarkText()
            text = ""
            composition.reset()
            editingInternally = false
        }
        override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
            updatingMarkedText = true
            super.setMarkedText(markedText, selectedRange: selectedRange)
            updatingMarkedText = false
        }
        override func unmarkText() {
            super.unmarkText()
            textViewDidChange(self)
        }
        func textViewDidChange(_ textView: UITextView) {
            guard !editingInternally, !updatingMarkedText, wantsKeyboard, isFirstResponder else { return }
            let actions = composition.update(text ?? "", hasMarkedText: markedTextRange != nil)
            guard markedTextRange == nil else { return }
            if text != composition.committed {
                editingInternally = true
                text = composition.committed
                selectedRange = NSRange(location: (text as NSString).length, length: 0)
                editingInternally = false
            }
            if !actions.isEmpty { onActions?(actions) }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            guard wantsKeyboard else { return }
            wantsKeyboard = false
            clearContext()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.wantsKeyboard else { return }
                self.onDismiss?()
            }
        }
        override func deleteBackward() {
            guard wantsKeyboard else { return }
            if markedTextRange == nil && (text ?? "").isEmpty {
                onActions?([.key(key: "delete", phase: "press", modifiers: 0)])
            } else { super.deleteBackward() }
        }
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if markedTextRange != nil {
                super.pressesBegan(presses, with: event)
                return
            }
            var remaining = Set<UIPress>()
            for press in presses {
                if wantsKeyboard, let key = press.key, let action = Self.remoteKey(key) {
                    clearContext()
                    remotePresses.insert(press)
                    onActions?([action])
                } else { remaining.insert(press) }
            }
            if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
        }
        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let remaining = Set(presses.filter { remotePresses.remove($0) == nil })
            if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
        }
        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let remaining = Set(presses.filter { remotePresses.remove($0) == nil })
            if !remaining.isEmpty { super.pressesCancelled(remaining, with: event) }
        }
        private static func remoteKey(_ key: UIKey) -> ComputerInputAction? {
            let names: [Int: String] = [40: "return", 41: "escape", 42: "delete", 43: "tab", 74: "home", 75: "pageup", 76: "forwarddelete", 77: "end", 78: "pagedown", 79: "right", 80: "left", 81: "down", 82: "up"]
            let code = Int(key.keyCode.rawValue)
            let flags = key.modifierFlags
            var modifiers: UInt32 = 0
            if flags.contains(.shift) { modifiers |= 1 }
            if flags.contains(.control) { modifiers |= 2 }
            if flags.contains(.alternate) { modifiers |= 4 }
            if flags.contains(.command) { modifiers |= 8 }
            if flags.contains(.alphaShift) { modifiers |= 16 }
            let name: String
            if let known = names[code] { name = known }
            else if (58...69).contains(code) { name = "f\(code - 57)" }
            else if flags.contains(.command) || flags.contains(.control) {
                let value = key.charactersIgnoringModifiers.lowercased()
                guard value.count == 1, value.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace }) else { return nil }
                name = value
            } else { return nil }
            return .key(key: name, phase: "press", modifiers: modifiers)
        }
    }
}

/// UIKit owns recognition; the session model is the only owner of remote input.
struct ComputerGestureSurface: UIViewRepresentable {
    let allowsInput: Bool
    let mode: ComputerInputMode
    let zoomScale: CGFloat
    let onTap: (CGPoint, CGSize, String) -> Void
    let onMove: (CGSize, CGSize) -> Void
    let onDragBegan: (CGPoint, CGSize) -> Void
    let onDragMoved: (CGPoint, CGSize) -> Void
    let onDragEnded: (CGPoint?, CGSize) -> Void
    let onScroll: (CGSize) -> Void
    let onPan: (CGSize, CGSize) -> Void
    let onPinch: (CGFloat) -> Void

    func makeUIView(context: Context) -> InputView { InputView() }
    func updateUIView(_ view: InputView, context: Context) {
        if view.mode != mode || (view.allowsInput && !allowsInput) { view.cancelDrag() }
        view.allowsInput = allowsInput
        view.mode = mode
        view.zoomScale = zoomScale
        view.onTap = onTap
        view.onMove = onMove
        view.onDragBegan = onDragBegan
        view.onDragMoved = onDragMoved
        view.onDragEnded = onDragEnded
        view.onScroll = onScroll
        view.onPan = onPan
        view.onPinch = onPinch
    }
    static func dismantleUIView(_ view: InputView, coordinator: ()) {
        view.cancelDrag()
        view.allowsInput = false
        view.onTap = nil; view.onMove = nil; view.onDragBegan = nil
        view.onDragMoved = nil; view.onDragEnded = nil
        view.onScroll = nil; view.onPan = nil; view.onPinch = nil
    }

    final class InputView: UIView, UIGestureRecognizerDelegate {
        var allowsInput = false
        var mode: ComputerInputMode = .trackpad
        var zoomScale: CGFloat = 1
        var onTap: ((CGPoint, CGSize, String) -> Void)?
        var onMove: ((CGSize, CGSize) -> Void)?
        var onDragBegan: ((CGPoint, CGSize) -> Void)?
        var onDragMoved: ((CGPoint, CGSize) -> Void)?
        var onDragEnded: ((CGPoint?, CGSize) -> Void)?
        var onScroll: ((CGSize) -> Void)?
        var onPan: ((CGSize, CGSize) -> Void)?
        var onPinch: ((CGFloat) -> Void)?
        private let tap = UITapGestureRecognizer()
        private let rightTap = UITapGestureRecognizer()
        private let rightHold = UILongPressGestureRecognizer()
        private let dragHold = UILongPressGestureRecognizer()
        private let singlePan = UIPanGestureRecognizer()
        private let twoPan = UIPanGestureRecognizer()
        private let pinch = UIPinchGestureRecognizer()
        private var dragActive = false
        private var suppressTap = false
        private var holdPoint: CGPoint?
        private var pinchStartScale: CGFloat = 1

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            tap.addTarget(self, action: #selector(tapped))
            rightTap.numberOfTouchesRequired = 2
            rightTap.addTarget(self, action: #selector(rightTapped))
            rightHold.minimumPressDuration = 0.5
            rightHold.addTarget(self, action: #selector(rightHeld))
            dragHold.numberOfTapsRequired = 1
            dragHold.minimumPressDuration = 0.18
            dragHold.addTarget(self, action: #selector(dragHeld))
            singlePan.maximumNumberOfTouches = 1
            singlePan.addTarget(self, action: #selector(singlePanned))
            twoPan.minimumNumberOfTouches = 2
            twoPan.maximumNumberOfTouches = 2
            twoPan.addTarget(self, action: #selector(twoPanned))
            pinch.addTarget(self, action: #selector(pinched))
            tap.require(toFail: singlePan)
            tap.require(toFail: rightHold)
            rightHold.require(toFail: dragHold)
            singlePan.require(toFail: dragHold)
            rightTap.require(toFail: twoPan)
            rightTap.require(toFail: pinch)
            for gesture in [tap, rightTap, rightHold, dragHold, singlePan, twoPan, pinch] {
                gesture.delegate = self
                addGestureRecognizer(gesture)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func cancelDrag() {
            if dragActive { onDragEnded?(nil, bounds.size) }
            dragActive = false
            holdPoint = nil
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if !dragActive { suppressTap = false }
            super.touchesBegan(touches, with: event)
        }
        @objc private func tapped() {
            guard allowsInput, !suppressTap else { return }
            onTap?(tap.location(in: self), bounds.size, "left")
        }
        @objc private func rightTapped() {
            guard allowsInput else { return }
            cancelDrag()
            onTap?(rightTap.location(in: self), bounds.size, "right")
        }
        @objc private func rightHeld() {
            guard allowsInput, rightHold.state == .began else { return }
            cancelDrag()
            onTap?(rightHold.location(in: self), bounds.size, "right")
        }
        @objc private func dragHeld() {
            guard allowsInput else { cancelDrag(); return }
            let point = dragHold.location(in: self)
            switch dragHold.state {
            case .began:
                suppressTap = true
                dragActive = true
                holdPoint = point
                onDragBegan?(point, bounds.size)
            case .changed:
                guard dragActive else { return }
                if mode == .trackpad, let previous = holdPoint {
                    onMove?(CGSize(width: point.x - previous.x, height: point.y - previous.y), bounds.size)
                } else { onDragMoved?(point, bounds.size) }
                holdPoint = point
            case .ended:
                if dragActive { onDragEnded?(point, bounds.size) }
                dragActive = false
                holdPoint = nil
            case .cancelled, .failed: cancelDrag()
            default: break
            }
        }
        @objc private func singlePanned() {
            guard allowsInput else { cancelDrag(); return }
            guard pinch.state != .began && pinch.state != .changed else { cancelDrag(); return }
            let point = singlePan.location(in: self)
            let delta = singlePan.translation(in: self)
            singlePan.setTranslation(.zero, in: self)
            switch singlePan.state {
            case .began:
                if mode == .directTouch {
                    dragActive = true
                    onDragBegan?(CGPoint(x: point.x - delta.x, y: point.y - delta.y), bounds.size)
                    onDragMoved?(point, bounds.size)
                } else { onMove?(CGSize(width: delta.x, height: delta.y), bounds.size) }
            case .changed:
                if mode == .directTouch {
                    if dragActive { onDragMoved?(point, bounds.size) }
                } else { onMove?(CGSize(width: delta.x, height: delta.y), bounds.size) }
            case .ended:
                if dragActive { onDragEnded?(point, bounds.size) }
                dragActive = false
            case .cancelled, .failed: cancelDrag()
            default: break
            }
        }
        @objc private func twoPanned() {
            guard pinch.state != .began && pinch.state != .changed else { twoPan.setTranslation(.zero, in: self); return }
            let delta = twoPan.translation(in: self)
            twoPan.setTranslation(.zero, in: self)
            guard twoPan.state == .began || twoPan.state == .changed else { return }
            cancelDrag()
            if zoomScale > 1 { onPan?(CGSize(width: delta.x, height: delta.y), bounds.size) }
            else if allowsInput { onScroll?(CGSize(width: delta.x, height: delta.y)) }
        }
        @objc private func pinched() {
            switch pinch.state {
            case .began:
                cancelDrag()
                pinchStartScale = zoomScale
            case .changed: onPinch?(pinchStartScale * pinch.scale)
            default: break
            }
        }
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            allowsInput || gestureRecognizer === pinch || (gestureRecognizer === twoPan && zoomScale > 1)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (gestureRecognizer === pinch && (other === twoPan || other === singlePan))
                || (other === pinch && (gestureRecognizer === twoPan || gestureRecognizer === singlePan))
                || (gestureRecognizer === tap && other === dragHold)
                || (gestureRecognizer === dragHold && other === tap)
        }
    }
}

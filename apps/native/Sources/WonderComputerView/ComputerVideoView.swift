#if canImport(UIKit)
import SwiftUI
import UIKit
@preconcurrency import WebRTC

public struct ComputerVideoView: UIViewRepresentable {
    private let receiver: ComputerReceiver

    public init(receiver: ComputerReceiver) {
        self.receiver = receiver
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(receiver: receiver)
    }

    public func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.backgroundColor = .black
        view.videoContentMode = .scaleAspectFit
        view.isEnabled = true
        receiver.attach(renderer: view)
        return view
    }

    public func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        view.videoContentMode = .scaleAspectFit
        receiver.attach(renderer: view)
    }

    public static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.receiver.detach(renderer: view)
        view.renderFrame(nil)
    }

    public final class Coordinator {
        fileprivate let receiver: ComputerReceiver

        fileprivate init(receiver: ComputerReceiver) {
            self.receiver = receiver
        }
    }
}
#endif

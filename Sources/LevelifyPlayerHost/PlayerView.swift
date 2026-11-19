import Foundation
import LevelifyKit
#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import SwiftUI
import WebKit
import Network

public struct LevelifyPlayerView: View {
    private let kit: LevelifyKit
    private let session: LKPlayerSession
    private let lesson: LKLessonFile
    private let stepId: String
    private let settings: LKPlayerSettings
    private let onState: @MainActor (LKPlayerState) -> Void
    private let onResult: @MainActor (LKPlayerResult) -> Void
    @State private var connected = true

    public init(
        kit: LevelifyKit,
        session: LKPlayerSession,
        lesson: LKLessonFile,
        stepId: String,
        settings: LKPlayerSettings,
        onState: @escaping @MainActor (LKPlayerState) -> Void,
        onResult: @escaping @MainActor (LKPlayerResult) -> Void
    ) {
        self.kit = kit
        self.session = session
        self.lesson = lesson
        self.stepId = stepId
        self.settings = settings
        self.onState = onState
        self.onResult = onResult
    }

    public var body: some View {
        PlayerWebView(session: session)
            .task { connected = await PlayerReachability.current() }
            .onAppear {
                session.show(lesson: lesson, stepId: stepId, settings: settings, connected: connected, onState: onState, onResult: onResult)
            }
            .onDisappear { session.hide(stepId: stepId) }
    }
}

private struct PlayerWebView: UIViewRepresentable {
    let session: LKPlayerSession

    func makeUIView(context: Context) -> WKWebView { session.makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private enum PlayerReachability {
    static func current() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "levelifykit.reachability")
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: queue)
        }
    }
}
#endif

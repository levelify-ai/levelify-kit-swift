import Foundation
import LevelifyKit
#if canImport(UIKit)
@preconcurrency import UIKit
import AudioToolbox
#endif
#if canImport(WebKit) && canImport(UIKit)
@preconcurrency import WebKit
#endif

/// One Player session. Creating it starts loading the Player build.
@MainActor
public final class LKPlayerSession {
    private let kit: LevelifyKit
    package var logic = PlayerLogic()
    private var onState: (@MainActor (LKPlayerState) -> Void)?
    private var onResult: (@MainActor (LKPlayerResult) -> Void)?
    private var shownStep: String?

    #if canImport(WebKit) && canImport(UIKit)
    private var webViewStore: WKWebView?
    private var proxy: PlayerBridgeProxy?
    private var allowedMain = false
    private var timeoutTask: Task<Void, Never>?
    #endif

    public init(kit: LevelifyKit) {
        self.kit = kit
        Task { await kit.content.preloadPlayer() }
    }

    package func show(
        lesson: LKLessonFile,
        stepId: String,
        settings: LKPlayerSettings,
        connected: Bool,
        onState: @escaping @MainActor (LKPlayerState) -> Void,
        onResult: @escaping @MainActor (LKPlayerResult) -> Void
    ) {
        self.onState = onState
        self.onResult = onResult
        logic.settings = settings
        shownStep = stepId
        Task { @MainActor in
            let context = await kit.content.stepContext(lesson, stepId: stepId)
            guard self.shownStep == stepId else { return }
            let effects = self.logic.appear(
                stepId: stepId,
                lessonId: context.lessonId,
                lessonVersion: context.lessonVersion,
                step: context.step,
                media: context.media,
                filesReady: context.filesReady,
                connected: connected
            )
            self.apply(effects)
            #if canImport(WebKit) && canImport(UIKit)
            self.ensurePage()
            #endif
        }
    }

    package func hide(stepId: String) {
        guard shownStep == stepId else { return }
        shownStep = nil
        apply(logic.disappear())
        #if canImport(WebKit) && canImport(UIKit)
        timeoutTask?.cancel()
        #endif
    }

    package func apply(_ effects: [PlayerEffect]) {
        for effect in effects {
            switch effect {
            case .state(let state):
                #if canImport(WebKit) && canImport(UIKit)
                if case .loading = state {
                    if timeoutTask == nil { armTimeout() }
                } else {
                    timeoutTask?.cancel()
                    timeoutTask = nil
                }
                #endif
                onState?(state)
            case .result(let result):
                onResult?(result)
            case .send(let message):
                #if canImport(WebKit) && canImport(UIKit)
                send(message)
                #endif
            case .haptic(let kind):
                playHaptic(kind)
            case .sound(let kind):
                playSound(kind)
            case .announce(let text):
                announce(text)
            }
        }
    }

    private func playHaptic(_ kind: String) {
        #if canImport(UIKit)
        switch kind {
        case "success", "celebrate":
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "error":
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "tap":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        default:
            break
        }
        #endif
    }

    private func playSound(_ kind: String) {
        #if canImport(UIKit)
        let id: SystemSoundID
        switch kind {
        case "correct": id = 1057
        case "wrong": id = 1053
        case "tap": id = 1104
        default: return
        }
        AudioServicesPlaySystemSound(id)
        #endif
    }

    private func announce(_ text: String) {
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: text)
        #endif
    }

    #if canImport(WebKit) && canImport(UIKit)
    package func makeWebView() -> WKWebView {
        if let webViewStore { return webViewStore }
        let proxy = PlayerBridgeProxy(session: self)
        self.proxy = proxy
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(proxy, forURLScheme: "levelify-player")
        configuration.userContentController.add(proxy, name: "levelify")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = proxy
        view.uiDelegate = proxy
        view.scrollView.bounces = false
        webViewStore = view
        installNetworkBlock(on: view)
        return view
    }

    fileprivate func ensurePage() {
        let view = makeWebView()
        guard !allowedMain else { return }
        view.load(URLRequest(url: URL(string: "levelify-player://player/index.html")!))
    }

    fileprivate func receiveWire(_ text: String) {
        switch parseMessage(text, direction: .toHost) {
        case .accept(let message):
            apply(logic.receive(message))
        case .ignore(let code, let type, _):
            LKLog.call("bridge", status: 0, code: "\(code) \(type)")
        case .reject(let code, _):
            // Keep the 8-second timer. A rejected Player message is logged and changes nothing else.
            LKLog.call("bridge", status: 0, code: "player.error internal \(code)")
        }
    }

    fileprivate func allow(_ action: WKNavigationAction) -> Bool {
        guard action.targetFrame?.isMainFrame == true else { return false }
        guard let raw = action.request.url?.absoluteString else { return false }
        guard case .build(let file, _) = resolvePlayerUrl(raw), file == "index.html", !allowedMain else { return false }
        allowedMain = true
        return true
    }

    /// `raw` is the URL text the scheme task handed over. It is not normalised before `resolvePlayerUrl`.
    fileprivate func file(for raw: String) async -> (data: Data, contentType: String)? {
        switch resolvePlayerUrl(raw) {
        case .build(let file, let contentType):
            guard let data = await kit.content.playerBuildFile(file) else { return nil }
            return (data, contentType)
        case .media(let sha, _, let contentType):
            guard let data = await kit.content.playerMediaFile(sha256: sha) else { return nil }
            return (data, contentType)
        case .notFound:
            return nil
        }
    }

    private func send(_ message: PlayerOutgoing) {
        guard let webViewStore else { return }
        var payload: [String: Any] = [:]
        for (key, value) in message.payload { payload[key] = plist(value) }
        var envelope: [String: Any] = [
            "bridge": message.bridge,
            "id": UUID().uuidString.lowercased(),
            "type": message.type,
            "payload": payload,
        ]
        if let replyTo = message.replyTo { envelope["replyTo"] = replyTo }
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8) else { return }
        webViewStore.callAsyncJavaScript(
            "window.levelifyPlayer.receive(message)",
            arguments: ["message": json],
            in: nil,
            in: .page
        ) { _ in }
    }

    private func armTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(playerReadyTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.apply(self.logic.timeout())
        }
    }

    private func installNetworkBlock(on view: WKWebView) {
        let rules = "[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}}]"
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "levelify-kit-block-network", encodedContentRuleList: rules) { [weak self] list, _ in
            guard let list else { return }
            let rule = UncheckedSendable(list)
            Task { @MainActor in
                self?.webViewStore?.configuration.userContentController.add(rule.value)
            }
        }
    }

    private func plist(_ json: LKJSON) -> Any {
        switch json {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            if value.rounded() == value { return Int(value) }
            return value
        case .string(let value): return value
        case .array(let values): return values.map(plist)
        case .object(let object): return object.mapValues(plist)
        }
    }
    #endif
}

#if canImport(WebKit) && canImport(UIKit)
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

final class PlayerBridgeProxy: NSObject, WKScriptMessageHandler, WKURLSchemeHandler, WKNavigationDelegate, WKUIDelegate, @unchecked Sendable {
    weak var session: LKPlayerSession?
    private let stopped = LKLocked<Set<ObjectIdentifier>>([])

    init(session: LKPlayerSession) { self.session = session }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "levelify", message.frameInfo.isMainFrame, let body = message.body as? String else { return }
        let text = body
        Task { @MainActor in self.session?.receiveWire(text) }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        let raw = urlSchemeTask.request.url?.absoluteString ?? ""
        let task = UncheckedSendable(urlSchemeTask)
        let url = urlSchemeTask.request.url
        Task { @MainActor in
            guard !self.isStopped(id) else { return }
            let served = await self.session?.file(for: raw)
            guard !self.isStopped(id) else { return }
            let status = served == nil ? 404 : 200
            let mime = served?.contentType ?? "text/plain"
            let body = served?.data ?? Data()
            let responseURL = url ?? URL(string: "levelify-player://player/")!
            let response = HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
            task.value.didReceive(response)
            task.value.didReceive(body)
            task.value.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        markStopped(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            let allow = self.session?.allow(navigationAction) ?? false
            decisionHandler(allow ? .allow : .cancel)
        }
    }

    private func isStopped(_ id: ObjectIdentifier) -> Bool {
        stopped.withLock { $0.contains(id) }
    }

    private func markStopped(_ id: ObjectIdentifier) {
        stopped.withLock { $0.insert(id) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        completionHandler(nil)
    }
}
#endif

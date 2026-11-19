import Foundation
import Testing
import LevelifyKit

@Test func levelifyDevGuestRoundTrip() async throws {
    let env = ProcessInfo.processInfo.environment
    let supabase = env["LEVELIFY_DEV_SUPABASE_URL"] ?? ""
    let key = env["LEVELIFY_DEV_PUBLISHABLE_KEY"] ?? ""
    if supabase.isEmpty || key.isEmpty { return }
    let supabaseURL = try #require(URL(string: supabase))
    let root = supabaseURL.absoluteString.hasSuffix("/") ? supabaseURL.absoluteString : supabaseURL.absoluteString + "/"
    let contentURL = try #require(URL(string: root + "storage/v1/object/public/content"))
    let kit = try LevelifyKit.configure(LevelifyConfig(
        supabaseURL: supabaseURL,
        publishableKey: key,
        contentBaseURL: contentURL,
        client: LKClientInfo(platform: "ios", appVersion: "0.1.0", build: "1"),
        capabilities: .rorkIOS4fe5be7
    ))
    await kit.auth.confirmAgeGate(minorUntil: nil)
    let config: LKAppConfig
    do {
        config = try await kit.config.refresh()
    } catch let error as LKError {
        // D2 deploys get_app_config on Friday. Until then dev answers 404 and this round trip cannot run.
        if case .server(let code, let status) = error, status == 404, code.contains("get_app_config") {
            return
        }
        throw error
    }
    #expect(config.serverTime != nil)
    _ = try await kit.content.refresh()
    let lesson = try await kit.content.lesson(id: "aut-l2-u1-l1")
    #expect(lesson.id == "aut-l2-u1-l1")
    #expect(lesson.version.count == 64)
    let session = UUID()
    await kit.progress.record(LKAttempt(
        sessionId: session,
        lessonId: lesson.id,
        lessonVersion: lesson.version,
        stepId: lesson.lesson.steps.first?.id ?? "aut-l2-u1-l1-e1",
        position: 0,
        mode: .lesson,
        response: .choice(0),
        correct: true
    ))
    await kit.progress.complete(LKSessionCompletion(
        id: session,
        mode: .lesson,
        lessonId: lesson.id,
        lessonVersion: lesson.version,
        unitId: nil,
        startedAt: Date().addingTimeInterval(-30),
        stepCount: 1
    ))
    let sync = await kit.progress.flush()
    #expect(sync.error == nil)
    let state = try await kit.progress.state()
    #expect(state.userId.uuidString.isEmpty == false)
    let again = await kit.progress.flush()
    #expect(again.sent == 0)
    _ = try await kit.progress.state()
}

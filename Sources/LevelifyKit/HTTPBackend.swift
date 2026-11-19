import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supabase Auth and PostgREST over URLSession. Used on Linux, where supabase-swift does not build.
package final class HTTPBackend: LKBackend, @unchecked Sendable {
    private let supabaseURL: URL
    private let publishableKey: String
    private let clientHeader: String
    private let sessionFile: URL
    private let urlSession: URLSession
    private let state: LKLocked<StoredSession?>

    package init(config: LevelifyConfig, directory: URL, urlSession: URLSession = .shared) {
        supabaseURL = config.supabaseURL
        publishableKey = config.publishableKey
        clientHeader = config.client.headerValue
        sessionFile = directory.appendingPathComponent("auth-session.json")
        self.urlSession = urlSession
        state = LKLocked(Self.read(sessionFile))
    }

    package func rpc(name: String, body: Data?, accessToken: String?) async throws -> Data {
        let url = supabaseURL.appendingPathComponent("rest/v1/rpc/\(name)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body ?? Data("{}".utf8)
        apply(&request, accessToken: accessToken)
        let (data, response) = try await send(request, name: name)
        return try unwrap(data, response, name: name)
    }

    package func get(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request, name: "GET")
        return try unwrap(data, response, name: "GET")
    }

    package func signInAnonymously() async throws -> LKSessionMaterial {
        let url = supabaseURL.appendingPathComponent("auth/v1/signup")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        apply(&request, accessToken: nil)
        let (data, response) = try await send(request, name: "signInAnonymously")
        let body = try unwrap(data, response, name: "signInAnonymously")
        let stored = try decodeSession(body)
        write(stored)
        return stored.material
    }

    package func restoreSession() async -> LKSessionMaterial? {
        let stored = state.withLock { $0 }
        guard let stored else { return nil }
        if stored.expiresAt > Date().timeIntervalSince1970 + 30 {
            return stored.material
        }
        do {
            return try await refresh(stored)
        } catch {
            return nil
        }
    }

    package func signOut() async throws {
        let token = state.withLock { $0?.accessToken }
        if let token {
            let url = supabaseURL.appendingPathComponent("auth/v1/logout")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            apply(&request, accessToken: token)
            _ = try? await send(request, name: "signOut")
        }
        write(nil)
    }

    private func refresh(_ stored: StoredSession) async throws -> LKSessionMaterial {
        var parts = URLComponents(url: supabaseURL.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let url = parts?.url else { throw LKError.offline }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": stored.refreshToken])
        apply(&request, accessToken: nil)
        let (data, response) = try await send(request, name: "refreshSession")
        let body = try unwrap(data, response, name: "refreshSession")
        let next = try decodeSession(body)
        write(next)
        return next.material
    }

    private func apply(_ request: inout URLRequest, accessToken: String?) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken ?? publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue(clientHeader, forHTTPHeaderField: "x-levelify-client")
    }

    private func send(_ request: URLRequest, name: String) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LKTransportError(status: 0, code: "offline", offline: true)
            }
            return (data, http)
        } catch let error as LKTransportError {
            throw error
        } catch {
            if Self.isOffline(error) {
                LKLog.call(name, status: 0, code: "offline")
                throw LKTransportError(status: 0, code: "offline", offline: true)
            }
            throw error
        }
    }

    private func unwrap(_ data: Data, _ response: HTTPURLResponse, name: String) throws -> Data {
        let retryAfter = Self.retryAfter(response)
        if (200..<300).contains(response.statusCode) {
            LKLog.call(name, status: response.statusCode)
            return data
        }
        let code = Self.errorCode(data) ?? "http_\(response.statusCode)"
        LKLog.call(name, status: response.statusCode, code: code)
        throw LKTransportError(status: response.statusCode, code: code, retryAfter: retryAfter)
    }

    private func decodeSession(_ data: Data) throws -> StoredSession {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard
            let access = object?["access_token"] as? String,
            let refresh = object?["refresh_token"] as? String,
            let user = object?["user"] as? [String: Any],
            let idText = user["id"] as? String,
            let id = UUID(uuidString: idText)
        else {
            throw LKTransportError(status: 200, code: "bad_session")
        }
        let guest = (user["is_anonymous"] as? Bool) ?? true
        let expires = object?["expires_at"] as? TimeInterval ?? (Date().timeIntervalSince1970 + 3600)
        return StoredSession(accessToken: access, refreshToken: refresh, userId: id, isGuest: guest, expiresAt: expires)
    }

    private func write(_ session: StoredSession?) {
        state.withLock { $0 = session }
        if let session {
            if let data = try? JSONEncoder().encode(session) {
                try? data.write(to: sessionFile, options: .atomic)
            }
        } else {
            try? FileManager.default.removeItem(at: sessionFile)
        }
    }

    private static func read(_ url: URL) -> StoredSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    private static func errorCode(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = object["message"] as? String, !message.isEmpty { return message }
        if let code = object["error_code"] as? String, !code.isEmpty { return code }
        if let code = object["code"] as? String, !code.isEmpty { return code }
        return nil
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) { return seconds }
        return nil
    }

    package static func isOffline(_ error: Error) -> Bool {
        let code = (error as? URLError)?.code
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed, .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}

private struct StoredSession: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var userId: UUID
    var isGuest: Bool
    var expiresAt: TimeInterval

    var material: LKSessionMaterial {
        LKSessionMaterial(userId: userId, isGuest: isGuest, accessToken: accessToken)
    }
}

import Foundation
#if canImport(Supabase)
import Supabase

/// Apple backend. Linux CI uses `HTTPBackend` because supabase-swift does not build there.
package final class SupabaseBackend: LKBackend, @unchecked Sendable {
    private let client: SupabaseClient

    package init(config: LevelifyConfig) {
        client = SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.publishableKey,
            options: SupabaseClientOptions(
                auth: .init(emitLocalSessionAsInitialSession: true),
                global: .init(headers: ["x-levelify-client": config.client.headerValue])
            )
        )
    }

    package func rpc(name: String, body: Data?, accessToken: String?) async throws -> Data {
        _ = accessToken
        do {
            let response: PostgrestResponse<Void>
            if let body, let json = try? LKCoding.decode(LKJSON.self, from: body), case .object = json {
                response = try await client.rpc(name, params: JSONParam(json: json)).execute()
            } else {
                response = try await client.rpc(name).execute()
            }
            LKLog.call(name, status: response.status)
            return response.data
        } catch {
            throw Self.transport(error, name: name)
        }
    }

    package func get(url: URL) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw LKTransportError(status: 0, code: "offline", offline: true)
            }
            if (200..<300).contains(http.statusCode) {
                LKLog.call("GET", status: http.statusCode)
                return data
            }
            LKLog.call("GET", status: http.statusCode, code: "http_\(http.statusCode)")
            throw LKTransportError(status: http.statusCode, code: "http_\(http.statusCode)")
        } catch let error as LKTransportError {
            throw error
        } catch {
            if HTTPBackend.isOffline(error) {
                throw LKTransportError(status: 0, code: "offline", offline: true)
            }
            throw error
        }
    }

    package func signInAnonymously() async throws -> LKSessionMaterial {
        do {
            let session = try await client.auth.signInAnonymously()
            LKLog.call("signInAnonymously", status: 200)
            return Self.material(session)
        } catch {
            throw Self.transport(error, name: "signInAnonymously")
        }
    }

    package func restoreSession() async -> LKSessionMaterial? {
        if let current = client.auth.currentSession, current.expiresAt > Date().timeIntervalSince1970 + 30 {
            return Self.material(current)
        }
        do {
            return Self.material(try await client.auth.session)
        } catch {
            return nil
        }
    }

    package func signOut() async throws {
        do {
            try await client.auth.signOut()
            LKLog.call("signOut", status: 200)
        } catch {
            throw Self.transport(error, name: "signOut")
        }
    }

    private static func material(_ session: Session) -> LKSessionMaterial {
        LKSessionMaterial(userId: session.user.id, isGuest: session.user.isAnonymous, accessToken: session.accessToken)
    }

    private static func transport(_ error: Error, name: String) -> Error {
        if let http = error as? HTTPError {
            let code = httpCode(http.data) ?? "http_\(http.response.statusCode)"
            LKLog.call(name, status: http.response.statusCode, code: code)
            return LKTransportError(status: http.response.statusCode, code: code, retryAfter: nil)
        }
        if let postgrest = error as? PostgrestError {
            let code = postgrest.message.isEmpty ? (postgrest.code ?? "postgrest") : postgrest.message
            LKLog.call(name, status: 400, code: code)
            return LKTransportError(status: 400, code: code)
        }
        if HTTPBackend.isOffline(error) {
            LKLog.call(name, status: 0, code: "offline")
            return LKTransportError(status: 0, code: "offline", offline: true)
        }
        return error
    }

    private static func httpCode(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = object["message"] as? String, !message.isEmpty { return message }
        if let code = object["code"] as? String, !code.isEmpty { return code }
        return nil
    }
}

private struct JSONParam: Encodable {
    var json: LKJSON
    func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}
#endif

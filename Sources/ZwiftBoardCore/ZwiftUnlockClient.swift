import Foundation

public actor ZwiftUnlockClient {
    private static let clientID = "Zwift Game Client"
    private static let tokenURL = URL(string: "https://secure.zwift.com/auth/realms/zwift/protocol/openid-connect/token")!
    private static let dlockURL = URL(string: "https://us-or-rly101.zwift.com/api/d-lock-service/device/authenticate")!
    private static let refreshTokenKey = "ZwiftBoard.RefreshToken"
    private static let formAllowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()

    private var accessToken: String?
    private var expiresAt: Date = .distantPast
    private var refreshToken: String? {
        didSet {
            if let rt = refreshToken {
                UserDefaults.standard.set(rt, forKey: Self.refreshTokenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.refreshTokenKey)
            }
        }
    }

    public init() {
        self.refreshToken = UserDefaults.standard.string(forKey: Self.refreshTokenKey)
    }

    public static func encodeFormComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
    }

    public var isSignedIn: Bool {
        refreshToken != nil && !(refreshToken?.isEmpty ?? true)
    }

    public func signOut() {
        accessToken = nil
        expiresAt = .distantPast
        refreshToken = nil
    }

    public func login(email: String, password: String) async throws {
        let params = [
            "grant_type": "password",
            "client_id": Self.clientID,
            "username": email,
            "password": password
        ]
        try await requestToken(params: params)
    }

    public func solve(challenge: Data) async throws -> Data {
        guard isSignedIn else {
            throw UnlockError.notSignedIn
        }
        if accessToken == nil || Date().addingTimeInterval(60) >= expiresAt {
            try await refresh()
        }
        do {
            return try await authenticate(challenge: challenge)
        } catch UnlockError.unauthorized {
            try await refresh()
            return try await authenticate(challenge: challenge)
        }
    }

    private func refresh() async throws {
        guard let rt = refreshToken else { throw UnlockError.notSignedIn }
        let params = [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": rt
        ]
        try await requestToken(params: params)
    }

    private func requestToken(params: [String: String]) async throws {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15

        let body = params
            .sorted { $0.key < $1.key }
            .map { k, v in "\(Self.encodeFormComponent(k))=\(Self.encodeFormComponent(v))" }
            .joined(separator: "&")
        req.httpBody = Data(body.utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw UnlockError.network("Invalid HTTP response")
        }
        guard http.statusCode == 200 else {
            let errObj = (try? JSONDecoder().decode(TokenError.self, from: data))?.error ?? "HTTP \(http.statusCode)"
            if ["invalid_grant", "invalid_client", "unauthorized_client"].contains(errObj) {
                signOut()
                throw UnlockError.authRejected(errObj)
            }
            throw UnlockError.network("Token request failed: \(errObj)")
        }

        let tr = try JSONDecoder().decode(TokenResponse.self, from: data)
        self.accessToken = tr.access_token
        if let rt = tr.refresh_token, !rt.isEmpty {
            self.refreshToken = rt
        }
        self.expiresAt = Date().addingTimeInterval(TimeInterval(tr.expires_in ?? 300))
    }

    private func authenticate(challenge: Data) async throws -> Data {
        guard let token = accessToken else { throw UnlockError.notSignedIn }
        var req = URLRequest(url: Self.dlockURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-protobuf-lite", forHTTPHeaderField: "Content-Type")
        req.setValue("application/x-protobuf-lite", forHTTPHeaderField: "Accept")
        req.httpBody = challenge

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw UnlockError.network("Invalid HTTP response")
        }
        if http.statusCode == 401 {
            throw UnlockError.unauthorized
        }
        guard http.statusCode == 200 else {
            throw UnlockError.network("d-lock HTTP \(http.statusCode)")
        }
        return data
    }

    public enum UnlockError: LocalizedError {
        case notSignedIn
        case unauthorized
        case authRejected(String)
        case network(String)

        public var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Not signed in to Zwift"
            case .unauthorized: return "Zwift token expired"
            case .authRejected(let code): return "Zwift sign-in rejected (\(code))"
            case .network(let msg): return msg
            }
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
    }

    private struct TokenError: Decodable {
        let error: String
    }
}

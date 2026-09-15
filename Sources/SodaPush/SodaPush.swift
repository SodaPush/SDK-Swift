//
//  SodaPush.swift
//  SodaPush
//
//  Created by Phineas Guo on 2026/9/13.
//

@_exported import RuntimeSecretMacro

import CryptoKit
import Foundation
import Security

public enum SodaPushEnvironment: String, Codable, Sendable {
    case development
    case production
    static var auto: SodaPushEnvironment {
        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }
}

public struct SodaPushConfiguration: Sendable {
    public let serverURL: URL
    public let appID: String
    public let registrationKeyID: String
    public let registrationSecret: String
    public let environment: SodaPushEnvironment

    public init(
        serverURL: URL,
        appID: String,
        registrationKeyID: String,
        registrationSecret: String,
        environment: SodaPushEnvironment
    ) {
        self.serverURL = serverURL
        self.appID = appID
        self.registrationKeyID = registrationKeyID
        self.registrationSecret = registrationSecret
        self.environment = environment
    }
}

public struct SodaPushDeviceContext: Codable, Sendable, Equatable {
    public var platform: String
    public var appVersion: String?
    public var appBuild: String?
    public var locale: String?
    public var language: String?
    public var timeZone: String?
    public var userID: String?
    public var tags: [String]

    public static var currentPlatform: String {
        #if os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(watchOS)
        "watchOS"
        #elseif os(visionOS)
        "visionOS"
        #else
        "Apple"
        #endif
    }

    public init(
        platform: String = SodaPushDeviceContext.currentPlatform,
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        appBuild: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        locale: String? = Locale.current.identifier,
        language: String? = Locale.preferredLanguages.first,
        timeZone: String? = TimeZone.current.identifier,
        userID: String? = nil,
        tags: [String] = []
    ) {
        self.platform = platform
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.locale = locale
        self.language = language
        self.timeZone = timeZone
        self.userID = userID
        self.tags = Self.normalizedTags(tags)
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        Array(Set(tags.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

public struct SodaPushDeviceRegistration: Codable, Sendable, Equatable {
    public let installationID: UUID
    public let environment: SodaPushEnvironment
    public let updatedAt: Date?
}

public enum SodaPushError: Error, LocalizedError, Sendable, Equatable {
    case invalidServerURL
    case invalidDeviceToken
    case invalidResponse
    case server(statusCode: Int, code: String?, message: String?, requestID: String?)
    case transport(String)
    case encoding(String)
    case randomGeneration(statusCode: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "The SodaPush server URL must be an HTTPS origin without a path, query, fragment, or credentials."
        case .invalidDeviceToken:
            return "The APNs device token must not be empty."
        case .invalidResponse:
            return "The SodaPush server returned an invalid response."
        case let .server(statusCode, code, message, requestID):
            let description = ["HTTP \(statusCode)", code, message].compactMap { $0 }.joined(separator: ": ")
            return requestID.map { "\(description) (request ID: \($0))" } ?? description
        case let .transport(message):
            return "SodaPush network request failed: \(message)"
        case let .encoding(message):
            return "SodaPush request encoding failed: \(message)"
        case let .randomGeneration(statusCode):
            return "SodaPush could not generate a secure request nonce (Security status \(statusCode))."
        }
    }
}

public actor SodaPushClient {
    private let configuration: SodaPushConfiguration
    private let session: URLSession
    private let serverURL: URL?
    private let installationID: UUID
    private var context: SodaPushDeviceContext

    public init(
        configuration: SodaPushConfiguration,
        installationID: UUID? = nil,
        context: SodaPushDeviceContext = SodaPushDeviceContext(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        let normalizedServerURL = SodaPushURL.normalizedOrigin(configuration.serverURL)
        self.serverURL = normalizedServerURL
        self.installationID = installationID ?? SodaPushInstallationIdentity.loadOrCreate(
            serverURL: normalizedServerURL ?? configuration.serverURL,
            appID: configuration.appID,
            environment: configuration.environment
        )
        self.context = context
        self.session = session
    }

    public func updateContext(_ context: SodaPushDeviceContext) {
        self.context = context
    }

    /// Replaces the custom targeting tags included in the next device registration.
    public func updateTags(_ tags: [String]) {
        context.tags = Array(Set(tags.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    /// Associates this installation with an application-defined user identifier.
    public func updateUserID(_ userID: String?) {
        let normalized = userID?.trimmingCharacters(in: .whitespacesAndNewlines)
        context.userID = normalized?.isEmpty == false ? normalized : nil
    }

    @discardableResult
    public func updateDeviceToken(_ token: Data) async throws -> SodaPushDeviceRegistration {
        guard !token.isEmpty else {
            throw SodaPushError.invalidDeviceToken
        }
        guard let serverURL else {
            throw SodaPushError.invalidServerURL
        }

        let requestBody = DeviceRegistrationRequest(
            deviceToken: token.map { String(format: "%02x", $0) }.joined(),
            environment: configuration.environment,
            context: context
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let body: Data
        do {
            body = try encoder.encode(requestBody)
        } catch {
            throw SodaPushError.encoding(error.localizedDescription)
        }

        let path = "/v1/apps/\(configuration.appID)/devices/\(installationID.uuidString.lowercased())/register"
        var request = URLRequest(url: SodaPushURL.requestURL(origin: serverURL, path: path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try sign(&request, canonicalTarget: path, body: body)
        return try await send(request)
    }

    public func unregister() async throws {
        guard let serverURL else {
            throw SodaPushError.invalidServerURL
        }

        let path = "/v1/apps/\(configuration.appID)/devices/\(installationID.uuidString.lowercased())/unregister"
        let body = try JSONEncoder().encode(UnregisterRequest(environment: configuration.environment))
        var request = URLRequest(url: SodaPushURL.requestURL(origin: serverURL, path: path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try sign(&request, canonicalTarget: path, body: body)
        _ = try await sendRaw(request)
    }

    private func send(_ request: URLRequest) async throws -> SodaPushDeviceRegistration {
        let data = try await sendRaw(request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(SodaPushDeviceRegistration.self, from: data)
        } catch {
            throw SodaPushError.invalidResponse
        }
    }

    private func sendRaw(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SodaPushError.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let serverError = try? JSONDecoder().decode(SodaPushServerError.self, from: data)
                throw SodaPushError.server(
                    statusCode: httpResponse.statusCode,
                    code: serverError?.code,
                    message: serverError?.message,
                    requestID: serverError?.requestId ?? httpResponse.value(forHTTPHeaderField: "X-Request-ID")
                )
            }
            return data
        } catch let error as SodaPushError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SodaPushError.transport(error.localizedDescription)
        }
    }

    private func sign(_ request: inout URLRequest, canonicalTarget: String, body: Data) throws {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = try randomNonce()
        let bodyHash = Data(SHA256.hash(data: body)).base64URLEncodedString
        let signingInput = [request.httpMethod ?? "GET", canonicalTarget, timestamp, nonce, bodyHash].joined(separator: "\n")
        let key = SymmetricKey(data: Data(configuration.registrationSecret.utf8))
        let signature = Data(HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8),
            using: key
        )).base64URLEncodedString
        request.setValue(configuration.registrationKeyID, forHTTPHeaderField: "X-Soda-Key-ID")
        request.setValue(timestamp, forHTTPHeaderField: "X-Soda-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Soda-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-Soda-Signature")
    }

    private func randomNonce() throws -> String {
        var data = Data(count: 16)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw SodaPushError.randomGeneration(statusCode: status)
        }
        return data.base64URLEncodedString
    }
}

private struct DeviceRegistrationRequest: Codable, Sendable {
    let deviceToken: String
    let environment: SodaPushEnvironment
    let context: SodaPushDeviceContext
}

private struct UnregisterRequest: Codable, Sendable {
    let environment: SodaPushEnvironment
}

private struct SodaPushServerError: Codable, Sendable {
    let code: String?
    let message: String?
    let requestId: String?
}

private enum SodaPushURL {
    static func normalizedOrigin(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            return nil
        }

        components.scheme = "https"
        components.host = host.lowercased()
        components.path = ""
        if components.port == 443 {
            components.port = nil
        }
        return components.url
    }

    static func requestURL(origin: URL, path: String, percentEncodedQuery: String? = nil) -> URL {
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        components.percentEncodedQuery = percentEncodedQuery
        return components.url!
    }
}

private enum SodaPushInstallationIdentity {
    private static let lock = NSLock()
    private static let keyPrefix = "dev.sodapush.installation-id."

    static func loadOrCreate(serverURL: URL, appID: String, environment: SodaPushEnvironment) -> UUID {
        let scope = [serverURL.absoluteString, appID, environment.rawValue].joined(separator: "\n")
        let scopeHash = Data(SHA256.hash(data: Data(scope.utf8))).base64URLEncodedString
        let key = keyPrefix + scopeHash

        lock.lock()
        defer { lock.unlock() }

        if let storedValue = UserDefaults.standard.string(forKey: key),
           let storedID = UUID(uuidString: storedValue) {
            return storedID
        }

        let newID = UUID()
        UserDefaults.standard.set(newID.uuidString.lowercased(), forKey: key)
        return newID
    }
}

private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

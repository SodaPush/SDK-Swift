//
//  SodaPushTests.swift
//  SodaPushTests
//
//  Created by Phineas Guo on 2026/9/13.
//

import CryptoKit
import Foundation
@testable import SodaPush
import XCTest

@MainActor
final class SodaPushTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testSecretMacroReturnsAString() {
        let value: String = #Secret("sdk-test-secret")

        XCTAssertEqual(value, "sdk-test-secret")
    }

    func testEnvironmentIsCodable() throws {
        let encoded = try JSONEncoder().encode(SodaPushEnvironment.production)
        let decoded = try JSONDecoder().decode(SodaPushEnvironment.self, from: encoded)

        XCTAssertEqual(decoded, .production)
    }

    func testRegistrationRequestMatchesServerContract() async throws {
        let installationID = UUID(uuidString: "D1B28F5A-F77B-44D5-A00A-68B6529E553A")!
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            var capturedRequest = request
            capturedRequest.httpBody = request.bodyData
            recorder.append(capturedRequest)
            return Self.response(
                for: request,
                statusCode: 200,
                body: #"{"installationID":"d1b28f5a-f77b-44d5-a00a-68b6529e553a","environment":"production","updatedAt":"2026-09-14T12:34:56.789Z"}"#
            )
        }
        let client = makeClient(installationID: installationID)
        await client.updateContext(.init(
            platform: "test",
            appVersion: "1.2.3",
            appBuild: "45",
            locale: "en_US",
            language: "en",
            timeZone: "America/Los_Angeles",
            userID: "customer-42",
            tags: ["paid", "beta", "paid"]
        ))

        let registration = try await client.updateDeviceToken(Data([0x00, 0xab, 0xff]))

        XCTAssertEqual(registration.installationID, installationID)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/apps/app-id/devices/d1b28f5a-f77b-44d5-a00a-68b6529e553a/register")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["deviceToken"] as? String, "00abff")
        XCTAssertEqual(json["environment"] as? String, "production")
        let context = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertEqual(context["platform"] as? String, "test")
        XCTAssertEqual(context["language"] as? String, "en")
        XCTAssertEqual(context["userID"] as? String, "customer-42")
        XCTAssertEqual(context["tags"] as? [String], ["beta", "paid"])
        assertValidSignature(request, canonicalTarget: request.url!.path, body: body)
    }

    func testUnregisterIncludesEnvironmentInBodyAndSignature() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.append(request)
            return Self.response(for: request, statusCode: 204)
        }
        let client = makeClient(
            installationID: UUID(uuidString: "D1B28F5A-F77B-44D5-A00A-68B6529E553A")!
        )

        try await client.unregister()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/apps/app-id/devices/d1b28f5a-f77b-44d5-a00a-68b6529e553a/unregister")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.bodyData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["environment"], "production")
        assertValidSignature(
            request,
            canonicalTarget: request.url!.path,
            body: body
        )
    }

    func testDefaultInstallationIDIsStableForSameScope() async throws {
        let recorder = RequestRecorder()
        URLProtocolStub.handler = { request in
            recorder.append(request)
            return Self.response(
                for: request,
                statusCode: 200,
                body: #"{"installationID":"d1b28f5a-f77b-44d5-a00a-68b6529e553a","environment":"production","updatedAt":null}"#
            )
        }
        let configuration = SodaPushConfiguration(
            serverURL: URL(string: "https://EXAMPLE.com:443/")!,
            appID: "scope-\(UUID().uuidString)",
            registrationKeyID: "key-id",
            registrationSecret: "registration-secret",
            environment: .production
        )
        let first = SodaPushClient(configuration: configuration, context: .init(platform: "test"), session: makeSession())
        let second = SodaPushClient(configuration: configuration, context: .init(platform: "test"), session: makeSession())

        _ = try await first.updateDeviceToken(Data([0x01]))
        _ = try await second.updateDeviceToken(Data([0x02]))

        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(recorder.requests[0].url?.path, recorder.requests[1].url?.path)
        XCTAssertEqual(recorder.requests[0].url?.host, "example.com")
        XCTAssertNil(recorder.requests[0].url?.port)
    }

    func testRejectsBaseURLWithPath() async {
        let configuration = SodaPushConfiguration(
            serverURL: URL(string: "https://example.com/api")!,
            appID: "app-id",
            registrationKeyID: "key-id",
            registrationSecret: "registration-secret",
            environment: .production
        )
        let client = SodaPushClient(configuration: configuration, session: makeSession())

        do {
            _ = try await client.updateDeviceToken(Data([0x01]))
            XCTFail("Expected invalidServerURL")
        } catch let error as SodaPushError {
            XCTAssertEqual(error, .invalidServerURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectsEmptyDeviceToken() async {
        let client = makeClient(installationID: UUID())
        do {
            _ = try await client.updateDeviceToken(Data())
            XCTFail("Expected invalidDeviceToken")
        } catch let error as SodaPushError {
            XCTAssertEqual(error, .invalidDeviceToken)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testServerErrorPreservesRequestID() async {
        URLProtocolStub.handler = { request in
            Self.response(
                for: request,
                statusCode: 401,
                body: #"{"code":"invalid_signature","message":"Request signature is invalid","requestId":"request-123"}"#
            )
        }
        let client = makeClient(installationID: UUID())

        do {
            _ = try await client.updateDeviceToken(Data([0x01]))
            XCTFail("Expected server error")
        } catch let error as SodaPushError {
            XCTAssertEqual(
                error,
                .server(
                    statusCode: 401,
                    code: "invalid_signature",
                    message: "Request signature is invalid",
                    requestID: "request-123"
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient(installationID: UUID) -> SodaPushClient {
        let configuration = SodaPushConfiguration(
            serverURL: URL(string: "https://example.com")!,
            appID: "app-id",
            registrationKeyID: "key-id",
            registrationSecret: "registration-secret",
            environment: .production
        )
        return SodaPushClient(
            configuration: configuration,
            installationID: installationID,
            context: .init(platform: "test"),
            session: makeSession()
        )
    }

    private func assertValidSignature(
        _ request: URLRequest,
        canonicalTarget: String,
        body: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let timestamp = request.value(forHTTPHeaderField: "X-Soda-Timestamp")
        let nonce = request.value(forHTTPHeaderField: "X-Soda-Nonce")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Soda-Key-ID"), "key-id", file: file, line: line)
        XCTAssertNotNil(timestamp, file: file, line: line)
        XCTAssertNotNil(nonce, file: file, line: line)

        let bodyHash = Data(SHA256.hash(data: body)).base64URLEncodedString
        let signingInput = [request.httpMethod!, canonicalTarget, timestamp!, nonce!, bodyHash].joined(separator: "\n")
        let key = SymmetricKey(data: Data("registration-secret".utf8))
        let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key))
            .base64URLEncodedString
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Soda-Signature"), expected, file: file, line: line)
    }

    nonisolated private static func response(
        for request: URLRequest,
        statusCode: Int,
        body: String = ""
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var storedHandler: Handler?

        var handler: Handler? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedHandler
            }
            set {
                lock.lock()
                storedHandler = newValue
                lock.unlock()
            }
        }
    }

    private static let state = State()

    static var handler: Handler? {
        get { state.handler }
        set { state.handler = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLProtocolStub.self]
    return URLSession(configuration: configuration)
}

private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension URLRequest {
    var bodyData: Data? {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }
        var result = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

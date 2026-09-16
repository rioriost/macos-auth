import AppKit
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MacosAuthAgent

final class AgentTests: XCTestCase {
    private var fixture: URL!
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    override func setUpWithError() throws {
        fixture = root.appendingPathComponent("agent/.test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: fixture)
    }

    private func pair() throws -> (FileHandle, FileHandle) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw AgentError.socket("socketpair") }
        try configureConnectedSocket(fds[0])
        try configureConnectedSocket(fds[1])
        return (FileHandle(fileDescriptor: fds[0], closeOnDealloc: true), FileHandle(fileDescriptor: fds[1], closeOnDealloc: true))
    }

    private func vector() throws -> ProtocolTestVector {
        try JSONDecoder().decode(ProtocolTestVector.self, from: Data(contentsOf: root.appendingPathComponent("test-vectors/v1/approval.json")))
    }

    private func request(expiresAtMs: UInt64 = unixTimeMs() + 5_000) throws -> SignedAuthRequest {
        let base = try vector().request.body
        let body = AuthRequestBody(
            protocolVersion: base.protocolVersion, requestId: UUID().uuidString, nonce: base.nonce,
            createdAtMs: unixTimeMs() - 1, expiresAtMs: expiresAtMs,
            linuxHostId: base.linuxHostId, linuxHostname: base.linuxHostname, pamService: base.pamService,
            pamUser: base.pamUser, pamRuser: base.pamRuser, pamRhost: base.pamRhost, pamTty: base.pamTty,
            sudoCommand: base.sudoCommand, clientPid: base.clientPid, keyId: base.keyId, alg: base.alg
        )
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        return SignedAuthRequest(body: body, signature: Array(try key.signature(for: Data(body.canonicalBytes()))))
    }

    private func runtime(maxRequests: Int = 5) throws -> AgentRuntime {
        let hostKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        return AgentRuntime(
            hostVerifiers: ["host-abc": HostVerifier(hostId: "host-abc", publicKey: hostKey.publicKey)],
            agentPrivateKey: try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32)),
            agentKeyId: "test", allowedFutureSkewMs: 0, requireConfirmation: false,
            rateLimiter: RateLimiter(windowSeconds: 60, maxRequests: maxRequests)
        )
    }

    private func connectTo(_ path: String) throws -> FileHandle {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentError.socket("socket") }
        var address = try UnixSocketListener.address(path: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); throw AgentError.socket("connect") }
        try configureConnectedSocket(fd)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func metadata(_ path: String) throws -> stat {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw AgentError.io("lstat") }
        return st
    }

    func testExistingApprovalVector() throws {
        try MacosAuthAgent.runVerifyVector(VerifyVectorOptions(path: root.appendingPathComponent("test-vectors/v1/approval.json").path))
    }

    func testEveryDecisionAndMethodVector() throws {
        let vector = try vector()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))
        let url = root.appendingPathComponent("test-vectors/v1/response-enums.json")
        if ProcessInfo.processInfo.environment["UPDATE_PROTOCOL_VECTORS"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let lines = try Decision.allCases.flatMap { decision in
                try AuthMethod.allCases.map { method in
                    let body = try AuthResponseBody.forRequest(vector.request.body, decision: decision, authMethod: method, nowMs: vector.response.body.createdAtMs, agentKeyId: vector.response.body.agentKeyId)
                    let response = SignedAuthResponse(body: body, signature: Array(try key.signature(for: Data(body.canonicalBytes()))))
                    return String(decoding: try encoder.encode(response), as: UTF8.self)
                }
            }
            try Data(("[\n" + lines.joined(separator: ",\n") + "\n]\n").utf8).write(to: url)
        }
        let responses = try JSONDecoder().decode([SignedAuthResponse].self, from: Data(contentsOf: url))
        var combinations = Set<String>()
        for response in responses {
            let body = response.body
            let expected = try AuthResponseBody.forRequest(vector.request.body, decision: body.decision, authMethod: body.authMethod, nowMs: vector.response.body.createdAtMs, agentKeyId: vector.response.body.agentKeyId)
            XCTAssertEqual(try body.canonicalBytes(), try expected.canonicalBytes())
            XCTAssertTrue(key.publicKey.isValidSignature(Data(response.signature), for: Data(try body.canonicalBytes())))
            let signedAgain = try key.signature(for: Data(body.canonicalBytes()))
            XCTAssertTrue(key.publicKey.isValidSignature(signedAgain, for: Data(try expected.canonicalBytes())))
            let roundTrip = try JSONDecoder().decode(SignedAuthResponse.self, from: JSONEncoder().encode(response))
            XCTAssertEqual(roundTrip.body.authMethod, body.authMethod)
            combinations.insert("\(body.decision.rawValue)/\(body.authMethod.rawValue)")
        }
        XCTAssertEqual(responses.count, 25)
        XCTAssertEqual(combinations, Set(Decision.allCases.flatMap { decision in AuthMethod.allCases.map { "\(decision.rawValue)/\($0.rawValue)" } }))
        XCTAssertEqual(AuthMethod.touchID.rawValue, "touch-id")
        XCTAssertEqual(AuthMethod.touchID.canonicalName, "touchid")
    }

    func testUnknownEnumsRejected() throws {
        let data = try JSONEncoder().encode(vector().response)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let original = try XCTUnwrap(json["body"] as? [String: Any])
        for (field, value) in [("decision", "approve"), ("auth_method", "touchid"), ("auth_method", "future-method")] {
            var body = original
            body[field] = value
            json["body"] = body
            XCTAssertThrowsError(try JSONDecoder().decode(SignedAuthResponse.self, from: JSONSerialization.data(withJSONObject: json)))
        }
    }

    func testResponseCannotOutliveRequestOrApproveAfterExpiry() throws {
        let body = try request().body
        let response = try AuthResponseBody.forRequest(body, decision: .approved, authMethod: .touchID, nowMs: body.expiresAtMs - 1, agentKeyId: "test")
        XCTAssertEqual(response.expiresAtMs, body.expiresAtMs)
        XCTAssertThrowsError(try AuthResponseBody.forRequest(body, decision: .approved, authMethod: .watch, nowMs: body.expiresAtMs, agentKeyId: "test"))
        XCTAssertThrowsError(try body.verifyFreshness(nowMs: body.expiresAtMs, allowedFutureSkewMs: 0))
        XCTAssertNoThrow(try body.verifyFreshness(nowMs: body.createdAtMs, allowedFutureSkewMs: UInt64.max))
    }

    func testFrameRoundTripAndMalformedFrames() throws {
        let (reader, writer) = try pair()
        defer { try? reader.close(); try? writer.close() }
        try writeJSONFrame(["hello": "world"], to: writer, deadline: Deadline(milliseconds: 1_000))
        let decoded: [String: String] = try readJSONFrame(from: reader, deadline: Deadline(milliseconds: 1_000))
        XCTAssertEqual(decoded, ["hello": "world"])
        for frame in [Data([0, 16, 0, 1]), Data([0, 0, 0, 0]), Data([0, 0, 0, 1, 0xff])] {
            try writer.write(contentsOf: frame)
            XCTAssertThrowsError(try readJSONFrame(from: reader, deadline: Deadline(milliseconds: 100)) as SignedAuthRequest)
        }
    }

    func testTruncatedFrameAndEOF() throws {
        let (reader, writer) = try pair()
        defer { try? reader.close() }
        try writer.write(contentsOf: Data([0, 0, 0, 10, 123]))
        try writer.close()
        XCTAssertThrowsError(try readJSONFrame(from: reader, deadline: Deadline(milliseconds: 100)) as SignedAuthRequest)
    }

    func testIdleAndDribblingReadUseAbsoluteDeadline() throws {
        let (reader, writer) = try pair()
        defer { try? reader.close(); try? writer.close() }
        let done = expectation(description: "dribbler finished")
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.025)
            try? writer.write(contentsOf: Data([0]))
            Thread.sleep(forTimeInterval: 0.025)
            try? writer.write(contentsOf: Data([0]))
            done.fulfill()
        }
        let start = Date()
        XCTAssertThrowsError(try readExactly(4, from: reader, deadline: Deadline(milliseconds: 80)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.4)
        wait(for: [done], timeout: 1)
        XCTAssertThrowsError(try readExactly(1, from: reader, deadline: Deadline(milliseconds: 20)))
    }

    func testFrameHeaderAndBodyShareDeadline() throws {
        let (reader, writer) = try pair()
        defer { try? reader.close(); try? writer.close() }
        let deadline = Deadline(milliseconds: 70)
        Thread.sleep(forTimeInterval: 0.045)
        try writer.write(contentsOf: Data([0, 0, 0, 2, 123]))
        let start = Date()
        XCTAssertThrowsError(try readJSONFrame(from: reader, deadline: deadline) as [String: String])
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    }

    func testWriteToDisconnectedAcceptedSocketDoesNotSignal() throws {
        let path = fixture.appendingPathComponent("socket").path
        let listener = try UnixSocketListener(path: path)
        defer { listener.closeAndUnlink() }
        let client = try connectTo(path)
        let accepted = try listener.acceptFileHandle()
        defer { try? accepted.close() }
        try client.close()
        XCTAssertThrowsError(try writeJSONFrame(["response": "test"], to: accepted, deadline: Deadline(milliseconds: 100)))
    }

    func testBlockedWriteIsBounded() throws {
        let (reader, writer) = try pair()
        defer { try? reader.close(); try? writer.close() }
        var small: Int32 = 1024
        XCTAssertEqual(setsockopt(writer.fileDescriptor, SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout.size(ofValue: small))), 0)
        let start = Date()
        XCTAssertThrowsError(try writeJSONFrame(String(repeating: "x", count: 900_000), to: writer, deadline: Deadline(milliseconds: 60)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testLifetimeClockExpiryAndBackwardWallClock() throws {
        let (reader, writer) = try pair()
        defer { try? reader.close(); try? writer.close() }
        var wall: UInt64 = 1_000
        var monotonic: UInt64 = 0
        let clock = AgentClock(wallTimeMs: { wall }, uptimeNs: { monotonic })
        let lifetime = RequestLifetime(fd: reader.fileDescriptor, expiresAtMs: 1_100, connectionDeadline: Deadline(milliseconds: 1_000, clock: clock))
        XCTAssertTrue(lifetime.isActive)
        wall = 900
        monotonic = 100_000_000
        XCTAssertFalse(lifetime.isActive)
        monotonic = 0
        XCTAssertFalse(lifetime.isActive, "expiry is terminal even if a test clock moves backward")
    }

    func testLifetimeDisconnectAndTrailingData() throws {
        let (reader, writer) = try pair()
        defer { try? reader.close() }
        let lifetime = RequestLifetime(fd: reader.fileDescriptor, expiresAtMs: unixTimeMs() + 1_000, connectionDeadline: Deadline(milliseconds: 1_000))
        XCTAssertTrue(lifetime.isActive)
        try writer.close()
        XCTAssertFalse(lifetime.isActive)
        let (second, peer) = try pair()
        defer { try? second.close(); try? peer.close() }
        try peer.write(contentsOf: Data([1]))
        XCTAssertFalse(RequestLifetime(fd: second.fileDescriptor, expiresAtMs: unixTimeMs() + 1_000, connectionDeadline: Deadline(milliseconds: 1_000)).isActive)
    }

    func testAuthenticationTimeoutInvalidatesAndRejectsLateApproval() throws {
        let (reader, writer) = try pair()
        defer { try? reader.close(); try? writer.close() }
        let mock = MockAuthenticationSession()
        let coordinator = AuthenticationCoordinator(makeSession: { mock })
        let body = try request().body
        let lifetime = RequestLifetime(fd: reader.fileDescriptor, expiresAtMs: body.expiresAtMs, connectionDeadline: Deadline(milliseconds: 45))
        XCTAssertThrowsError(try coordinator.evaluate(request: body, requireConfirmation: true, lifetime: lifetime))
        XCTAssertTrue(mock.cancelled)
        mock.reply?(AuthenticationResult(decision: .approved))
        XCTAssertFalse(lifetime.isActive)
    }

    func testAuthenticationDisconnectCancelsPendingSession() throws {
        let (reader, writer) = try pair()
        defer { try? reader.close(); try? writer.close() }
        let mock = MockAuthenticationSession()
        mock.onStart = { try? writer.close() }
        let coordinator = AuthenticationCoordinator(makeSession: { mock })
        let body = try request().body
        let lifetime = RequestLifetime(fd: reader.fileDescriptor, expiresAtMs: body.expiresAtMs, connectionDeadline: Deadline(milliseconds: 1_000))
        XCTAssertThrowsError(try coordinator.evaluate(request: body, requireConfirmation: true, lifetime: lifetime))
        XCTAssertTrue(mock.cancelled)
    }

    func testConfirmationCancellationTimerFiresInModalModeWithoutUI() throws {
        XCTAssertTrue(Thread.isMainThread)
        for disconnect in [false, true] {
            let (reader, writer) = try pair()
            defer { try? reader.close(); try? writer.close() }
            let lifetime = RequestLifetime(fd: reader.fileDescriptor, expiresAtMs: unixTimeMs() + 1_000, connectionDeadline: Deadline(milliseconds: disconnect ? 1_000 : 35))
            var cancelled = false
            let start = Date()
            let timer = confirmationCancellationTimer(lifetime: lifetime) {
                cancelled = true
                CFRunLoopStop(CFRunLoopGetMain())
            }
            defer { timer.invalidate() }
            if disconnect { try writer.close() }
            let end = Date(timeIntervalSinceNow: 0.5)
            while !cancelled && Date() < end {
                _ = RunLoop.main.run(mode: .modalPanel, before: end)
            }
            XCTAssertTrue(cancelled, "modal-mode timer must cancel on \(disconnect ? "disconnect" : "expiry")")
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
            XCTAssertFalse(lifetime.isActive)
        }
    }

    func testConfirmationCancellationTimerDoesNotDismissLiveRequest() throws {
        let (reader, writer) = try pair()
        defer { try? reader.close(); try? writer.close() }
        let lifetime = RequestLifetime(fd: reader.fileDescriptor, expiresAtMs: unixTimeMs() + 1_000, connectionDeadline: Deadline(milliseconds: 1_000))
        var cancelled = false
        let timer = confirmationCancellationTimer(lifetime: lifetime) { cancelled = true }
        defer { timer.invalidate() }
        _ = RunLoop.main.run(mode: .modalPanel, before: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(cancelled)
        XCTAssertTrue(lifetime.isActive)
    }

    func testQueuedAuthenticationExpiresWithoutStartingAnotherSession() throws {
        let (reader, writer) = try pair()
        let (queuedReader, queuedWriter) = try pair()
        defer { try? reader.close(); try? writer.close(); try? queuedReader.close(); try? queuedWriter.close() }
        let mock = MockAuthenticationSession()
        let started = DispatchSemaphore(value: 0)
        mock.onStart = { started.signal() }
        let coordinator = AuthenticationCoordinator(makeSession: { mock })
        let body = try request().body
        let lifetime = RequestLifetime(fd: reader.fileDescriptor, expiresAtMs: body.expiresAtMs, connectionDeadline: Deadline(milliseconds: 1_000))
        let finished = expectation(description: "first auth cancelled")
        DispatchQueue.global().async {
            do {
                _ = try coordinator.evaluate(request: body, requireConfirmation: false, lifetime: lifetime)
                XCTFail("cancelled request approved")
            } catch {}
            finished.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        let queuedLifetime = RequestLifetime(fd: queuedReader.fileDescriptor, expiresAtMs: body.expiresAtMs, connectionDeadline: Deadline(milliseconds: 30))
        XCTAssertThrowsError(try coordinator.evaluate(request: body, requireConfirmation: false, lifetime: queuedLifetime))
        XCTAssertEqual(mock.starts, 1)
        lifetime.cancel()
        wait(for: [finished], timeout: 1)
    }

    func testBoundedConnectionAdmissionAndRecovery() {
        let pool = ConnectionPool(limit: 2)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "workers finished")
        finished.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            XCTAssertTrue(pool.submit { _ = release.wait(timeout: .now() + 1); finished.fulfill() })
        }
        XCTAssertFalse(pool.submit { XCTFail("excess worker admitted") })
        release.signal()
        release.signal()
        wait(for: [finished], timeout: 2)
        let next = expectation(description: "slot reused")
        // Completion notification can precede the worker's deferred slot release.
        Thread.sleep(forTimeInterval: 0.01)
        XCTAssertTrue(pool.submit { next.fulfill() })
        wait(for: [next], timeout: 1)
    }

    func testInvalidSignatureAndHostNeverStartAuthentication() throws {
        for invalidHost in [false, true] {
            let (reader, writer) = try pair()
            defer { try? reader.close(); try? writer.close() }
            let mock = MockAuthenticationSession()
            let coordinator = AuthenticationCoordinator(makeSession: { mock })
            let signed = try request()
            let invalid = SignedAuthRequest(body: signed.body, signature: invalidHost ? signed.signature : [UInt8](repeating: 0, count: 64))
            let hostKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
            let runtime = AgentRuntime(hostVerifiers: invalidHost ? [:] : [signed.body.linuxHostId: HostVerifier(hostId: signed.body.linuxHostId, publicKey: hostKey.publicKey)], agentPrivateKey: try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32)), agentKeyId: "test", allowedFutureSkewMs: 0, requireConfirmation: false, rateLimiter: RateLimiter(windowSeconds: 60, maxRequests: 5))
            try writeJSONFrame(invalid, to: writer, deadline: Deadline(milliseconds: 1_000))
            XCTAssertThrowsError(try MacosAuthAgent.handleServeRequest(handle: reader, runtime: runtime, deadline: Deadline(milliseconds: 1_000), authenticator: coordinator))
            XCTAssertEqual(mock.starts, 0)
        }
    }

    func testServeSignsMockOutcomesAndPreservesResponseBinding() throws {
        for decision in Decision.allCases {
            let (server, client) = try pair()
            defer { try? server.close(); try? client.close() }
            let mock = MockAuthenticationSession()
            mock.onStart = { [weak mock] in mock?.reply?(AuthenticationResult(decision: decision)) }
            let signed = try request()
            try writeJSONFrame(signed, to: client, deadline: Deadline(milliseconds: 1_000))
            let runtime = try runtime()
            try MacosAuthAgent.handleServeRequest(handle: server, runtime: runtime, deadline: Deadline(milliseconds: 1_000), authenticator: AuthenticationCoordinator(makeSession: { mock }))
            let response: SignedAuthResponse = try readJSONFrame(from: client, deadline: Deadline(milliseconds: 1_000))
            XCTAssertEqual(response.body.decision, decision)
            XCTAssertEqual(response.body.authMethod, decision == .approved ? .biometricOrWatch : .none)
            XCTAssertEqual(response.body.requestHash, try signed.body.sha256())
            XCTAssertLessThanOrEqual(response.body.expiresAtMs, signed.body.expiresAtMs)
            XCTAssertTrue(runtime.agentPrivateKey.publicKey.isValidSignature(Data(response.signature), for: Data(try response.body.canonicalBytes())))
            XCTAssertTrue(mock.cancelled)
        }
    }

    func testServeDoesNotWriteLateApproval() throws {
        let (server, client) = try pair()
        defer { try? server.close(); try? client.close() }
        let mock = MockAuthenticationSession()
        let signed = try request()
        try writeJSONFrame(signed, to: client, deadline: Deadline(milliseconds: 1_000))
        XCTAssertThrowsError(try MacosAuthAgent.handleServeRequest(handle: server, runtime: runtime(), deadline: Deadline(milliseconds: 40), authenticator: AuthenticationCoordinator(makeSession: { mock })))
        mock.reply?(AuthenticationResult(decision: .approved))
        XCTAssertTrue(mock.cancelled)
        XCTAssertThrowsError(try readExactly(1, from: client, deadline: Deadline(milliseconds: 20)))
    }

    func testExpiredAndRateLimitedRequestsNeverStartAuthentication() throws {
        let runtime = try runtime(maxRequests: 1)
        let live = try request()
        XCTAssertTrue(runtime.rateLimiter.allow(live.body))
        let expired = try request(expiresAtMs: unixTimeMs() + 20)
        Thread.sleep(forTimeInterval: 0.03)
        for (signed, shouldRespond) in [(expired, false), (live, true)] {
            let (server, client) = try pair()
            defer { try? server.close(); try? client.close() }
            let mock = MockAuthenticationSession()
            try writeJSONFrame(signed, to: client, deadline: Deadline(milliseconds: 1_000))
            let coordinator = AuthenticationCoordinator(makeSession: { mock })
            if shouldRespond {
                try MacosAuthAgent.handleServeRequest(handle: server, runtime: runtime, deadline: Deadline(milliseconds: 1_000), authenticator: coordinator)
                let response: SignedAuthResponse = try readJSONFrame(from: client, deadline: Deadline(milliseconds: 1_000))
                XCTAssertEqual(response.body.decision, .cancelled)
                XCTAssertEqual(response.body.authMethod, AuthMethod.none)
            } else {
                XCTAssertThrowsError(try MacosAuthAgent.handleServeRequest(handle: server, runtime: runtime, deadline: Deadline(milliseconds: 1_000), authenticator: coordinator))
            }
            XCTAssertEqual(mock.starts, 0)
        }
    }

    func testSocketRefusesRegularFileSymlinkAndLiveListener() throws {
        let path = fixture.appendingPathComponent("socket").path
        try writeNewFile(path: path, contents: "keep me", mode: 0o600)
        XCTAssertThrowsError(try UnixSocketListener(path: path))
        XCTAssertEqual(try String(contentsOfFile: path), "keep me")
        let symlink = fixture.appendingPathComponent("link").path
        XCTAssertEqual(Darwin.symlink(path, symlink), 0)
        XCTAssertThrowsError(try UnixSocketListener(path: symlink))
        XCTAssertEqual(try metadata(symlink).st_mode & S_IFMT, S_IFLNK)
        let socket = fixture.appendingPathComponent("live").path
        let listener = try UnixSocketListener(path: socket)
        defer { listener.closeAndUnlink() }
        let before = try metadata(socket)
        XCTAssertEqual(before.st_mode & 0o777, 0o600)
        XCTAssertThrowsError(try UnixSocketListener(path: socket))
        XCTAssertTrue(sameFile(before, try metadata(socket)))
    }

    func testStaleSocketReplacedAndCleanupPreservesReplacement() throws {
        let path = fixture.appendingPathComponent("socket").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = try UnixSocketListener.address(path: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        XCTAssertEqual(result, 0)
        let listener = try UnixSocketListener(path: path)
        XCTAssertEqual(unlink(path), 0)
        try writeNewFile(path: path, contents: "replacement", mode: 0o600)
        listener.closeAndUnlink()
        listener.closeAndUnlink()
        XCTAssertEqual(try String(contentsOfFile: path), "replacement")
    }

    func testSocketRefusesUntrustedDirectoryAndInvalidPath() throws {
        XCTAssertEqual(chmod(fixture.path, 0o777), 0)
        defer { chmod(fixture.path, 0o700) }
        XCTAssertThrowsError(try UnixSocketListener(path: fixture.appendingPathComponent("socket").path))
        XCTAssertThrowsError(try UnixSocketListener.address(path: String(repeating: "x", count: 200)))
        XCTAssertThrowsError(try UnixSocketListener.address(path: "bad\0path"))
    }

    func testSocketAllowsTrustedSymlinkedParentAndCleansOwnSocket() throws {
        let real = fixture.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let alias = fixture.appendingPathComponent("alias")
        XCTAssertEqual(symlink(real.path, alias.path), 0)
        let path = alias.appendingPathComponent("socket").path
        let listener = try UnixSocketListener(path: path)
        XCTAssertEqual(try metadata(path).st_mode & 0o777, 0o600)
        listener.closeAndUnlink()
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.appendingPathComponent("socket").path))
    }

    private func configData(inlineSecret: Bool = false) throws -> Data {
        var config: [String: Any] = ["socket_path": fixture.appendingPathComponent("socket").path, "hosts": []]
        if inlineSecret { config["agent_key_hex"] = String(repeating: "09", count: 32) }
        return try JSONSerialization.data(withJSONObject: config)
    }

    func testConfigRewritePreservesModesAndInlineSecrets() throws {
        for mode: mode_t in [0o600, 0o640, 0o644, 0o400] {
            let path = fixture.appendingPathComponent("config-\(mode)").path
            try writeNewFile(path: path, contents: String(decoding: configData(), as: UTF8.self), mode: mode)
            XCTAssertEqual(chmod(path, mode), 0)
            let config = try MacosAuthAgent.loadAgentConfig(path: path)
            XCTAssertNil(config.requireConfirmation)
            try MacosAuthAgent.writeAgentConfig(config, path: path)
            XCTAssertEqual(try metadata(path).st_mode & 0o777, mode)
            XCTAssertNoThrow(try MacosAuthAgent.loadAgentConfig(path: path))
        }
        let path = fixture.appendingPathComponent("secret").path
        try writeNewFile(path: path, contents: String(decoding: configData(inlineSecret: true), as: UTF8.self), mode: 0o644)
        XCTAssertEqual(chmod(path, 0o644), 0)
        XCTAssertThrowsError(try MacosAuthAgent.loadAgentConfig(path: path))
        let config = try JSONDecoder().decode(AgentConfig.self, from: configData(inlineSecret: true))
        try MacosAuthAgent.writeAgentConfig(config, path: path)
        XCTAssertEqual(try metadata(path).st_mode & 0o777, 0o600)
        XCTAssertNoThrow(try MacosAuthAgent.loadAgentConfig(path: path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.path).contains { $0.contains("replacement") })
    }

    func testFileSafetyRejectsSymlinksFIFOsPermissionsAndForeignOwner() throws {
        let path = fixture.appendingPathComponent("key").path
        try writeNewFile(path: path, contents: "test", mode: 0o600)
        let link = fixture.appendingPathComponent("link").path
        XCTAssertEqual(symlink(path, link), 0)
        XCTAssertThrowsError(try readSafeFile(path: link, label: "key", privateMaterial: true))
        let fifo = fixture.appendingPathComponent("fifo").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        XCTAssertThrowsError(try readSafeFile(path: fifo, label: "key", privateMaterial: true))
        XCTAssertEqual(chmod(path, 0o666), 0)
        XCTAssertThrowsError(try readSafeFile(path: path, label: "key", privateMaterial: false))
        var st = try metadata(path)
        st.st_mode = S_IFREG | 0o600
        st.st_uid = 1234
        XCTAssertThrowsError(try validateFileMetadata(st, label: "key", privateMaterial: true, effectiveUID: 1235))
        XCTAssertNoThrow(try validateFileMetadata(st, label: "key", privateMaterial: true, effectiveUID: 1234))
        st.st_uid = 0
        XCTAssertNoThrow(try validateFileMetadata(st, label: "key", privateMaterial: true, effectiveUID: 1234))
    }

    func testConfigRewriteRejectsSymlinkAndUnsafeDirectoryWithoutDamage() throws {
        let path = fixture.appendingPathComponent("config").path
        let data = try configData()
        try writeNewFile(path: path, contents: String(decoding: data, as: UTF8.self), mode: 0o600)
        let config = try MacosAuthAgent.loadAgentConfig(path: path)
        let link = fixture.appendingPathComponent("link").path
        XCTAssertEqual(symlink(path, link), 0)
        XCTAssertThrowsError(try MacosAuthAgent.writeAgentConfig(config, path: link))
        XCTAssertEqual(chmod(fixture.path, 0o777), 0)
        defer { chmod(fixture.path, 0o700) }
        XCTAssertThrowsError(try MacosAuthAgent.writeAgentConfig(config, path: path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
    }

    func testFakeAgentIdleAndDisconnectedClientDoNotBlockNextRequest() throws {
        #if DEBUG
        let executable = root.appendingPathComponent("agent/.build/debug/macos-auth-agent")
        #else
        let executable = root.appendingPathComponent("agent/.build/release/macos-auth-agent")
        #endif
        let path = fixture.appendingPathComponent("socket").path
        let process = Process()
        process.executableURL = executable
        process.arguments = ["fake-agent", "--socket", path, "--host-pubkey-hex", try vector().hostPublicKeyHex, "--agent-key-hex", String(repeating: "09", count: 32)]
        let log = Pipe()
        process.standardError = log
        process.standardOutput = log
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let ready = Deadline(milliseconds: 2_000)
        while !FileManager.default.fileExists(atPath: path) && process.isRunning && ready.remainingMilliseconds > 0 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(process.isRunning)
        let idle = try connectTo(path)
        defer { try? idle.close() }
        let disconnected = try connectTo(path)
        try writeJSONFrame(request(), to: disconnected, deadline: Deadline(milliseconds: 1_000))
        try disconnected.close()
        let client = try connectTo(path)
        defer { try? client.close() }
        let signed = try request()
        let start = Date()
        try writeJSONFrame(signed, to: client, deadline: Deadline(milliseconds: 1_000))
        let response: SignedAuthResponse = try readJSONFrame(from: client, deadline: Deadline(milliseconds: 1_000))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(response.body.decision, .approved)
        XCTAssertEqual(response.body.requestHash, try signed.body.sha256())
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(hexDecode(vector().agentPublicKeyHex)))
        XCTAssertTrue(key.isValidSignature(Data(response.signature), for: Data(try response.body.canonicalBytes())))
    }
}

private final class MockAuthenticationSession: AuthenticationSession {
    var reply: ((AuthenticationResult) -> Void)?
    var onStart: (() -> Void)?
    var cancelled = false
    var starts = 0

    func start(request: AuthRequestBody, requireConfirmation: Bool, lifetime: RequestLifetime, completion: @escaping (AuthenticationResult) -> Void) {
        starts += 1
        reply = completion
        onStart?()
    }

    func cancel() { cancelled = true }
}

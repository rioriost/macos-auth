#if !arch(arm64)
#error("macos-auth supports only arm64/aarch64 build targets")
#endif

import AppKit
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

private let supportedProtocolVersion: UInt16 = 1
private let nonceLength = 32
let maxFrameLength = 1024 * 1024
private let requestDomain = Array("macos-auth/auth-request/v1".utf8)
private let responseDomain = Array("macos-auth/auth-response/v1".utf8)

enum AgentError: Error, CustomStringConvertible {
    case usage(String)
    case invalidHex(String)
    case invalidKeyLength(String)
    case invalidPayload(String)
    case invalidSignature
    case socket(String)
    case io(String)
    case timeout

    var description: String {
        switch self {
        case .usage(let message): return message
        case .invalidHex(let message): return "invalid hex: \(message)"
        case .invalidKeyLength(let message): return "invalid key length: \(message)"
        case .invalidPayload(let message): return "invalid payload: \(message)"
        case .invalidSignature: return "signature verification failed"
        case .socket(let message): return "socket error: \(message)"
        case .io(let message): return "io error: \(message)"
        case .timeout: return "request deadline exceeded"
        }
    }
}

struct ProtocolTestVector: Codable {
    let hostPublicKeyHex: String
    let agentPublicKeyHex: String
    let requestHashHex: String
    let request: SignedAuthRequest
    let response: SignedAuthResponse

    enum CodingKeys: String, CodingKey {
        case hostPublicKeyHex = "host_public_key_hex"
        case agentPublicKeyHex = "agent_public_key_hex"
        case requestHashHex = "request_hash_hex"
        case request
        case response
    }
}

struct SignedAuthRequest: Codable {
    let body: AuthRequestBody
    let signature: [UInt8]
}

struct AuthRequestBody: Codable {
    let protocolVersion: UInt16
    let requestId: String
    let nonce: [UInt8]
    let createdAtMs: UInt64
    let expiresAtMs: UInt64
    let linuxHostId: String
    let linuxHostname: String
    let pamService: String
    let pamUser: String
    let pamRuser: String?
    let pamRhost: String?
    let pamTty: String?
    let sudoCommand: String?
    let clientPid: UInt32?
    let keyId: String
    let alg: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case nonce
        case createdAtMs = "created_at_ms"
        case expiresAtMs = "expires_at_ms"
        case linuxHostId = "linux_host_id"
        case linuxHostname = "linux_hostname"
        case pamService = "pam_service"
        case pamUser = "pam_user"
        case pamRuser = "pam_ruser"
        case pamRhost = "pam_rhost"
        case pamTty = "pam_tty"
        case sudoCommand = "sudo_command"
        case clientPid = "client_pid"
        case keyId = "key_id"
        case alg
    }

    func validate() throws {
        guard protocolVersion == supportedProtocolVersion else {
            throw AgentError.invalidPayload("unsupported protocol version \(protocolVersion)")
        }
        guard canonicalAlgorithmName(alg) != nil else {
            throw AgentError.invalidPayload("unsupported algorithm \(alg)")
        }
        guard nonce.count == nonceLength else {
            throw AgentError.invalidPayload("invalid nonce length \(nonce.count)")
        }
        guard createdAtMs < expiresAtMs else {
            throw AgentError.invalidPayload("invalid validity window")
        }
    }

    func canonicalBytes() throws -> [UInt8] {
        try validate()
        var out: [UInt8] = []
        try encodeBytes(&out, requestDomain)
        encodeUInt16(&out, protocolVersion)
        try encodeString(&out, requestId)
        try encodeBytes(&out, nonce)
        encodeUInt64(&out, createdAtMs)
        encodeUInt64(&out, expiresAtMs)
        try encodeString(&out, linuxHostId)
        try encodeString(&out, linuxHostname)
        try encodeString(&out, pamService)
        try encodeString(&out, pamUser)
        try encodeOptionalString(&out, pamRuser)
        try encodeOptionalString(&out, pamRhost)
        try encodeOptionalString(&out, pamTty)
        try encodeOptionalString(&out, sudoCommand)
        encodeOptionalUInt32(&out, clientPid)
        try encodeString(&out, keyId)
        try encodeString(&out, canonicalAlgorithmName(alg)!)
        return out
    }

    func sha256() throws -> [UInt8] {
        Array(SHA256.hash(data: Data(try canonicalBytes())))
    }

    func verifyFreshness(nowMs: UInt64, allowedFutureSkewMs: UInt64) throws {
        if nowMs >= expiresAtMs {
            throw AgentError.invalidPayload("request expired")
        }
        if createdAtMs > nowMs && createdAtMs - nowMs > allowedFutureSkewMs {
            throw AgentError.invalidPayload("request created too far in the future")
        }
    }
}

struct SignedAuthResponse: Codable {
    let body: AuthResponseBody
    let signature: [UInt8]
}

enum Decision: String, Codable, CaseIterable {
    case approved, denied, unavailable, cancelled, failed
}

enum AuthMethod: String, Codable, CaseIterable {
    case watch
    case touchID = "touch-id"
    case biometricOrWatch = "biometric-or-watch"
    case unknown, none

    var canonicalName: String {
        self == .touchID ? "touchid" : rawValue
    }
}

struct AuthResponseBody: Codable {
    let protocolVersion: UInt16
    let requestId: String
    let nonce: [UInt8]
    let requestHash: [UInt8]
    let linuxHostId: String
    let pamService: String
    let pamUser: String
    let decision: Decision
    let authMethod: AuthMethod
    let createdAtMs: UInt64
    let expiresAtMs: UInt64
    let agentKeyId: String
    let alg: String
    let errorCode: String?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case requestId = "request_id"
        case nonce
        case requestHash = "request_hash"
        case linuxHostId = "linux_host_id"
        case pamService = "pam_service"
        case pamUser = "pam_user"
        case decision
        case authMethod = "auth_method"
        case createdAtMs = "created_at_ms"
        case expiresAtMs = "expires_at_ms"
        case agentKeyId = "agent_key_id"
        case alg
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }

    static func forRequest(
        _ request: AuthRequestBody,
        decision: Decision,
        authMethod: AuthMethod,
        nowMs: UInt64,
        agentKeyId: String
    ) throws -> AuthResponseBody {
        guard nowMs < request.expiresAtMs else {
            throw AgentError.timeout
        }
        return AuthResponseBody(
            protocolVersion: request.protocolVersion,
            requestId: request.requestId,
            nonce: request.nonce,
            requestHash: try request.sha256(),
            linuxHostId: request.linuxHostId,
            pamService: request.pamService,
            pamUser: request.pamUser,
            decision: decision,
            authMethod: authMethod,
            createdAtMs: nowMs,
            expiresAtMs: nowMs + min(10_000, request.expiresAtMs - nowMs),
            agentKeyId: agentKeyId,
            alg: "ed25519",
            errorCode: nil,
            errorMessage: nil
        )
    }

    func validate() throws {
        guard protocolVersion == supportedProtocolVersion else {
            throw AgentError.invalidPayload("unsupported protocol version \(protocolVersion)")
        }
        guard canonicalAlgorithmName(alg) != nil else {
            throw AgentError.invalidPayload("unsupported algorithm \(alg)")
        }
        guard nonce.count == nonceLength else {
            throw AgentError.invalidPayload("invalid nonce length \(nonce.count)")
        }
        guard createdAtMs < expiresAtMs else {
            throw AgentError.invalidPayload("invalid validity window")
        }
    }

    func canonicalBytes() throws -> [UInt8] {
        try validate()
        var out: [UInt8] = []
        try encodeBytes(&out, responseDomain)
        encodeUInt16(&out, protocolVersion)
        try encodeString(&out, requestId)
        try encodeBytes(&out, nonce)
        try encodeBytes(&out, requestHash)
        try encodeString(&out, linuxHostId)
        try encodeString(&out, pamService)
        try encodeString(&out, pamUser)
        try encodeString(&out, decision.rawValue)
        try encodeString(&out, authMethod.canonicalName)
        encodeUInt64(&out, createdAtMs)
        encodeUInt64(&out, expiresAtMs)
        try encodeString(&out, agentKeyId)
        try encodeString(&out, canonicalAlgorithmName(alg)!)
        try encodeOptionalString(&out, errorCode)
        try encodeOptionalString(&out, errorMessage)
        return out
    }
}

struct FakeAgentOptions {
    let socketPath: String
    let hostPublicKeyHex: String?
    let hostPublicKeyFile: String?
    let agentKeyHex: String?
    let agentKeyFile: String?
    let agentKeyId: String
    let decision: Decision
    let once: Bool
}

struct ServeOptions {
    let configPath: String
    let once: Bool
}

struct InitKeyOptions {
    let privateKeyFile: String
    let publicKeyFile: String?
}

struct PrintPublicKeyOptions {
    let agentKeyHex: String?
    let agentKeyFile: String?
    let keychainService: String?
    let keychainAccount: String?
}

struct KeychainInitOptions {
    let service: String
    let account: String
    let overwrite: Bool
}

struct KeychainPublicKeyOptions {
    let service: String
    let account: String
}

struct VerifyVectorOptions {
    let path: String
}

struct HostsOptions {
    let command: String
    let configPath: String
    let hostId: String?
    let publicKeyHex: String?
    let publicKeyFile: String?
}

struct AgentConfig: Codable {
    let socketPath: String
    var hosts: [AllowedHost]?
    let hostPublicKeyHex: String?
    let hostPublicKeyFile: String?
    let agentKeyHex: String?
    let agentKeyFile: String?
    let agentKeychainService: String?
    let agentKeychainAccount: String?
    let agentKeyId: String?
    let allowedFutureSkewMs: UInt64?
    let requireConfirmation: Bool?
    let rateLimitWindowSeconds: UInt64?
    let rateLimitMaxRequests: Int?

    enum CodingKeys: String, CodingKey {
        case socketPath = "socket_path"
        case hosts
        case hostPublicKeyHex = "host_public_key_hex"
        case hostPublicKeyFile = "host_public_key_file"
        case agentKeyHex = "agent_key_hex"
        case agentKeyFile = "agent_key_file"
        case agentKeychainService = "agent_keychain_service"
        case agentKeychainAccount = "agent_keychain_account"
        case agentKeyId = "agent_key_id"
        case allowedFutureSkewMs = "allowed_future_skew_ms"
        case requireConfirmation = "require_confirmation"
        case rateLimitWindowSeconds = "rate_limit_window_seconds"
        case rateLimitMaxRequests = "rate_limit_max_requests"
    }
}

struct AllowedHost: Codable {
    let hostId: String
    let publicKeyHex: String?
    let publicKeyFile: String?

    enum CodingKeys: String, CodingKey {
        case hostId = "host_id"
        case publicKeyHex = "public_key_hex"
        case publicKeyFile = "public_key_file"
    }
}

struct HostVerifier {
    let hostId: String
    let publicKey: Curve25519.Signing.PublicKey
}

struct AgentRuntime {
    let hostVerifiers: [String: HostVerifier]
    let agentPrivateKey: Curve25519.Signing.PrivateKey
    let agentKeyId: String
    let allowedFutureSkewMs: UInt64
    let requireConfirmation: Bool
    let rateLimiter: RateLimiter
}

final class RateLimiter {
    private let lock = NSLock()
    private let windowMs: UInt64
    private let maxRequests: Int
    private var eventsByKey: [String: [UInt64]] = [:]

    init(windowSeconds: UInt64, maxRequests: Int) {
        self.windowMs = windowSeconds.saturatingMilliseconds
        self.maxRequests = maxRequests
    }

    func allow(_ request: AuthRequestBody) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if maxRequests <= 0 {
            return true
        }

        let now = unixTimeMs()
        let cutoff = now > windowMs ? now - windowMs : 0
        let key = "\(request.linuxHostId)|\(request.pamService)|\(request.pamUser)"
        var events = eventsByKey[key, default: []].filter { $0 >= cutoff }
        if events.count >= maxRequests {
            eventsByKey[key] = events
            return false
        }
        events.append(now)
        eventsByKey[key] = events
        return true
    }
}

extension UInt64 {
    var saturatingMilliseconds: UInt64 {
        let (value, overflow) = multipliedReportingOverflow(by: 1000)
        return overflow ? UInt64.max : value
    }
}

@main
enum MacosAuthAgent {
    static func main() {
        do {
            try run()
        } catch {
            fputs("macos-auth-agent: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    static func run() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            throw AgentError.usage(usage())
        }
        args.removeFirst()

        switch command {
        case "fake-agent":
            let options = try parseFakeAgentOptions(args)
            try runFakeAgent(options)
        case "serve":
            let options = try parseServeOptions(args)
            try runServe(options)
        case "init-key":
            let options = try parseInitKeyOptions(args)
            try runInitKey(options)
        case "print-public-key":
            let options = try parsePrintPublicKeyOptions(args)
            try runPrintPublicKey(options)
        case "keychain-init":
            let options = try parseKeychainInitOptions(args)
            try runKeychainInit(options)
        case "keychain-public-key":
            let options = try parseKeychainPublicKeyOptions(args)
            try runKeychainPublicKey(options)
        case "verify-vector":
            let options = try parseVerifyVectorOptions(args)
            try runVerifyVector(options)
        case "hosts":
            let options = try parseHostsOptions(args)
            try runHosts(options)
        case "help", "--help", "-h":
            print(usage())
        default:
            throw AgentError.usage("unknown command \(command)\n\n\(usage())")
        }
    }

    static func usage() -> String {
        """
        Usage:
          macos-auth-agent fake-agent --socket PATH (--host-pubkey-hex HEX | --host-pubkey-file PATH) (--agent-key-hex HEX | --agent-key-file PATH) [--agent-key-id ID] [--decision approved|denied|unavailable|cancelled|failed] [--once]
          macos-auth-agent serve --config PATH [--once]
          macos-auth-agent init-key --private-key-file PATH [--public-key-file PATH]
          macos-auth-agent print-public-key (--agent-key-file PATH | --agent-key-hex HEX | --keychain-service SERVICE --keychain-account ACCOUNT)
          macos-auth-agent keychain-init --service SERVICE --account ACCOUNT [--overwrite]
          macos-auth-agent keychain-public-key --service SERVICE --account ACCOUNT
          macos-auth-agent verify-vector --path PATH
          macos-auth-agent hosts list --config PATH
          macos-auth-agent hosts add --config PATH --host-id ID (--public-key-file PATH | --public-key-hex HEX)
          macos-auth-agent hosts remove --config PATH --host-id ID
        """
    }

    static func parseHostsOptions(_ args: [String]) throws -> HostsOptions {
        guard let subcommand = args.first else {
            throw AgentError.usage("missing hosts subcommand")
        }
        var configPath: String?
        var hostId: String?
        var publicKeyHex: String?
        var publicKeyFile: String?
        var index = 1

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--config":
                configPath = try value(after: arg, in: args, index: &index)
            case "--host-id":
                hostId = try value(after: arg, in: args, index: &index)
            case "--public-key-hex":
                publicKeyHex = try value(after: arg, in: args, index: &index)
            case "--public-key-file":
                publicKeyFile = try value(after: arg, in: args, index: &index)
            default:
                throw AgentError.usage("unknown option \(arg)")
            }
            index += 1
        }

        guard let configPath else { throw AgentError.usage("missing --config") }
        switch subcommand {
        case "list":
            break
        case "add":
            guard hostId != nil else { throw AgentError.usage("hosts add requires --host-id") }
            if publicKeyHex == nil && publicKeyFile == nil {
                throw AgentError.usage("hosts add requires --public-key-hex or --public-key-file")
            }
            if publicKeyHex != nil && publicKeyFile != nil {
                throw AgentError.usage("provide only one public key source")
            }
        case "remove":
            guard hostId != nil else { throw AgentError.usage("hosts remove requires --host-id") }
        default:
            throw AgentError.usage("unknown hosts subcommand \(subcommand)")
        }

        return HostsOptions(command: subcommand, configPath: configPath, hostId: hostId, publicKeyHex: publicKeyHex, publicKeyFile: publicKeyFile)
    }

    static func parseFakeAgentOptions(_ args: [String]) throws -> FakeAgentOptions {
        var socketPath: String?
        var hostPublicKeyHex: String?
        var hostPublicKeyFile: String?
        var agentKeyHex: String?
        var agentKeyFile: String?
        var agentKeyId = "agent-key-1"
        var decision = "approved"
        var once = false
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--socket":
                socketPath = try value(after: arg, in: args, index: &index)
            case "--host-pubkey-hex":
                hostPublicKeyHex = try value(after: arg, in: args, index: &index)
            case "--host-pubkey-file":
                hostPublicKeyFile = try value(after: arg, in: args, index: &index)
            case "--agent-key-hex":
                agentKeyHex = try value(after: arg, in: args, index: &index)
            case "--agent-key-file":
                agentKeyFile = try value(after: arg, in: args, index: &index)
            case "--agent-key-id":
                agentKeyId = try value(after: arg, in: args, index: &index)
            case "--decision":
                decision = try value(after: arg, in: args, index: &index)
            case "--once":
                once = true
            default:
                throw AgentError.usage("unknown option \(arg)")
            }
            index += 1
        }

        guard let decision = Decision(rawValue: decision) else {
            throw AgentError.usage("invalid decision \(decision)")
        }
        guard let socketPath else { throw AgentError.usage("missing --socket") }
        if hostPublicKeyHex == nil && hostPublicKeyFile == nil {
            throw AgentError.usage("missing --host-pubkey-hex or --host-pubkey-file")
        }
        if hostPublicKeyHex != nil && hostPublicKeyFile != nil {
            throw AgentError.usage("provide only one of --host-pubkey-hex or --host-pubkey-file")
        }
        if agentKeyHex == nil && agentKeyFile == nil {
            throw AgentError.usage("missing --agent-key-hex or --agent-key-file")
        }
        if agentKeyHex != nil && agentKeyFile != nil {
            throw AgentError.usage("provide only one of --agent-key-hex or --agent-key-file")
        }

        return FakeAgentOptions(
            socketPath: socketPath,
            hostPublicKeyHex: hostPublicKeyHex,
            hostPublicKeyFile: hostPublicKeyFile,
            agentKeyHex: agentKeyHex,
            agentKeyFile: agentKeyFile,
            agentKeyId: agentKeyId,
            decision: decision,
            once: once
        )
    }

    static func parseServeOptions(_ args: [String]) throws -> ServeOptions {
        var configPath: String?
        var once = false
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--config":
                configPath = try value(after: arg, in: args, index: &index)
            case "--once":
                once = true
            default:
                throw AgentError.usage("unknown option \(arg)")
            }
            index += 1
        }

        guard let configPath else { throw AgentError.usage("missing --config") }
        return ServeOptions(configPath: configPath, once: once)
    }

    static func parseInitKeyOptions(_ args: [String]) throws -> InitKeyOptions {
        var privateKeyFile: String?
        var publicKeyFile: String?
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--private-key-file":
                privateKeyFile = try value(after: arg, in: args, index: &index)
            case "--public-key-file":
                publicKeyFile = try value(after: arg, in: args, index: &index)
            default:
                throw AgentError.usage("unknown option \(arg)")
            }
            index += 1
        }

        guard let privateKeyFile else { throw AgentError.usage("missing --private-key-file") }
        return InitKeyOptions(privateKeyFile: privateKeyFile, publicKeyFile: publicKeyFile)
    }

    static func parsePrintPublicKeyOptions(_ args: [String]) throws -> PrintPublicKeyOptions {
        var agentKeyHex: String?
        var agentKeyFile: String?
        var index = 0

        var keychainService: String?
        var keychainAccount: String?

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--agent-key-hex":
                agentKeyHex = try value(after: arg, in: args, index: &index)
            case "--agent-key-file":
                agentKeyFile = try value(after: arg, in: args, index: &index)
            case "--keychain-service":
                keychainService = try value(after: arg, in: args, index: &index)
            case "--keychain-account":
                keychainAccount = try value(after: arg, in: args, index: &index)
            default:
                throw AgentError.usage("unknown option \(arg)")
            }
            index += 1
        }

        let fileOrHexCount = [agentKeyHex, agentKeyFile].filter { $0 != nil }.count
        let hasKeychain = keychainService != nil || keychainAccount != nil
        if fileOrHexCount == 0 && !hasKeychain {
            throw AgentError.usage("missing private key source")
        }
        if fileOrHexCount > 0 && hasKeychain {
            throw AgentError.usage("provide either file/hex key or keychain key, not both")
        }
        if hasKeychain && (keychainService == nil || keychainAccount == nil) {
            throw AgentError.usage("keychain source requires --keychain-service and --keychain-account")
        }
        if fileOrHexCount > 1 {
            throw AgentError.usage("provide only one of --agent-key-file or --agent-key-hex")
        }
        return PrintPublicKeyOptions(agentKeyHex: agentKeyHex, agentKeyFile: agentKeyFile, keychainService: keychainService, keychainAccount: keychainAccount)
    }

    static func parseKeychainInitOptions(_ args: [String]) throws -> KeychainInitOptions {
        var service: String?
        var account: String?
        var overwrite = false
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--service":
                service = try value(after: arg, in: args, index: &index)
            case "--account":
                account = try value(after: arg, in: args, index: &index)
            case "--overwrite":
                overwrite = true
            default:
                throw AgentError.usage("unknown option \(arg)")
            }
            index += 1
        }

        guard let service else { throw AgentError.usage("missing --service") }
        guard let account else { throw AgentError.usage("missing --account") }
        return KeychainInitOptions(service: service, account: account, overwrite: overwrite)
    }

    static func parseVerifyVectorOptions(_ args: [String]) throws -> VerifyVectorOptions {
        var path: String?
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--path":
                path = try value(after: arg, in: args, index: &index)
            default:
                throw AgentError.usage("unknown option \(arg)")
            }
            index += 1
        }

        guard let path else { throw AgentError.usage("missing --path") }
        return VerifyVectorOptions(path: path)
    }

    static func parseKeychainPublicKeyOptions(_ args: [String]) throws -> KeychainPublicKeyOptions {
        var service: String?
        var account: String?
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--service":
                service = try value(after: arg, in: args, index: &index)
            case "--account":
                account = try value(after: arg, in: args, index: &index)
            default:
                throw AgentError.usage("unknown option \(arg)")
            }
            index += 1
        }

        guard let service else { throw AgentError.usage("missing --service") }
        guard let account else { throw AgentError.usage("missing --account") }
        return KeychainPublicKeyOptions(service: service, account: account)
    }

    static func value(after option: String, in args: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < args.count else {
            throw AgentError.usage("missing value for \(option)")
        }
        index = valueIndex
        return args[valueIndex]
    }

    static func runHosts(_ options: HostsOptions) throws {
        var config = try loadAgentConfig(path: options.configPath)
        switch options.command {
        case "list":
            for host in config.hosts ?? [] {
                let source = host.publicKeyFile ?? (host.publicKeyHex != nil ? "<inline>" : "<missing>")
                print("\(host.hostId) \(source)")
            }
        case "add":
            let host = AllowedHost(hostId: options.hostId!, publicKeyHex: options.publicKeyHex, publicKeyFile: options.publicKeyFile)
            var hosts = config.hosts ?? []
            if hosts.contains(where: { $0.hostId == host.hostId }) {
                throw AgentError.invalidPayload("host already exists: \(host.hostId)")
            }
            hosts.append(host)
            config.hosts = hosts
            try writeAgentConfig(config, path: options.configPath)
        case "remove":
            let hostId = options.hostId!
            let oldHosts = config.hosts ?? []
            let newHosts = oldHosts.filter { $0.hostId != hostId }
            guard newHosts.count != oldHosts.count else {
                throw AgentError.invalidPayload("host not found: \(hostId)")
            }
            config.hosts = newHosts
            try writeAgentConfig(config, path: options.configPath)
        default:
            throw AgentError.usage("unknown hosts subcommand \(options.command)")
        }
    }

    static func runInitKey(_ options: InitKeyOptions) throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let privateKeyHex = hexEncode(Array(privateKey.rawRepresentation))
        let publicKeyHex = hexEncode(Array(privateKey.publicKey.rawRepresentation))
        try writeNewFile(path: options.privateKeyFile, contents: "private_key_hex=\(privateKeyHex)\n", mode: 0o600)
        if let publicKeyFile = options.publicKeyFile {
            try writeNewFile(path: publicKeyFile, contents: "public_key_hex=\(publicKeyHex)\n", mode: 0o644)
        }
        print("public_key_hex=\(publicKeyHex)")
    }

    static func runVerifyVector(_ options: VerifyVectorOptions) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: options.path))
        let vector = try JSONDecoder().decode(ProtocolTestVector.self, from: data)
        let hostPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(hexDecode(vector.hostPublicKeyHex)))
        let agentPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(hexDecode(vector.agentPublicKeyHex)))

        let requestBytes = try vector.request.body.canonicalBytes()
        guard hostPublicKey.isValidSignature(Data(vector.request.signature), for: Data(requestBytes)) else {
            throw AgentError.invalidSignature
        }
        let requestHash = try vector.request.body.sha256()
        guard hexEncode(requestHash) == vector.requestHashHex else {
            throw AgentError.invalidPayload("request hash mismatch")
        }
        guard vector.response.body.requestId == vector.request.body.requestId,
              vector.response.body.nonce == vector.request.body.nonce,
              vector.response.body.requestHash == requestHash,
              vector.response.body.linuxHostId == vector.request.body.linuxHostId,
              vector.response.body.pamService == vector.request.body.pamService,
              vector.response.body.pamUser == vector.request.body.pamUser else {
            throw AgentError.invalidPayload("response binding mismatch")
        }
        let responseBytes = try vector.response.body.canonicalBytes()
        guard agentPublicKey.isValidSignature(Data(vector.response.signature), for: Data(responseBytes)) else {
            throw AgentError.invalidSignature
        }
        print("ok")
    }

    static func runPrintPublicKey(_ options: PrintPublicKeyOptions) throws {
        let privateKey: Curve25519.Signing.PrivateKey
        if let service = options.keychainService, let account = options.keychainAccount {
            privateKey = try loadPrivateKeyFromKeychain(service: service, account: account)
        } else {
            let agentKeyHex = try readKeyMaterial(hex: options.agentKeyHex, file: options.agentKeyFile, label: "agent private key", privateMaterial: true)
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(hexDecode(agentKeyHex)))
        }
        print("public_key_hex=\(hexEncode(Array(privateKey.publicKey.rawRepresentation)))")
    }

    static func runKeychainInit(_ options: KeychainInitOptions) throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        try storePrivateKeyInKeychain(
            privateKey,
            service: options.service,
            account: options.account,
            overwrite: options.overwrite
        )
        print("public_key_hex=\(hexEncode(Array(privateKey.publicKey.rawRepresentation)))")
    }

    static func runKeychainPublicKey(_ options: KeychainPublicKeyOptions) throws {
        let privateKey = try loadPrivateKeyFromKeychain(service: options.service, account: options.account)
        print("public_key_hex=\(hexEncode(Array(privateKey.publicKey.rawRepresentation)))")
    }

    static func runServe(_ options: ServeOptions) throws {
        let config = try loadAgentConfig(path: options.configPath)
        let runtime = try runtime(from: config)
        let listener = try UnixSocketListener(path: config.socketPath)
        defer { listener.closeAndUnlink() }

        fputs("macos-auth-agent serving on \(config.socketPath)\n", stderr)
        let authenticator = AuthenticationCoordinator()
        try runSocketServer(listener: listener, once: options.once) { handle, deadline in
            try handleServeRequest(handle: handle, runtime: runtime, deadline: deadline, authenticator: authenticator)
        }
    }

    static func loadAgentConfig(path: String) throws -> AgentConfig {
        let (data, metadata) = try readSafeFile(path: path, label: "agent config", privateMaterial: false)
        let config = try JSONDecoder().decode(AgentConfig.self, from: data)
        if config.agentKeyHex != nil {
            try validateFileMetadata(metadata, label: "agent config with inline private key", privateMaterial: true)
        }
        return config
    }

    static func writeAgentConfig(_ config: AgentConfig, path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try replaceConfigFile(path: path, data: data, privateMaterial: config.agentKeyHex != nil)
    }

    static func runtime(from config: AgentConfig) throws -> AgentRuntime {
        let hostVerifiers = try hostVerifiers(from: config)
        let agentPrivateKey: Curve25519.Signing.PrivateKey
        if let service = config.agentKeychainService, let account = config.agentKeychainAccount {
            if config.agentKeyHex != nil || config.agentKeyFile != nil {
                throw AgentError.usage("provide either agent key file/hex or keychain source, not both")
            }
            agentPrivateKey = try loadPrivateKeyFromKeychain(service: service, account: account)
        } else {
            let agentKeyHex = try readKeyMaterial(hex: config.agentKeyHex, file: config.agentKeyFile, label: "agent private key", privateMaterial: true)
            agentPrivateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(hexDecode(agentKeyHex)))
        }
        return AgentRuntime(
            hostVerifiers: hostVerifiers,
            agentPrivateKey: agentPrivateKey,
            agentKeyId: config.agentKeyId ?? "agent-key-1",
            allowedFutureSkewMs: config.allowedFutureSkewMs ?? 30_000,
            requireConfirmation: config.requireConfirmation ?? false,
            rateLimiter: RateLimiter(
                windowSeconds: config.rateLimitWindowSeconds ?? 60,
                maxRequests: config.rateLimitMaxRequests ?? 5
            )
        )
    }

    static func hostVerifiers(from config: AgentConfig) throws -> [String: HostVerifier] {
        if let hosts = config.hosts, !hosts.isEmpty {
            var verifiers: [String: HostVerifier] = [:]
            for host in hosts {
                let publicKeyHex = try readKeyMaterial(hex: host.publicKeyHex, file: host.publicKeyFile, label: "host public key for \(host.hostId)", privateMaterial: false)
                guard verifiers[host.hostId] == nil else {
                    throw AgentError.invalidPayload("duplicate host_id \(host.hostId)")
                }
                verifiers[host.hostId] = HostVerifier(
                    hostId: host.hostId,
                    publicKey: try Curve25519.Signing.PublicKey(rawRepresentation: Data(hexDecode(publicKeyHex)))
                )
            }
            return verifiers
        }

        let publicKeyHex = try readKeyMaterial(hex: config.hostPublicKeyHex, file: config.hostPublicKeyFile, label: "host public key", privateMaterial: false)
        return [
            "*": HostVerifier(
                hostId: "*",
                publicKey: try Curve25519.Signing.PublicKey(rawRepresentation: Data(hexDecode(publicKeyHex)))
            )
        ]
    }

    static func validateFilePermissions(path: String, label: String, privateMaterial: Bool) throws {
        let fd = try openSafeFile(path: path, label: label, privateMaterial: privateMaterial)
        close(fd)
    }

    static func readKeyMaterial(hex: String?, file: String?, label: String, privateMaterial: Bool) throws -> String {
        if hex != nil, file != nil {
            throw AgentError.usage("provide only one source for \(label)")
        }
        if let hex {
            return hex.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let file else {
            throw AgentError.usage("missing \(label)")
        }
        let (data, _) = try readSafeFile(path: file, label: label, privateMaterial: privateMaterial)
        guard let contents = String(data: data, encoding: .utf8) else {
            throw AgentError.invalidPayload("\(label) is not UTF-8")
        }
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if let equals = line.firstIndex(of: "=") {
                return String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return line
        }
        throw AgentError.invalidPayload("\(label) file is empty")
    }

    static func runFakeAgent(_ options: FakeAgentOptions) throws {
        let hostPublicKeyHex = try readKeyMaterial(hex: options.hostPublicKeyHex, file: options.hostPublicKeyFile, label: "host public key", privateMaterial: false)
        let agentKeyHex = try readKeyMaterial(hex: options.agentKeyHex, file: options.agentKeyFile, label: "agent private key", privateMaterial: true)
        let hostPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(hexDecode(hostPublicKeyHex)))
        let agentPrivateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(hexDecode(agentKeyHex)))
        let listener = try UnixSocketListener(path: options.socketPath)
        defer { listener.closeAndUnlink() }

        fputs("macos-auth-agent fake-agent listening on \(options.socketPath)\n", stderr)
        try runSocketServer(listener: listener, once: options.once) { handle, deadline in
            try handleRequest(handle: handle, hostPublicKey: hostPublicKey, agentPrivateKey: agentPrivateKey, options: options, deadline: deadline)
        }
    }

    static func handleServeRequest(
        handle: FileHandle,
        runtime: AgentRuntime,
        deadline: Deadline,
        authenticator: AuthenticationCoordinator
    ) throws {
        let request: SignedAuthRequest = try readJSONFrame(from: handle, deadline: deadline.capped(milliseconds: 2_000))
        guard let verifier = runtime.hostVerifiers[request.body.linuxHostId] ?? runtime.hostVerifiers["*"] else {
            throw AgentError.invalidPayload("host \(request.body.linuxHostId) is not allowed")
        }
        try verifyRequest(request, hostPublicKey: verifier.publicKey, allowedFutureSkewMs: runtime.allowedFutureSkewMs)
        let lifetime = RequestLifetime(fd: handle.fileDescriptor, expiresAtMs: request.body.expiresAtMs, connectionDeadline: deadline)
        defer { lifetime.cancel() }
        try lifetime.check()
        logRequestContext(request.body)
        let authResult: AuthenticationResult
        if runtime.rateLimiter.allow(request.body) {
            authResult = try authenticator.evaluate(request: request.body, requireConfirmation: runtime.requireConfirmation, lifetime: lifetime)
        } else {
            fputs("macos-auth-agent rate limit exceeded for host_id=\(request.body.linuxHostId) service=\(request.body.pamService) user=\(request.body.pamUser)\n", stderr)
            authResult = AuthenticationResult(decision: .cancelled)
        }
        try lifetime.check()
        let responseBody = try AuthResponseBody.forRequest(
            request.body,
            decision: authResult.decision,
            authMethod: authResult.authMethod,
            nowMs: unixTimeMs(),
            agentKeyId: runtime.agentKeyId
        )
        let signature = try runtime.agentPrivateKey.signature(for: Data(responseBody.canonicalBytes()))
        let response = SignedAuthResponse(body: responseBody, signature: Array(signature))
        try lifetime.check()
        try writeJSONFrame(response, to: handle, deadline: lifetime.deadline)
    }

    static func handleRequest(
        handle: FileHandle,
        hostPublicKey: Curve25519.Signing.PublicKey,
        agentPrivateKey: Curve25519.Signing.PrivateKey,
        options: FakeAgentOptions,
        deadline: Deadline
    ) throws {
        let request = try verifiedRequest(from: handle, hostPublicKey: hostPublicKey, allowedFutureSkewMs: 30_000, deadline: deadline.capped(milliseconds: 2_000))
        let lifetime = RequestLifetime(fd: handle.fileDescriptor, expiresAtMs: request.body.expiresAtMs, connectionDeadline: deadline)
        defer { lifetime.cancel() }
        try lifetime.check()

        let method: AuthMethod = options.decision == .approved ? .biometricOrWatch : .none
        let responseBody = try AuthResponseBody.forRequest(
            request.body,
            decision: options.decision,
            authMethod: method,
            nowMs: unixTimeMs(),
            agentKeyId: options.agentKeyId
        )
        let signature = try agentPrivateKey.signature(for: Data(responseBody.canonicalBytes()))
        let response = SignedAuthResponse(body: responseBody, signature: Array(signature))
        try lifetime.check()
        try writeJSONFrame(response, to: handle, deadline: lifetime.deadline)
    }

    static func verifiedRequest(
        from handle: FileHandle,
        hostPublicKey: Curve25519.Signing.PublicKey,
        allowedFutureSkewMs: UInt64,
        deadline: Deadline
    ) throws -> SignedAuthRequest {
        let request: SignedAuthRequest = try readJSONFrame(from: handle, deadline: deadline)
        try verifyRequest(request, hostPublicKey: hostPublicKey, allowedFutureSkewMs: allowedFutureSkewMs)
        return request
    }

    static func verifyRequest(
        _ request: SignedAuthRequest,
        hostPublicKey: Curve25519.Signing.PublicKey,
        allowedFutureSkewMs: UInt64
    ) throws {
        let requestBytes = try request.body.canonicalBytes()
        guard hostPublicKey.isValidSignature(Data(request.signature), for: Data(requestBytes)) else {
            throw AgentError.invalidSignature
        }
        try request.body.verifyFreshness(nowMs: unixTimeMs(), allowedFutureSkewMs: allowedFutureSkewMs)
    }

    static func localAuthenticationReason(for request: AuthRequestBody) -> String {
        var parts = [
            "Approve \(request.pamService) on \(request.linuxHostname)",
            "User: \(request.pamUser)",
        ]
        if let ruser = request.pamRuser, !ruser.isEmpty {
            parts.append("Requester: \(ruser)")
        }
        if let tty = request.pamTty, !tty.isEmpty {
            parts.append("TTY: \(tty)")
        }
        if let command = request.sudoCommand, !command.isEmpty {
            parts.append("Command: \(truncate(command, maxLength: 120))")
        }
        return parts.joined(separator: "\n")
    }

    static func logRequestContext(_ request: AuthRequestBody) {
        let ruser = request.pamRuser ?? ""
        let tty = request.pamTty ?? ""
        fputs(
            "macos-auth-agent request request_id=\(request.requestId) host_id=\(request.linuxHostId) host=\(request.linuxHostname) service=\(request.pamService) user=\(request.pamUser) ruser=\(ruser) tty=\(tty)\n",
            stderr
        )
    }

    static func showConfirmationAlert(for request: AuthRequestBody, lifetime: RequestLifetime) -> Bool {
        precondition(Thread.isMainThread)
        guard lifetime.isActive else { return false }
        return autoreleasepool {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Approve remote sudo authentication?"
            alert.informativeText = confirmationText(for: request)
            alert.addButton(withTitle: "Approve")
            alert.addButton(withTitle: "Use Linux Password")
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.activate(ignoringOtherApps: true)
            let timer = confirmationCancellationTimer(lifetime: lifetime) {
                NSApplication.shared.abortModal()
            }
            defer { timer.invalidate() }
            let response = alert.runModal()
            alert.window.orderOut(nil)
            alert.window.close()
            return lifetime.isActive && response == .alertFirstButtonReturn
        }
    }

    static func confirmationText(for request: AuthRequestBody) -> String {
        var lines = [
            "Host: \(request.linuxHostname)",
            "Host ID: \(request.linuxHostId)",
            "Service: \(request.pamService)",
            "User: \(request.pamUser)",
        ]
        if let ruser = request.pamRuser, !ruser.isEmpty {
            lines.append("Requester: \(ruser)")
        }
        if let rhost = request.pamRhost, !rhost.isEmpty {
            lines.append("Remote host: \(rhost)")
        }
        if let tty = request.pamTty, !tty.isEmpty {
            lines.append("TTY: \(tty)")
        }
        if let command = request.sudoCommand, !command.isEmpty {
            lines.append("Command: \(truncate(command, maxLength: 300))")
        }
        lines.append("Request ID: \(request.requestId)")
        return lines.joined(separator: "\n")
    }

    static func truncate(_ value: String, maxLength: Int) -> String {
        if value.count <= maxLength {
            return value
        }
        let end = value.index(value.startIndex, offsetBy: maxLength)
        return String(value[..<end]) + "…"
    }

    static func authenticationPolicy() -> LAPolicy {
        if #available(macOS 15.0, *) {
            return .deviceOwnerAuthenticationWithBiometricsOrCompanion
        }
        return .deviceOwnerAuthenticationWithBiometricsOrWatch
    }
}

func storePrivateKeyInKeychain(
    _ privateKey: Curve25519.Signing.PrivateKey,
    service: String,
    account: String,
    overwrite: Bool
) throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    let data = Data(privateKey.rawRepresentation)

    if overwrite {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw AgentError.io("failed to update keychain item: \(secStatusDescription(status))")
        }
    }

    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status != errSecSuccess {
        throw AgentError.io("failed to add keychain item: \(secStatusDescription(status))")
    }
}

func loadPrivateKeyFromKeychain(service: String, account: String) throws -> Curve25519.Signing.PrivateKey {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess else {
        throw AgentError.io("failed to read keychain item: \(secStatusDescription(status))")
    }
    guard let data = item as? Data else {
        throw AgentError.io("keychain item did not contain data")
    }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
}

func secStatusDescription(_ status: OSStatus) -> String {
    if let message = SecCopyErrorMessageString(status, nil) as String? {
        return "\(message) (\(status))"
    }
    return "OSStatus \(status)"
}

func writeNewFile(path: String, contents: String, mode: mode_t) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
    guard fd >= 0 else {
        throw AgentError.io("failed to create \(path): \(String(cString: strerror(errno)))")
    }
    defer { close(fd) }

    try writeAll(Data(contents.utf8), fd: fd)
    guard fsync(fd) == 0 else { throw AgentError.io("failed to sync \(path): \(String(cString: strerror(errno)))") }
}

func hexEncode(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func hexDecode(_ string: String) throws -> [UInt8] {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count % 2 == 0 else {
        throw AgentError.invalidHex("odd length")
    }

    var bytes: [UInt8] = []
    var index = trimmed.startIndex
    while index < trimmed.endIndex {
        let next = trimmed.index(index, offsetBy: 2)
        let pair = trimmed[index..<next]
        guard let byte = UInt8(pair, radix: 16) else {
            throw AgentError.invalidHex(String(pair))
        }
        bytes.append(byte)
        index = next
    }
    return bytes
}


func canonicalAlgorithmName(_ value: String) -> String? {
    switch value.lowercased() {
    case "ed25519": return "Ed25519"
    default: return nil
    }
}

func encodeUInt16(_ out: inout [UInt8], _ value: UInt16) {
    out.append(UInt8((value >> 8) & 0xff))
    out.append(UInt8(value & 0xff))
}

func encodeUInt32(_ out: inout [UInt8], _ value: UInt32) {
    out.append(UInt8((value >> 24) & 0xff))
    out.append(UInt8((value >> 16) & 0xff))
    out.append(UInt8((value >> 8) & 0xff))
    out.append(UInt8(value & 0xff))
}

func encodeUInt64(_ out: inout [UInt8], _ value: UInt64) {
    for shift in stride(from: 56, through: 0, by: -8) {
        out.append(UInt8((value >> UInt64(shift)) & 0xff))
    }
}

func encodeBytes(_ out: inout [UInt8], _ value: [UInt8]) throws {
    guard value.count <= Int(UInt32.max) else {
        throw AgentError.invalidPayload("field too large")
    }
    encodeUInt32(&out, UInt32(value.count))
    out.append(contentsOf: value)
}

func encodeString(_ out: inout [UInt8], _ value: String) throws {
    try encodeBytes(&out, Array(value.utf8))
}

func encodeOptionalString(_ out: inout [UInt8], _ value: String?) throws {
    guard let value else {
        out.append(0)
        return
    }
    out.append(1)
    try encodeString(&out, value)
}

func encodeOptionalUInt32(_ out: inout [UInt8], _ value: UInt32?) {
    guard let value else {
        out.append(0)
        return
    }
    out.append(1)
    encodeUInt32(&out, value)
}

func unixTimeMs() -> UInt64 {
    UInt64(Date().timeIntervalSince1970 * 1000)
}

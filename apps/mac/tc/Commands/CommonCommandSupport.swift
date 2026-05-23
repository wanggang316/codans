import ArgumentParser
import Darwin
import Foundation
import TouchCodeCore
import TouchCodeIPC
import tcKit

struct EmptyParams: Codable, Sendable {}

enum CLISession {
  static func connect(globals: GlobalOptions) -> RPCClient {
    let path = globals.resolvedSocketPath
    let transport: Transport
    do {
      transport = try UnixSocketTransport(path: path)
    } catch {
      CLIError(code: .noSocket, message: "touch-code is not running at \(path)").exitProcess()
    }
    return RPCClient(
      transport: transport,
      versions: RPCClient.Versions(
        clientVersion: TouchCodeCLI.version,
        clientBinary: "tc"
      )
    )
  }
}

struct CLIError: Error, CustomStringConvertible {
  let code: CLIExitCode
  let message: String
  var description: String { message }

  static func from(_ error: Error) -> CLIError {
    if let cli = error as? CLIError { return cli }
    if let args = error as? CLIArgumentError {
      return CLIError(code: .userError, message: args.description)
    }
    if let alias = error as? AliasResolver.Error {
      switch alias {
      case .noContext(let kind):
        return CLIError(
          code: .userError,
          message: "no current \(kind.rawValue) context; pass an explicit id"
        )
      case .rpc(let rpc):
        return from(rpc)
      }
    }
    if let rpc = error as? RPCClient.RPCError {
      return fromRPCError(rpc)
    }
    if let connect = error as? UnixSocketTransport.ConnectError {
      return fromConnectError(connect)
    }
    return CLIError(code: .internal, message: "\(error)")
  }

  private static func fromRPCError(_ rpc: RPCClient.RPCError) -> CLIError {
    switch rpc {
    case .ipc(let ipc):
      return CLIError(code: CLIExitCode.from(ipc), message: ipc.displayMessage)
    case .timeout:
      return CLIError(code: .requestTimeout, message: "request timed out")
    case .noResponse:
      return CLIError(code: .internal, message: "server closed before sending a result")
    case .streamClosed:
      return CLIError(code: .internal, message: "transport stream closed")
    case .decodeFailed(let reason):
      return CLIError(code: .internal, message: "response decode failed: \(reason)")
    case .misorderedResponse(let expected, let got):
      return CLIError(
        code: .internal,
        message: "server sent misordered response (expected id=\(expected), got id=\(got))"
      )
    }
  }

  private static func fromConnectError(_ connect: UnixSocketTransport.ConnectError) -> CLIError {
    switch connect {
    case .connectFailed(let path, _):
      return CLIError(code: .noSocket, message: "touch-code is not running at \(path)")
    case .socketCreateFailed(let errno):
      return CLIError(code: .noSocket, message: "socket create failed (errno=\(errno))")
    case .pathTooLong(let path):
      return CLIError(code: .userError, message: "socket path too long: \(path)")
    }
  }

  func exitProcess() -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    Darwin.exit(code.rawValue)
  }
}

enum StandardInput {
  static func readString() throws -> String {
    guard isatty(STDIN_FILENO) == 0 else {
      throw CLIError(code: .userError, message: "stdin is a terminal; pipe input or pass text arguments")
    }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else {
      throw CLIError(code: .userError, message: "stdin is not valid UTF-8")
    }
    return text
  }
}

enum PathResolver {
  static func absolute(_ path: String?, defaultingToPWD: Bool = true) -> String {
    let pwd = FileManager.default.currentDirectoryPath
    let raw = (path?.isEmpty == false) ? path! : (defaultingToPWD ? pwd : "")
    if raw.hasPrefix("/") { return raw }
    return URL(fileURLWithPath: pwd).appendingPathComponent(raw).path
  }
}

enum CommandRunner {
  static func run(_ body: () async throws -> Void) async {
    do {
      try await body()
    } catch {
      CLIError.from(error).exitProcess()
    }
  }
}

struct JSONValueRenderable: Encodable, CustomStringConvertible {
  let value: JSONValue
  init(_ value: JSONValue) { self.value = value }

  func encode(to encoder: Encoder) throws {
    try value.encode(to: encoder)
  }

  var description: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(value)) ?? Data()
    return String(bytes: data, encoding: .utf8) ?? "(unprintable)"
  }
}

struct IDMessage: Encodable, CustomStringConvertible {
  let id: String
  let message: String

  var description: String { message }
}

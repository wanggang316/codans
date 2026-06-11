import Foundation

/// Top-level namespace for the codans JSON-RPC wire protocol.
///
/// The CLI (`codans`) and the app (`codans`) both import `CodansIPC` and
/// switch on `IPC.Method` — wire strings are defined in exactly one place.
public enum IPC {}

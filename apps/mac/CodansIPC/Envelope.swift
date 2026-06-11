import Foundation

extension IPC {
  /// Request envelope. `params` carries the typed parameters for `method`
  /// as a dynamic `JSONValue`; the router re-decodes the subtree into the
  /// method-specific param type.
  public struct Request: Codable, Equatable, Sendable {
    public let id: String
    public let method: Method
    public let params: JSONValue
    public let stream: Bool

    public init(id: String, method: Method, params: JSONValue = .object([:]), stream: Bool = false) {
      self.id = id
      self.method = method
      self.params = params
      self.stream = stream
    }

    private enum CodingKeys: String, CodingKey { case id, method, params, stream }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.id = try c.decode(String.self, forKey: .id)
      self.method = try c.decode(Method.self, forKey: .method)
      self.params = try c.decodeIfPresent(JSONValue.self, forKey: .params) ?? .object([:])
      self.stream = try c.decodeIfPresent(Bool.self, forKey: .stream) ?? false
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(id, forKey: .id)
      try c.encode(method, forKey: .method)
      try c.encode(params, forKey: .params)
      if stream { try c.encode(stream, forKey: .stream) }
    }
  }

  /// Response envelope. `stream` is `true` for intermediate streaming frames,
  /// `false` for unary results and for the final terminator of a stream.
  /// Exactly one of `result` / `error` is non-nil; both may be nil on the
  /// final frame of a graceful streaming close.
  public struct Response: Codable, Equatable, Sendable {
    public let id: String
    public let stream: Bool
    public let result: JSONValue?
    public let error: IPCError?

    public init(id: String, stream: Bool = false, result: JSONValue? = nil, error: IPCError? = nil) {
      self.id = id
      self.stream = stream
      self.result = result
      self.error = error
    }

    private enum CodingKeys: String, CodingKey { case id, stream, result, error }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.id = try c.decode(String.self, forKey: .id)
      self.stream = try c.decodeIfPresent(Bool.self, forKey: .stream) ?? false
      self.result = try c.decodeIfPresent(JSONValue.self, forKey: .result)
      self.error = try c.decodeIfPresent(IPCError.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(id, forKey: .id)
      if stream { try c.encode(stream, forKey: .stream) }
      try c.encodeIfPresent(result, forKey: .result)
      try c.encodeIfPresent(error, forKey: .error)
    }
  }
}

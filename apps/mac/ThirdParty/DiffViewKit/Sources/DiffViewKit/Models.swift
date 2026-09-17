import Foundation

public struct DiffDocument: Codable, Sendable, Equatable {
    public var id: String
    public var path: String
    public var oldText: String
    public var newText: String
    public var language: String?

    public init(id: String, path: String, oldText: String, newText: String, language: String? = nil) {
        self.id = id
        self.path = path
        self.oldText = oldText
        self.newText = newText
        self.language = language
    }
}

public struct DiffOptions: Codable, Sendable, Equatable {
    public var layout: String
    public var theme: String
    public var chrome: String

    public init(layout: String = "unified", theme: String = "dark", chrome: String = "full") {
        self.layout = layout
        self.theme = theme
        self.chrome = chrome
    }
}

public struct DiffEvent: Codable, Sendable, Equatable {
    public let version: Int
    public let type: String
    public let documentID: String?
    public let path: String?
    public let side: String?
    public let line: Int?
    public let message: String?

    public init(version: Int = 1, type: String, documentID: String? = nil,
                path: String? = nil, side: String? = nil, line: Int? = nil, message: String? = nil) {
        self.version = version
        self.type = type
        self.documentID = documentID
        self.path = path
        self.side = side
        self.line = line
        self.message = message
    }

    /// Checks the untrusted web bridge before events cross into the host application.
    public func isValid(for document: DiffDocument) -> Bool {
        guard version == 1 else { return false }
        switch type {
        case "ready":
            return documentID == nil
        case "rendered":
            return documentID == document.id && (path == nil || path == document.path)
        case "error":
            return (documentID == nil || documentID == document.id) && message != nil
        case "openFile":
            guard documentID == document.id, path == document.path,
                  side == "old" || side == "new" else { return false }
            guard let line else { return true }
            guard line > 0 else { return false }
            let source = side == "old" ? document.oldText : document.newText
            let count = source.isEmpty ? 0 : source.split(separator: "\n", omittingEmptySubsequences: false).count
                - (source.hasSuffix("\n") ? 1 : 0)
            return line <= count
        default:
            return false
        }
    }
}

import Foundation

/// Stable identifier for an editor entry. Stored in `Project.defaultEditor` and in
/// `settings.json`. The value domain is restricted to entries present in
/// `EditorRegistry.registry` (callers normalise unknown IDs to `nil` at load time).
public typealias EditorID = String

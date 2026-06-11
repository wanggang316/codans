# Editor fixture tree — placeholder for 0005 M6 + M8

Reserved for on-disk fixtures consumed by `codans/Tests/EditorTests/` and the future
integration tests in M8.

Expected contents when M6 and M8 land:

- `descriptors-all-installed.json` — canonical `[EditorDescriptor]` snapshot used by
  resolution + settings-UI snapshot tests.
- `descriptors-partial.json` — three built-ins installed, two missing, one custom.
- `settings-json-samples/` — `settings.json` fixtures for `SettingsStore` round-trip tests.
- `custom-editor-samples/` — valid + invalid `CustomEditor` payloads for the
  `validate()` / `validatedID(_:)` boundary tests.

Currently empty — no Swift code reads from this path.

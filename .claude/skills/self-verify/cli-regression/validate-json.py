#!/usr/bin/env python3
"""Validate `codans --json` outputs against the CLI output schema.

Usage: validate-json.py <schema.json> <output.json>...

A dependency-free subset of JSON Schema 2020-12: type, properties, required,
additionalProperties, enum, const, pattern, items, oneOf, allOf, not, if/then,
and local `$ref`s into `$defs`. Exits 1 when any file fails and prints one
line per failure; files that are not JSON objects are skipped.
"""
import json
import re
import sys

TYPES = {
    "object": dict, "array": list, "string": str, "boolean": bool,
    "null": type(None),
}


def type_ok(value, name):
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, TYPES[name])


class Validator:
    def __init__(self, schema):
        self.root = schema

    def resolve(self, ref):
        node = self.root
        for part in ref.lstrip("#/").split("/"):
            node = node[part]
        return node

    def errors(self, value, schema, path="$"):
        out = []
        if "$ref" in schema:
            return self.errors(value, self.resolve(schema["$ref"]), path)
        if "type" in schema:
            names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
            if not any(type_ok(value, n) for n in names):
                out.append(f"{path}: expected {names}, got {type(value).__name__}")
                return out
        if "const" in schema and value != schema["const"]:
            out.append(f"{path}: expected {schema['const']!r}")
        if "enum" in schema and value not in schema["enum"]:
            out.append(f"{path}: {value!r} not in {schema['enum']}")
        if "pattern" in schema and isinstance(value, str) and not re.search(schema["pattern"], value):
            out.append(f"{path}: {value!r} does not match {schema['pattern']}")
        if isinstance(value, dict):
            for key in schema.get("required", []):
                if key not in value:
                    out.append(f"{path}: missing required {key!r}")
            props = schema.get("properties", {})
            for key, sub in props.items():
                if key in value:
                    out.extend(self.errors(value[key], sub, f"{path}.{key}"))
            extra = schema.get("additionalProperties", True)
            for key in value:
                if key in props:
                    continue
                if extra is False:
                    out.append(f"{path}: unexpected property {key!r}")
                elif isinstance(extra, dict):
                    out.extend(self.errors(value[key], extra, f"{path}.{key}"))
        if isinstance(value, list) and "items" in schema:
            for index, item in enumerate(value):
                out.extend(self.errors(item, schema["items"], f"{path}[{index}]"))
        for sub in schema.get("allOf", []):
            out.extend(self.errors(value, sub, path))
        if "oneOf" in schema:
            matches = [sub for sub in schema["oneOf"] if not self.errors(value, sub, path)]
            if len(matches) != 1:
                out.append(f"{path}: expected exactly one oneOf branch, {len(matches)} matched")
        if "not" in schema and not self.errors(value, schema["not"], path):
            out.append(f"{path}: matched a forbidden shape")
        if "if" in schema and not self.errors(value, schema["if"], path):
            out.extend(self.errors(value, schema.get("then", {}), path))
        return out


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    validator = Validator(json.load(open(argv[1])))
    failures = 0
    checked = 0
    for name in argv[2:]:
        try:
            with open(name) as handle:
                text = handle.read()
            value = json.loads(text)
        except (OSError, ValueError):
            continue
        if not isinstance(value, dict) or "schemaVersion" not in value:
            continue
        checked += 1
        for problem in validator.errors(value, validator.root):
            failures += 1
            print(f"{name}: {problem}")
    print(f"validated {checked} envelope(s), {failures} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

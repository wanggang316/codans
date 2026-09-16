#!/usr/bin/env python3
"""Check proposal fixtures and trace supplied results; never execute workflow Actions."""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import re

import yaml


class CaseError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise CaseError(message)


class UniqueLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        require(key not in result, f"Duplicate YAML key: {key}")
        result[key] = loader.construct_object(value_node)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)

# Deliberately bounded fixture contracts, not the application's Action registry.
CONTRACTS = {
    "codans/session.launch@v1": (set(), {"session"}, "launch"),
    "codans/agent.request@v1": ({"instruction", "context"}, {"result", "delivery"}, "agent"),
    "codans/handoff.packet.create@v1": ({"briefing"}, {"packet"}, None),
    "codans/handoff.ack.verify@v1": ({"packet", "acknowledgement"}, {"readiness"}, None),
    "codans/human.decide@v1": ({"question", "options", "evidence"}, {"decision", "reason"}, None),
}


def check_schema(value, schema):
    """Validate only JSON Schema keywords used by these fixtures; reject others."""
    supported = {"type", "required", "properties", "additionalProperties", "items", "minLength"}
    require(set(schema) <= supported, "Unsupported fixture schema keyword")
    kind = schema["type"]
    types = {"string": str, "object": dict, "array": list, "integer": int, "boolean": bool}
    require(kind in types and type(value) is types[kind], f"Expected {kind}")
    if kind == "string":
        require(len(value) >= schema.get("minLength", 0), "String is too short")
    if kind == "object":
        require(set(schema.get("required", [])) <= set(value), "Missing JSON field")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            require(set(value) <= set(properties), "Unexpected JSON field")
        for key in value.keys() & properties.keys():
            check_schema(value[key], properties[key])
    if kind == "array":
        for item in value:
            check_schema(item, schema["items"])


def sources(node):
    for key, value in node.get("with", {}).items():
        if node["uses"] == "codans/agent.request@v1" and key == "context":
            yield from value.values()
        else:
            yield value


def validate_definition(definition):
    require(definition.get("schema") == "codans.workflow/v1", "Unknown DSL version")
    require(set(definition) <= {"schema", "id", "name", "description", "inputs", "roles", "nodes", "outputs"}, "Unexpected definition field")
    nodes = definition["nodes"]
    roles = definition.get("roles", {})
    require(bool(nodes), "No nodes")
    ancestors = {}

    def visit(key, stack=()):
        require(key in nodes, f"Unknown dependency: {key}")
        require(key not in stack, "Dependency cycle")
        if key not in ancestors:
            inherited = set()
            for dependency in nodes[key].get("needs", []):
                inherited.add(dependency)
                inherited.update(visit(dependency, stack + (key,)))
            ancestors[key] = inherited
        return ancestors[key]

    for key in nodes:
        visit(key)
    for role, declaration in roles.items():
        require(set(declaration) <= {"label", "description", "source", "requirements"}, "Runtime data in Role definition")
        require(declaration["source"] in {"current", "pick", "launch"}, "Unknown Role source")
        launches = [key for key, node in nodes.items() if node.get("role") == role and node["uses"] == "codans/session.launch@v1"]
        require(len(launches) == (1 if declaration["source"] == "launch" else 0), "Invalid Role launch count")
        for key, node in nodes.items():
            if launches and node.get("role") == role and node["uses"] == "codans/agent.request@v1":
                require(launches[0] in ancestors[key], "Request before launch")

    def check_source(source, upstream):
        require(isinstance(source, dict) and set(source) in ({"value"}, {"ref"}), "Expected value or ref")
        if "ref" not in source:
            return
        path = source["ref"].split(".")
        if path[0] == "inputs":
            require(len(path) == 2 and path[1] in definition.get("inputs", {}), "Unknown input reference")
        else:
            require(len(path) >= 4 and path[0] == "nodes" and path[2] == "outputs", "Invalid output reference")
            require(path[1] in upstream, "Output reference is not upstream")
            require(path[3] in CONTRACTS[nodes[path[1]]["uses"]][1], "Unknown Action output")

    for key, node in nodes.items():
        require(set(node) <= {"title", "uses", "role", "needs", "with", "expect"}, "Unsupported node field")
        require(node["uses"] in CONTRACTS, "Unknown Action")
        inputs, _, role_kind = CONTRACTS[node["uses"]]
        require(set(node.get("with", {})) == inputs, "Action input contract mismatch")
        if role_kind:
            require(node.get("role") in roles, "Missing or unknown Role")
        else:
            require("role" not in node, "Unexpected Role on native Action")
        if role_kind == "agent":
            require("expect" in node, "Agent request requires delivery contract")
        else:
            require("expect" not in node, "Unexpected delivery contract")
    for key, node in nodes.items():
        for source in sources(node):
            check_source(source, ancestors[key])
    for source in definition["outputs"].values():
        check_source(source, set(nodes))
    return ancestors


def trace_case(definition, scenario):
    ancestors = validate_definition(definition)
    inputs = scenario["request"]["inputs"]
    require(set(inputs) == set(definition.get("inputs", {})), "Run input mismatch")
    for key, declaration in definition.get("inputs", {}).items():
        check_schema(inputs[key], {"type": declaration["type"]})
    roles = definition.get("roles", {})
    bindings = copy.deepcopy(scenario["request"]["roles"])
    require(set(bindings) == set(roles), "Role selection mismatch")
    occupied = set()
    for role, binding in bindings.items():
        require(binding["source"] == roles[role]["source"], "Role source mismatch")
        if binding["source"] == "launch":
            require(bool(binding.get("profileId")) and bool(binding.get("environment", {}).get("cwd")), "Incomplete launch binding")
        else:
            endpoint = binding["endpoint"]
            require(endpoint.get("endpointGeneration", 0) > 0, "Invalid endpoint generation")
            require(endpoint["paneId"] not in occupied, "Duplicate endpoint binding")
            occupied.add(endpoint["paneId"])
    require(set(scenario["actionResults"]) == set(definition["nodes"]), "Missing fixture result; this is not a completed trace")
    results = {}
    trace = []

    def resolve(source):
        if "value" in source:
            return source["value"]
        path = source["ref"].split(".")
        if path[0] == "inputs":
            return inputs[path[1]]
        value = results[path[1]]
        for segment in path[3:]:
            require(isinstance(value, dict) and segment in value, "Unresolved field reference")
            value = value[segment]
        return value

    while len(results) < len(definition["nodes"]):
        for key, node in definition["nodes"].items():
            if key in results or not ancestors[key] <= results.keys():
                continue
            args = {}
            for name, source in node.get("with", {}).items():
                args[name] = {k: resolve(v) for k, v in source.items()} if name == "context" else resolve(source)
            output = copy.deepcopy(scenario["actionResults"][key])
            action = node["uses"]
            require(set(output) == CONTRACTS[action][1], "Action output contract mismatch")
            role = node.get("role")
            if action == "codans/session.launch@v1":
                endpoint = output["session"]
                require(endpoint.get("endpointGeneration", 0) > 0, "Invalid launched endpoint generation")
                require(endpoint["paneId"] not in occupied, "Launch reused an occupied endpoint")
                occupied.add(endpoint["paneId"])
                bindings[role]["endpoint"] = endpoint
            elif action == "codans/agent.request@v1":
                require(bool(output["delivery"].get("id")), "Missing explicit Delivery")
                expect = node["expect"]
                require(expect["format"] in {"json", "markdown", "text"}, "Unsupported delivery format")
                if expect["format"] == "json":
                    check_schema(output["result"], expect["schema"])
                else:
                    require(isinstance(output["result"], str), "Expected text delivery")
                    for section in expect.get("sections", []):
                        require(re.search(r"^#{1,6} " + re.escape(section) + r"\s*$", output["result"], re.M), f"Missing section: {section}")
            elif action == "codans/handoff.packet.create@v1":
                require(output["packet"]["digest"] == hashlib.sha256(args["briefing"].encode()).hexdigest(), "Fixture packet digest mismatch")
            elif action == "codans/handoff.ack.verify@v1":
                packet, ack = args["packet"], args["acknowledgement"]
                require(ack["packetId"] == packet["id"] and ack["packetDigest"] == packet["digest"], "Acknowledgement targets another packet")
                require(output["readiness"] == ("blocked" if ack["blockers"] else "ready"), "Readiness mismatch")
            elif action == "codans/human.decide@v1":
                require(output["decision"] in args["options"] and bool(output["reason"].strip()), "Invalid human decision")
            results[key] = output
            trace.append({"node": key, "uses": action, "role": role, "endpoint": bindings.get(role, {}).get("endpoint"), "resolvedInputs": args, "fixtureResult": output})
    outputs = {key: resolve(source) for key, source in definition["outputs"].items()}
    require(outputs == scenario["expectedOutputs"], "Workflow output mismatch")
    return {"mode": "synthetic-fixture-trace", "workflow": definition["id"], "nodes": trace, "outputs": outputs}


def rejection_checks(definition, scenario):
    mutations = {
        "unknown Action": lambda d, s: d["nodes"]["packet"].update(uses="unknown/action@v1"),
        "cycle": lambda d, s: d["nodes"]["briefing"].update(needs=["verify"]),
        "missing launch dependency": lambda d, s: d["nodes"]["receive"].update(needs=["packet"]),
        "non-upstream reference": lambda d, s: d["nodes"]["briefing"]["with"]["context"].update(packet={"ref": "nodes.packet.outputs.packet"}),
        "wrong Role source": lambda d, s: s["request"]["roles"]["author"].update(source="pick"),
        "wrong packet digest": lambda d, s: s["actionResults"]["receive"]["result"].update(packetDigest="wrong"),
        "missing explicit Delivery": lambda d, s: s["actionResults"]["receive"].update(delivery={}),
        "launch without receipt": lambda d, s: s["actionResults"].pop("receive"),
        "invalid JSON result": lambda d, s: s["actionResults"]["receive"]["result"].pop("understanding"),
    }
    for name, mutate in mutations.items():
        candidate, fixture = copy.deepcopy(definition), copy.deepcopy(scenario)
        mutate(candidate, fixture)
        try:
            trace_case(candidate, fixture)
        except CaseError:
            continue
        raise CaseError(f"Invalid case accepted: {name}")
    candidate = copy.deepcopy(scenario)
    candidate["actionResults"]["receive"]["result"]["blockers"] = ["Source ownership has not been released."]
    candidate["actionResults"]["verify"]["readiness"] = "blocked"
    candidate["expectedOutputs"]["acknowledgement"] = candidate["actionResults"]["receive"]["result"]
    candidate["expectedOutputs"]["readiness"] = "blocked"
    trace_case(definition, candidate)
    return len(mutations)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace-dir", type=Path, help="Write explicitly synthetic traces to this directory")
    args = parser.parse_args()
    base = Path(__file__).resolve().parent
    count = 0
    for bundle in sorted(base.glob("*.codansworkflow")):
        definition = yaml.load((bundle / "workflow.yaml").read_text(), Loader=UniqueLoader)
        scenario = json.loads((bundle / "scenario.json").read_text())
        trace = trace_case(definition, scenario)
        if bundle.stem == "committee":
            by_id = {node["node"]: node for node in trace["nodes"]}
            for suffix in ("a", "b"):
                require(set(by_id[f"analysis_{suffix}"]["resolvedInputs"]["context"]) == {"question"}, "Initial analysis received peer context")
                require(by_id[f"analysis_{suffix}"]["endpoint"] == by_id[f"review_{suffix}"]["endpoint"], "Role did not reuse its Session")
        if bundle.stem == "handoff":
            print(f"PASS {rejection_checks(definition, scenario)} rejection checks and blocked acknowledgement")
        if args.trace_dir:
            args.trace_dir.mkdir(parents=True, exist_ok=True)
            (args.trace_dir / f"{bundle.stem}.json").write_text(json.dumps(trace, indent=2) + "\n")
        count += 1
        print(f"PASS {bundle.stem}: {len(trace['nodes'])} nodes, supplied results only")
    require(count == 5, f"Expected five bundles, found {count}")
    print("No terminals, agents, human decisions, native Actions or application storage were executed.")


if __name__ == "__main__":
    main()

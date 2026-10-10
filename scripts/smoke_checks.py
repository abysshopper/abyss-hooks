"""Validate contributor smoke inheritance and the executed mandatory test set."""
import json


def require(condition, message):
    if not condition:
        raise ValueError(message)


def contract_nodes(compiled):
    nodes = {}
    for path, source in compiled.get("sources", {}).items():
        ast = source.get("ast")
        require(isinstance(ast, dict), f"Independent compiler did not emit AST: {path}")
        for node in ast.get("nodes", []):
            if node.get("nodeType") == "ContractDefinition":
                nodes[node["id"]] = (path, node)
    return nodes


def required_tests(compiled, base_path, base_name="HookSmokeTest"):
    nodes = contract_nodes(compiled)
    bases = [(identifier, node) for identifier, (path, node) in nodes.items()
             if path == base_path and node["name"] == base_name]
    require(len(bases) == 1, "Missing independently compiled shared smoke base")
    base_id, base = bases[0]
    required = []
    for identifier in base.get("linearizedBaseContracts", [base_id]):
        for node in nodes[identifier][1].get("nodes", []):
            if node.get("nodeType") == "FunctionDefinition" and node.get("name", "").startswith("testSmoke"):
                require(node.get("visibility") in ("public", "external") and not node.get("virtual"),
                        "Shared smoke tests must be public and nonvirtual")
                require(not node.get("parameters", {}).get("parameters"), "Shared smoke tests must be deterministic no-argument cases")
                required.append(node["name"] + "()")
    require(bool(required), "Shared smoke base has no required tests")
    return base_id, sorted(required), nodes


def verify_inheritance(compiled, *, base_path, smoke_path, smoke_contract):
    base_id, required, nodes = required_tests(compiled, base_path)
    selected = [node for path, node in nodes.values() if path == smoke_path and node["name"] == smoke_contract]
    require(len(selected) == 1, "Smoke file must contain the conventionally named concrete smoke contract")
    child = selected[0]
    require(child.get("contractKind") == "contract" and not child.get("abstract"), "Smoke test must be concrete")
    require(base_id in child.get("linearizedBaseContracts", []), "Contributor smoke does not inherit the shared invariant suite")
    for identifier in child.get("linearizedBaseContracts", []):
        if identifier in nodes[base_id][1].get("linearizedBaseContracts", [base_id]):
            continue
        for node in nodes[identifier][1].get("nodes", []):
            require(not (node.get("nodeType") == "FunctionDefinition"
                         and node.get("name", "").startswith("testSmoke")),
                    "Contributor cannot replace or overload mandatory smoke tests")
    return required


def discovery_tests(payload, smoke_path, smoke_contract):
    require(isinstance(payload, dict), "Invalid Foundry test discovery")
    contracts = payload.get(smoke_path)
    require(isinstance(contracts, dict) and smoke_contract in contracts, "Required smoke contract was not discovered")
    tests = contracts[smoke_contract]
    require(isinstance(tests, list), "Invalid smoke test discovery list")
    return [name if "(" in name else name + "()" for name in tests]


def parse_foundry_output(text):
    """Forge --json emits one suite map; reject missing/malformed results, not compiler chatter."""
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as error:
        raise ValueError("Foundry did not emit valid JSON test results; inspect the retained log") from error
    require(isinstance(payload, dict), "Foundry JSON test output must be an object")
    return payload


def abi_type(argument):
    kind = argument["type"]
    if kind.startswith("tuple"):
        return "(" + ",".join(abi_type(component) for component in argument["components"]) + ")" + kind[5:]
    return kind


def test_signatures(abi, discovered):
    signatures = []
    functions = [entry for entry in abi if entry.get("type") == "function"
                 and entry.get("name", "").startswith("test")]
    for name in discovered:
        candidates = [entry for entry in functions if entry["name"] == name.split("(", 1)[0]]
        require(len(candidates) == 1, f"Discovered test is absent or overloaded in ABI: {name}")
        entry = candidates[0]
        signatures.append(entry["name"] + "(" + ",".join(abi_type(argument) for argument in entry["inputs"]) + ")")
    return signatures

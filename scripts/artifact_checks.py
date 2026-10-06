"""Reconstruct portable hook artifacts from local compiler source inventories."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from eth_utils import keccak

SOLC_VERSION = "0.8.28+commit.7893614a"
SETTINGS = {
    "optimizer": {"enabled": True, "runs": 1}, "evmVersion": "cancun", "viaIR": False,
    "metadata": {"bytecodeHash": "none", "appendCBOR": False},
}


def require(value, message):
    if not value:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON field: {key}")
        result[key] = value
    return result


def load_json(raw):
    return json.loads(raw, object_pairs_hook=unique_object)


def artifact_metadata(artifact, path):
    metadata = artifact.get("metadata") or artifact.get("rawMetadata")
    if isinstance(metadata, str):
        metadata = load_json(metadata)
    require(isinstance(metadata, dict), f"Artifact lacks compiler metadata: {path}")
    settings = metadata["settings"]
    require(metadata["compiler"]["version"] == SOLC_VERSION and
            all(settings.get(key, False if key == "viaIR" else None) == value for key, value in SETTINGS.items()),
            f"Wrong compiler/profile artifact: {path}")
    sources = metadata.get("sources")
    require(isinstance(sources, dict) and bool(sources), "Artifact has an empty compiler dependency inventory")
    target = settings.get("compilationTarget")
    require(isinstance(target, dict) and len(target) == 1 and next(iter(target)) in sources,
            "Artifact lacks one exact compiler source/contract target")
    require(not settings.get("libraries"), "External linked-library substitutions are not supported")
    return metadata


def artifact_evidence(path):
    raw = path.read_bytes()
    artifact = load_json(raw)
    metadata = artifact_metadata(artifact, path)
    creation = bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x"))
    runtime = bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x"))
    require(0 < len(runtime) <= 24576, "Runtime portability limit")
    require(0 < len(creation) <= 49152, "Creation portability limit")
    require(not artifact["bytecode"].get("linkReferences") and not artifact["deployedBytecode"].get("linkReferences"),
            "Artifact must have fully linked executable bytes")
    references = json.dumps(artifact["deployedBytecode"].get("immutableReferences", {}), sort_keys=True, separators=(",", ":")).encode()
    return {
        "file": str(path), "fileSha256": hashlib.sha256(raw).hexdigest(),
        "creationCodeHash": "0x" + keccak(creation).hex(), "deployedBytecodeHash": "0x" + keccak(runtime).hex(),
        "immutableReferencesDigest": "0x" + keccak(references).hex(),
        "templateRuntimeBytes": len(runtime), "creationBytes": len(creation),
        "claimedCompilerSources": {name: row["keccak256"] for name, row in sorted(metadata["sources"].items())},
        "compilerSourceCorrespondenceVerified": False,
    }


def compiler_executable():
    path = Path.home() / ".svm/0.8.28/solc-0.8.28"
    if not path.is_file():
        installed = shutil.which("solc")
        require(installed is not None, "Install the trusted exact solc 0.8.28 compiler")
        path = Path(installed)
    path = path.resolve()
    require(path.is_file() and os.access(path, os.X_OK), f"Trusted compiler is not executable: {path}")
    result = subprocess.run([str(path), "--version"], text=True, capture_output=True)
    require(result.returncode == 0 and f"Version: {SOLC_VERSION}." in result.stdout,
            f"Trusted compiler must be exact {SOLC_VERSION}: {path}")
    return path


def source_inventory(measured, root):
    root = root.resolve()
    pins = {}
    for name, claimed in measured["claimedCompilerSources"].items():
        relative = Path(name)
        require(not relative.is_absolute() and ".." not in relative.parts, f"Nonlocal compiler source: {name}")
        path = (root / relative).resolve()
        require(path.is_relative_to(root) and path.is_file(), f"Missing local compiler dependency: {name}")
        content = path.read_bytes()
        require("0x" + keccak(content).hex() == claimed.lower(), f"Compiler dependency changed: {name}")
        pins[name] = {"path": str(relative), "sha256": hashlib.sha256(content).hexdigest(), "keccak256": claimed}
    return pins


def immutable_reference_groups(references):
    # AST IDs are incidental; locations and immutable alias groups are not.
    return sorted(sorted((entry["start"], entry["length"]) for entry in entries) for entries in references.values())


def reconstruct_artifact(measured, pins, *, root, solc, output=None):
    path = Path(measured["file"])
    raw = path.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == measured["fileSha256"], "Artifact changed before compiler reconstruction")
    artifact = load_json(raw)
    metadata = artifact_metadata(artifact, path)
    source_name, contract = next(iter(metadata["settings"]["compilationTarget"].items()))
    require(set(pins) == set(measured["claimedCompilerSources"]), "Pinned source inventory differs from artifact")
    sources = {}
    for name, pin in pins.items():
        local = (root / pin["path"]).resolve()
        require(local.is_relative_to(root.resolve()), f"Compiler source escapes local root: {name}")
        content = local.read_bytes()
        require(hashlib.sha256(content).hexdigest() == pin["sha256"], f"Pinned compiler source SHA256 mismatch: {name}")
        require("0x" + keccak(content).hex() == measured["claimedCompilerSources"][name].lower(),
                f"Pinned compiler source Keccak mismatch: {name}")
        sources[name] = {"content": content.decode("utf-8")}
    compiler_input = {"language": "Solidity", "sources": sources, "settings": {
        **SETTINGS, "remappings": metadata["settings"].get("remappings", []),
        "outputSelection": {source_name: {contract: ["evm.bytecode", "evm.deployedBytecode", "metadata"]}},
    }}
    encoded = json.dumps(compiler_input, sort_keys=True, separators=(",", ":"))
    command = [str(solc), "--standard-json", "--no-import-callback"]
    result = subprocess.run(command, input=encoded, cwd=root, text=True, capture_output=True)
    if output is not None:
        output.mkdir()
        (output / "compiler-input.json").write_text(encoded + "\n")
        (output / "compiler-output.json").write_text(result.stdout)
        (output / "compiler.stderr.log").write_text(result.stderr)
    require(result.returncode == 0, "Independent exact compiler reconstruction failed")
    compiled = load_json(result.stdout)
    errors = [row.get("formattedMessage", row["message"]) for row in compiled.get("errors", []) if row["severity"] == "error"]
    require(not errors, "Independent exact compiler reconstruction failed: " + "; ".join(errors))
    rebuilt = compiled["contracts"][source_name][contract]
    inventory = {name: row["keccak256"] for name, row in load_json(rebuilt["metadata"])["sources"].items()}
    require(inventory == measured["claimedCompilerSources"], "Author metadata inventory differs from independent compiler")
    for field in ("bytecode", "deployedBytecode"):
        require(rebuilt["evm"][field]["object"].lower() == artifact[field]["object"].removeprefix("0x").lower(),
                f"Independent compiler bytecode/source mismatch: {field}")
    require(immutable_reference_groups(rebuilt["evm"]["deployedBytecode"].get("immutableReferences", {})) ==
            immutable_reference_groups(artifact["deployedBytecode"].get("immutableReferences", {})),
            "Independent compiler immutable substitution mismatch")
    return {
        "method": "independent exact compiler reconstruction", "artifactFileSha256": measured["fileSha256"],
        "compiler": str(solc), "compilerVersion": SOLC_VERSION, "compilerSha256": hashlib.sha256(solc.read_bytes()).hexdigest(),
        "command": command, "compilerInputSha256": hashlib.sha256(encoded.encode()).hexdigest(),
        "compilerOutputSha256": hashlib.sha256(result.stdout.encode()).hexdigest(), "sourcePins": pins,
        "importCallbackEnabled": False, "creationAndRuntimeExact": True, "immutableReferenceGroupsExact": True,
        "metadataTrusted": False,
    }

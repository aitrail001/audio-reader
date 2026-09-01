#!/usr/bin/env python3
"""Validate contracts/openapi-v1.yaml against AudioReader contract rules."""

from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable, Iterator, Mapping, Sequence

try:
    import yaml
except ImportError as exc:  # pragma: no cover - environment dependency
    raise SystemExit(
        "PyYAML is required. Install with: "
        "python3 -m pip install -r contracts/requirements-validator.txt"
    ) from exc

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONTRACT = REPO_ROOT / "contracts" / "openapi-v1.yaml"

HTTP_METHODS = {"get", "put", "post", "delete", "options", "head", "patch", "trace"}
WRITE_METHODS = {"post", "put", "patch", "delete"}
PROBLEM_STATUSES = {
    "400",
    "401",
    "403",
    "404",
    "409",
    "422",
    "429",
    "500",
    "default",
}
ADMIN_PATH_PREFIX = "/v1/admin/"
ADMIN_SCHEME = "AdminBearer"


class ContractError(Exception):
    """The product OpenAPI contract violates a validation rule."""


def load_openapi(path: Path | None = None) -> dict[str, Any]:
    contract_path = Path(path) if path is not None else DEFAULT_CONTRACT
    if not contract_path.is_file():
        raise ContractError(f"OpenAPI contract not found: {contract_path}")
    try:
        with contract_path.open("r", encoding="utf-8") as handle:
            spec = yaml.safe_load(handle)
    except yaml.YAMLError as exc:
        raise ContractError(f"OpenAPI contract is not valid YAML: {exc}") from exc
    if not isinstance(spec, dict):
        raise ContractError("OpenAPI contract must parse to a mapping")
    version = spec.get("openapi")
    if not isinstance(version, str) or not version.startswith("3.1"):
        raise ContractError(
            f"OpenAPI 3.1 required, found {version!r}"
        )
    if not isinstance(spec.get("paths"), dict):
        raise ContractError("OpenAPI contract is missing a paths mapping")
    return spec


def iter_operations(
    spec: Mapping[str, Any],
) -> Iterator[tuple[str, str, dict[str, Any]]]:
    paths = spec.get("paths") or {}
    if not isinstance(paths, dict):
        return
    for path, item in paths.items():
        if not isinstance(item, dict):
            continue
        for method, operation in item.items():
            if str(method).lower() not in HTTP_METHODS:
                continue
            if not isinstance(operation, dict):
                continue
            yield str(path), str(method).lower(), operation


def decode_pointer_token(token: str) -> str:
    return token.replace("~1", "/").replace("~0", "~")


def resolve_pointer(spec: Any, ref: str) -> Any:
    if not ref.startswith("#/"):
        raise KeyError(ref)
    node: Any = spec
    for token in ref[2:].split("/"):
        key = decode_pointer_token(token)
        if isinstance(node, Mapping) and key in node:
            node = node[key]
            continue
        if isinstance(node, Sequence) and not isinstance(node, (str, bytes)):
            try:
                node = node[int(key)]
                continue
            except (ValueError, IndexError) as exc:
                raise KeyError(ref) from exc
        raise KeyError(ref)
    return node


def resolve_node(spec: Mapping[str, Any], node: Any, seen: set[str] | None = None) -> Any:
    if not isinstance(node, Mapping) or "$ref" not in node:
        return node
    ref = node.get("$ref")
    if not isinstance(ref, str) or not ref.startswith("#/"):
        return node
    if seen is None:
        seen = set()
    if ref in seen:
        return node
    seen.add(ref)
    return resolve_node(spec, resolve_pointer(spec, ref), seen)


def walk(node: Any) -> Iterable[Any]:
    yield node
    if isinstance(node, Mapping):
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)


def assert_operation_ids_unique(spec: Mapping[str, Any]) -> None:
    seen: dict[str, list[str]] = defaultdict(list)
    missing: list[str] = []
    for path, method, operation in iter_operations(spec):
        location = f"{method.upper()} {path}"
        operation_id = operation.get("operationId")
        if not isinstance(operation_id, str) or not operation_id.strip():
            missing.append(location)
            continue
        seen[operation_id].append(location)
    errors: list[str] = []
    if missing:
        errors.append(
            "operations missing operationId: " + ", ".join(sorted(missing))
        )
    duplicates = {
        operation_id: locations
        for operation_id, locations in seen.items()
        if len(locations) > 1
    }
    if duplicates:
        details = "; ".join(
            f"{operation_id} -> {', '.join(locations)}"
            for operation_id, locations in sorted(duplicates.items())
        )
        errors.append("duplicate operationId values: " + details)
    if errors:
        raise ContractError("; ".join(errors))


def assert_local_refs_resolve(spec: Mapping[str, Any]) -> None:
    missing: list[str] = []
    for node in walk(spec):
        if not isinstance(node, Mapping):
            continue
        ref = node.get("$ref")
        if not isinstance(ref, str):
            continue
        if not ref.startswith("#"):
            continue
        if not ref.startswith("#/"):
            missing.append(ref)
            continue
        try:
            resolve_pointer(spec, ref)
        except KeyError:
            missing.append(ref)
    if missing:
        unique = ", ".join(sorted(set(missing)))
        raise ContractError(f"unresolved local $ref values: {unique}")


def _schema_is_problem(spec: Mapping[str, Any], schema: Any) -> bool:
    if not isinstance(schema, Mapping):
        return False
    ref = schema.get("$ref")
    if isinstance(ref, str) and ref.rstrip("/").endswith("/Problem"):
        return True
    try:
        resolved = resolve_node(spec, schema)
    except KeyError:
        return False
    problem = ((spec.get("components") or {}).get("schemas") or {}).get("Problem")
    return problem is not None and resolved is problem


def _response_is_problem(spec: Mapping[str, Any], response: Any) -> bool:
    try:
        resolved = resolve_node(spec, response)
    except KeyError:
        return False
    if not isinstance(resolved, Mapping):
        return False
    content = resolved.get("content") or {}
    if not isinstance(content, Mapping):
        return False
    body = content.get("application/problem+json")
    if not isinstance(body, Mapping):
        return False
    return _schema_is_problem(spec, body.get("schema"))


def assert_writes_declare_problem_response(spec: Mapping[str, Any]) -> None:
    missing: list[str] = []
    for path, method, operation in iter_operations(spec):
        if method not in WRITE_METHODS:
            continue
        responses = operation.get("responses")
        if not isinstance(responses, Mapping):
            missing.append(f"{method.upper()} {path}")
            continue
        declared = False
        for status, response in responses.items():
            if str(status) not in PROBLEM_STATUSES and not (
                str(status).isdigit() and int(str(status)) >= 400
            ):
                continue
            if _response_is_problem(spec, response):
                declared = True
                break
        if not declared:
            missing.append(f"{method.upper()} {path}")
    if missing:
        raise ContractError(
            "write operations missing ProblemDetails responses: "
            + ", ".join(sorted(missing))
        )


def _effective_security(
    spec: Mapping[str, Any], operation: Mapping[str, Any]
) -> Any:
    if "security" in operation:
        return operation.get("security")
    return spec.get("security")


def _has_admin_scheme(security: Any) -> bool:
    if not isinstance(security, list) or not security:
        return False
    for requirement in security:
        if isinstance(requirement, Mapping) and ADMIN_SCHEME in requirement:
            return True
    return False


def assert_admin_routes_require_admin_security(spec: Mapping[str, Any]) -> None:
    schemes = ((spec.get("components") or {}).get("securitySchemes") or {})
    if not isinstance(schemes, Mapping) or ADMIN_SCHEME not in schemes:
        raise ContractError(
            f"components.securitySchemes must declare {ADMIN_SCHEME}"
        )
    missing: list[str] = []
    found = False
    for path, method, operation in iter_operations(spec):
        if not path.startswith(ADMIN_PATH_PREFIX):
            continue
        found = True
        if not _has_admin_scheme(_effective_security(spec, operation)):
            missing.append(f"{method.upper()} {path}")
    if not found:
        raise ContractError("no /v1/admin/ routes found")
    if missing:
        raise ContractError(
            "admin operations missing AdminBearer security: "
            + ", ".join(sorted(missing))
        )


def validate(path: Path | None = None) -> dict[str, Any]:
    spec = load_openapi(path)
    assert_operation_ids_unique(spec)
    assert_local_refs_resolve(spec)
    assert_writes_declare_problem_response(spec)
    assert_admin_routes_require_admin_security(spec)
    return spec


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate the AudioReader OpenAPI v1 product contract."
    )
    parser.add_argument(
        "contract",
        nargs="?",
        type=Path,
        default=DEFAULT_CONTRACT,
        help=f"path to OpenAPI document (default: {DEFAULT_CONTRACT})",
    )
    args = parser.parse_args(argv)
    try:
        spec = validate(args.contract)
    except ContractError as exc:
        print(f"OpenAPI contract validation failed: {exc}", file=sys.stderr)
        return 1
    operation_count = sum(1 for _ in iter_operations(spec))
    print(
        f"OpenAPI contract OK: {args.contract} "
        f"(openapi {spec.get('openapi')}, {operation_count} operations)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

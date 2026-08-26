"""Contract tests for the product OpenAPI v1 document.

These tests must fail until contracts/openapi-v1.yaml exists and
scripts/validate_openapi.py implements the Phase 0.2 checks.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))


class OpenAPIV1ContractTests(unittest.TestCase):
    def test_openapi_parses(self) -> None:
        import validate_openapi as v

        spec = v.load_openapi()
        self.assertIsInstance(spec, dict)
        self.assertTrue(str(spec.get("openapi", "")).startswith("3.1"))
        self.assertIn("paths", spec)

    def test_operation_ids_are_unique(self) -> None:
        import validate_openapi as v

        v.assert_operation_ids_unique(v.load_openapi())

    def test_all_local_refs_resolve(self) -> None:
        import validate_openapi as v

        v.assert_local_refs_resolve(v.load_openapi())

    def test_every_write_declares_problem_response(self) -> None:
        import validate_openapi as v

        v.assert_writes_declare_problem_response(v.load_openapi())

    def test_admin_routes_require_admin_security(self) -> None:
        import validate_openapi as v

        v.assert_admin_routes_require_admin_security(v.load_openapi())


if __name__ == "__main__":
    unittest.main()

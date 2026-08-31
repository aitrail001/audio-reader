"""Lock the product OpenAPI v1 rules that CI lint enforces."""

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

    def test_assistant_cache_routes_declare_lookup_only(self) -> None:
        import validate_openapi as v

        spec = v.load_openapi()
        paths = spec["paths"]
        self.assertIn("/v1/ai/translations", paths)
        self.assertIn("/v1/ai/translation-batches", paths)
        self.assertIn("/v1/ai/chapter-summaries", paths)
        schemas = spec["components"]["schemas"]
        self.assertIn("lookupOnly", schemas["TranslationRequest"]["properties"])
        self.assertIn("refresh", schemas["TranslationRequest"]["properties"])
        self.assertIn("lookupOnly", schemas["TranslationBatchRequest"]["properties"])
        self.assertIn("refreshIds", schemas["TranslationBatchRequest"]["properties"])
        self.assertIn("lookupOnly", schemas["ChapterSummaryRequest"]["properties"])
        self.assertEqual(schemas["TranslationBatchRequest"]["properties"]["sentences"]["maxItems"], 40)
        self.assertIn("missingIds", schemas["TranslationBatchResult"]["required"])

    def test_v2_asset_streaming_operations_are_explicit_and_bounded(self) -> None:
        import validate_openapi as v

        spec = v.load_openapi()
        self.assertEqual(spec["security"], [{"bearerAuth": []}])
        paths = spec["paths"]
        upload = paths["/v2/assets/uploads/{uploadId}/body"]["put"]
        self.assertNotEqual(upload.get("security"), [])
        self.assertEqual(upload["operationId"], "putV2AssetUploadBody")
        length = next(item for item in upload["parameters"] if item["name"] == "Content-Length")
        self.assertTrue(length["required"])
        self.assertEqual(length["schema"]["maximum"], 8 * 1024 * 1024)
        binary = upload["requestBody"]["content"]["application/octet-stream"]["schema"]
        self.assertEqual(binary["format"], "binary")
        self.assertTrue({"200", "400", "401", "403", "404", "409", "411", "422", "500"}
                        .issubset(upload["responses"]))

        manifest = paths["/v2/assets/{assetId}"]["get"]
        self.assertEqual(manifest["operationId"], "getV2Asset")
        content = paths["/v2/assets/{assetId}/content"]
        self.assertNotEqual(content["get"].get("security"), [])
        self.assertNotEqual(content["head"].get("security"), [])
        self.assertEqual(content["get"]["operationId"], "getV2AssetContent")
        self.assertEqual(content["head"]["operationId"], "headV2AssetContent")
        self.assertEqual(
            content["get"]["responses"]["200"]["content"]["application/octet-stream"]["schema"]["format"],
            "binary",
        )


if __name__ == "__main__":
    unittest.main()

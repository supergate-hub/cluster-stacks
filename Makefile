.PHONY: validate test-catalog check build-catalog publish-catalog-validate

CATALOG_OUTPUT ?= .artifacts/application-catalog
CATALOG_RELEASE_REVISION ?= test.1
CATALOG_CHART_REPOSITORY ?= oci://127.0.0.1:5000/launcher/charts
CATALOG_SIGNING_KEY ?=
CATALOG_SIGNING_KEY_ID ?=
CATALOG_REF ?= oci://127.0.0.1:5000/launcher/catalog:test.1

validate:
	./validate-applications.sh

test-catalog:
	python3 ./test_catalog_release.py

check: validate test-catalog

build-catalog:
	@test -n "$(CATALOG_SIGNING_KEY)" || { echo "CATALOG_SIGNING_KEY is required" >&2; exit 1; }
	@test -n "$(CATALOG_SIGNING_KEY_ID)" || { echo "CATALOG_SIGNING_KEY_ID is required" >&2; exit 1; }
	python3 ./build_catalog_test_release.py \
		--output "$(CATALOG_OUTPUT)" \
		--release-revision "$(CATALOG_RELEASE_REVISION)" \
		--chart-repository "$(CATALOG_CHART_REPOSITORY)" \
		--signing-key "$(CATALOG_SIGNING_KEY)" \
		--signing-key-id "$(CATALOG_SIGNING_KEY_ID)"

publish-catalog-validate:
	./publish_catalog_release.sh --release-dir "$(CATALOG_OUTPUT)" --catalog-ref "$(CATALOG_REF)" --validate-only

#!/usr/bin/env python3
"""Regression tests for the deterministic local catalog test release."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
BUILDER = ROOT / "build_catalog_test_release.py"
PUBLISHER = ROOT / "publish_catalog_release.sh"
OPENSSL = os.environ.get("OPENSSL") or (
    "/opt/homebrew/opt/openssl@3/bin/openssl"
    if Path("/opt/homebrew/opt/openssl@3/bin/openssl").is_file()
    else "openssl"
)
FORBIDDEN_FORM_TERMS = (
    "password",
    "secret",
    "token",
    "credential",
    "kubeconfig",
    "yaml_input",
    "cluster_select",
    "targetCluster",
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(output: Path, signing_key: Path) -> None:
    subprocess.run(
        [
            sys.executable,
            str(BUILDER),
            "--output",
            str(output),
            "--producer-revision",
            "1d8311a-test",
            "--release-revision",
            "test.1",
            "--signing-key",
            str(signing_key),
            "--signing-key-id",
            "test-ed25519",
        ],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )


def files_with_digests(root: Path) -> dict[str, str]:
    return {
        path.relative_to(root).as_posix(): sha256(path)
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def form_field_names(spec: dict[str, object]) -> list[str]:
    names: list[str] = []
    properties = spec.get("properties", {})
    if not isinstance(properties, dict):
        return names
    for name, child in properties.items():
        names.append(name)
        if isinstance(child, dict):
            names.extend(form_field_names(child))
    return names


def main() -> int:
    if not BUILDER.is_file():
        print(f"missing release builder: {BUILDER.name}", file=sys.stderr)
        return 1

    publisher = PUBLISHER.read_text()
    assert '${chart_ref%:*}@$chart_manifest_digest' in publisher, (
        "chart signatures must target the resolved digest without a tag"
    )
    assert '${normalized_catalog_ref%:*}@$catalog_manifest_digest' in publisher, (
        "catalog signatures must target the resolved digest without a tag"
    )
    assert '${chart_ref%@*}' not in publisher and '${normalized_catalog_ref%@*}' not in publisher

    with tempfile.TemporaryDirectory() as first_temp, tempfile.TemporaryDirectory() as second_temp:
        first = Path(first_temp) / "release"
        second = Path(second_temp) / "release"
        signing_key = Path(first_temp) / "catalog.key"
        public_key = Path(first_temp) / "catalog.pub"
        subprocess.run(
            [OPENSSL, "genpkey", "-algorithm", "ED25519", "-out", str(signing_key)],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [OPENSSL, "pkey", "-in", str(signing_key), "-pubout", "-out", str(public_key)],
            check=True,
            capture_output=True,
        )
        build(first, signing_key)
        build(second, signing_key)

        validation = subprocess.run(
            [
                str(PUBLISHER),
                "--release-dir",
                str(first),
                "--catalog-ref",
                "oci://harbor.example/launcher/catalog:test.1",
                "--validate-only",
            ],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        assert "signed and internally consistent" in validation.stdout

        assert files_with_digests(first) == files_with_digests(second), (
            "catalog test releases must be byte-for-byte deterministic"
        )

        catalog = json.loads((first / "catalog.json").read_text())
        release = json.loads((first / "release.json").read_text())
        applications = catalog["applications"]

        assert catalog["schemaVersion"] == 1
        assert (
            release["artifact"]["mediaType"]
            == "application/vnd.supergate.application-catalog.v1+tar+gzip"
        )
        assert catalog["catalogDigest"].startswith("sha256:")
        assert catalog["signature"]["algorithm"] == "Ed25519"
        signature_path = Path(first_temp) / "catalog.sig"
        digest_path = Path(first_temp) / "catalog.digest"
        signature_path.write_bytes(base64.b64decode(catalog["signature"]["value"]))
        digest_path.write_text(catalog["catalogDigest"])
        subprocess.run(
            [
                OPENSSL, "pkeyutl", "-verify", "-rawin", "-pubin",
                "-inkey", str(public_key), "-sigfile", str(signature_path),
                "-in", str(digest_path),
            ],
            check=True,
            capture_output=True,
        )
        assert [application["slug"] for application in applications] == [
            "headlamp",
            "argo-cd",
            "mlflow",
        ]
        argo_cd = next(
            application
            for application in applications
            if application["slug"] == "argo-cd"
        )
        assert argo_cd["formSpec"]["properties"] == {}, (
            "Argo CD has no application-specific install fields"
        )
        argo_cd_install_copy = json.dumps(
            {
                "formSpec": argo_cd["formSpec"],
                "tutorial": argo_cd["tutorial"],
            }
        ).lower()
        assert "notifications" not in argo_cd_install_copy
        assert "controllers" not in argo_cd_install_copy

        for application in applications:
            icon = application["icon"]
            assert icon["mediaType"] == "image/svg+xml"
            assert icon["path"].startswith("assets/")
            assert not icon["path"].startswith(("http://", "https://"))
            icon_path = first / icon["path"]
            assert icon_path.is_file()
            assert icon["digest"] == f"sha256:{sha256(icon_path)}"
            assert application["links"]
            assert application["licenses"]

            serialized_form = json.dumps(form_field_names(application["formSpec"]))
            for forbidden in FORBIDDEN_FORM_TERMS:
                assert forbidden.lower() not in serialized_form.lower(), (
                    f"{application['slug']} test form contains forbidden term {forbidden}"
                )
            chart = application["chart"]
            chart_path = first / chart["archive"]
            assert chart_path.is_file()
            assert chart["digest"] == f"sha256:{sha256(chart_path)}"
            with tarfile.open(chart_path, "r:gz") as chart_bundle:
                assert f"{chart['name']}/Chart.yaml" in chart_bundle.getnames()
            assert application["deployment"]["engine"] == "sveltos"
            assert application["deployment"]["sveltos"] == {
                "apiVersion": "config.projectsveltos.io/v1beta1",
                "syncMode": "Continuous",
                "driftDetection": False,
                "healthChecks": False,
            }
            assert all("version" not in license for license in application["licenses"])

        archive = first / release["artifact"]["path"]
        assert release["artifact"]["digest"] == f"sha256:{sha256(archive)}"
        with tarfile.open(archive, "r:gz") as bundle:
            names = sorted(bundle.getnames())
        assert names[0] == "assets"
        assert "catalog.json" in names
        assert len([name for name in names if name.endswith(".svg")]) == 3

    print("catalog test release validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

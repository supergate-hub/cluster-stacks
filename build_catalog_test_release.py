#!/usr/bin/env python3
"""Compile deterministic Launcher application catalog and Helm artifacts.

The output is the exact producer contract consumed by Launcher tests and by the
OCI publication script. Signing is optional only for local tests; production
publication rejects unsigned output.
"""

from __future__ import annotations

import argparse
import base64
import copy
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
APPLICATIONS = ("headlamp", "argo-cd", "mlflow")
ARCHIVE_NAME = "application-catalog-test-v1.tar.gz"
SAFE_FORM_FIELDS = {
    "headlamp": {"configuration": ("clusterRoleName",)},
    "argo-cd": {},
    "mlflow": {
        "authentication": ("adminUsername",),
        "storage": (
            "storageClassName",
            "databaseStorageSize",
            "artifactStorageSize",
        ),
    },
}
OVERVIEW_TITLES = {
    "headlamp": "A focused Kubernetes interface for daily operations",
    "argo-cd": "Declarative GitOps continuous delivery with Argo CD",
    "mlflow": "Track experiments and manage models with MLflow",
}
TEST_TUTORIALS = {
    "headlamp": [
        "Select an existing Kubernetes cluster.",
        "Review the installation name and namespace.",
        "Choose read-only or full cluster administration access.",
        "Review the configuration before deployment.",
    ],
    "argo-cd": [
        "Select an existing Kubernetes cluster.",
        "Review the installation name and namespace.",
        "Review the configuration before deployment.",
    ],
    "mlflow": [
        "Select a Kubernetes cluster with a default StorageClass.",
        "Review the installation name and namespace.",
        "Choose the administrator username and persistent volume sizes.",
        "Review the configuration before deployment.",
    ],
}
FORBIDDEN_FORM_TERMS = re.compile(
    r"password|secret|token|credential|kubeconfig|yaml_input|cluster_select|targetCluster",
    re.IGNORECASE,
)
SUPPORTED_WIDGETS = {"base", "select", "switch"}


def canonical_json(value: object) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode()


def pretty_json(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def digest_file(path: Path) -> str:
    return digest_bytes(path.read_bytes())


def openssl_command() -> str:
    configured = os.environ.get("OPENSSL", "").strip()
    if configured:
        return configured
    homebrew = Path("/opt/homebrew/opt/openssl@3/bin/openssl")
    if homebrew.is_file():
        return str(homebrew)
    return "openssl"


def deterministic_chart_archive(chart_dir: Path, output: Path) -> Path:
    chart = read_yaml(chart_dir / "Chart.yaml")
    chart_name = chart["name"]
    chart_version = chart["version"]
    destination = output / "charts" / f"{chart_name}-{chart_version}.tgz"
    destination.parent.mkdir(parents=True, exist_ok=True)

    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.USTAR_FORMAT) as bundle:
        add_tar_directory(bundle, chart_name)
        for source in sorted(chart_dir.rglob("*")):
            if source.name == ".DS_Store":
                continue
            if source.is_symlink():
                raise ValueError(f"chart symlinks are not allowed: {source}")
            relative = source.relative_to(chart_dir).as_posix()
            archive_path = f"{chart_name}/{relative}"
            if source.is_dir():
                add_tar_directory(bundle, archive_path)
            elif source.is_file():
                add_tar_file(bundle, archive_path, source.read_bytes())

    with destination.open("wb") as target:
        with gzip.GzipFile(filename="", fileobj=target, mode="wb", compresslevel=9, mtime=0) as compressed:
            compressed.write(tar_buffer.getvalue())
    return destination


def read_yaml(path: Path) -> dict[str, Any]:
    result = subprocess.run(
        ["yq", "eval", "-o=json", ".", str(path)],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    value = json.loads(result.stdout)
    if not isinstance(value, dict):
        raise ValueError(f"expected an object in {path.relative_to(ROOT)}")
    return value


def markdown_section(markdown: str, heading: str, level: int = 2) -> str:
    hashes = "#" * level
    match = re.search(
        rf"(?ms)^{re.escape(hashes)} {re.escape(heading)}[ \t]*\n(.*?)(?=^{re.escape(hashes)} |\Z)",
        markdown,
    )
    if not match:
        raise ValueError(f"README is missing {hashes} {heading}")
    return match.group(1).strip()


def plain_markdown(markdown: str) -> str:
    without_code = re.sub(r"(?ms)```.*?```", "", markdown)
    without_links = re.sub(r"\[([^]]+)]\([^)]+\)", r"\1", without_code)
    without_marks = re.sub(r"[`*_]", "", without_links)
    lines = [line.strip() for line in without_marks.splitlines() if line.strip()]
    return " ".join(lines)


def markdown_bullets(markdown: str) -> list[str]:
    items: list[str] = []
    current: list[str] = []
    started = False
    for line in markdown.splitlines():
        match = re.match(r"^-\s+(.+)$", line)
        if match:
            if current:
                items.append(plain_markdown(" ".join(current)))
            current = [match.group(1)]
            started = True
            continue
        if started and line.startswith(("  ", "\t")) and line.strip():
            current.append(line.strip())
            continue
        if started:
            break
    if current:
        items.append(plain_markdown(" ".join(current)))
    return items


def markdown_links(markdown: str) -> list[dict[str, str]]:
    return [
        {"label": label, "href": href}
        for label, href in re.findall(r"(?m)^- \[([^]]+)]\(([^)]+)\)$", markdown)
    ]


def project_safe_form(slug: str, source: dict[str, Any]) -> dict[str, Any]:
    projected = {key: copy.deepcopy(value) for key, value in source.items() if key != "properties"}
    projected["properties"] = {}

    root_view = projected.get("viewSpec")
    if isinstance(root_view, dict):
        root_view["order"] = list(SAFE_FORM_FIELDS[slug])

    source_properties = source.get("properties")
    if not isinstance(source_properties, dict):
        raise ValueError(f"{slug}: form root properties must be an object")

    for section_name, field_names in SAFE_FORM_FIELDS[slug].items():
        source_section = source_properties.get(section_name)
        if not isinstance(source_section, dict):
            raise ValueError(f"{slug}: form section {section_name} is missing")
        section_properties = source_section.get("properties")
        if not isinstance(section_properties, dict):
            raise ValueError(f"{slug}: form section {section_name} has no properties")

        section = {
            key: copy.deepcopy(value)
            for key, value in source_section.items()
            if key != "properties"
        }
        section["properties"] = {}
        section_view = section.get("viewSpec")
        if isinstance(section_view, dict):
            section_view["order"] = list(field_names)

        for field_name in field_names:
            if field_name not in section_properties:
                raise ValueError(f"{slug}: form field {section_name}.{field_name} is missing")
            section["properties"][field_name] = copy.deepcopy(section_properties[field_name])
        projected["properties"][section_name] = section

    def validate(node: Any, path: tuple[str, ...] = ()) -> None:
        if isinstance(node, dict):
            view_type = node.get("viewSpec", {}).get("type") if isinstance(node.get("viewSpec"), dict) else None
            if view_type is not None and view_type not in SUPPORTED_WIDGETS:
                raise ValueError(f"{slug}: unsupported widget {view_type} at {'.'.join(path) or '<root>'}")
            properties = node.get("properties")
            if properties is not None:
                if not isinstance(properties, dict):
                    raise ValueError(f"{slug}: properties at {'.'.join(path) or '<root>'} must be an object")
                for name, child in properties.items():
                    if FORBIDDEN_FORM_TERMS.search(name):
                        raise ValueError(f"{slug}: forbidden form field {'.'.join((*path, name))}")
                    validate(child, (*path, name))
        elif isinstance(node, list):
            for index, child in enumerate(node):
                validate(child, (*path, str(index)))

    validate(projected)
    return projected


def category_labels() -> dict[str, str]:
    schema = json.loads((ROOT / "application-manifest.schema.json").read_text())
    choices = schema["properties"]["categories"]["items"]["oneOf"]
    return {choice["const"]: choice["title"] for choice in choices}


def application_projection(slug: str, output: Path, chart_repository: str) -> dict[str, Any]:
    package = ROOT / slug
    manifest = read_yaml(package / "manifest.yaml")
    licenses_document = read_yaml(package / "licenses.yaml")
    form = json.loads((package / "values.form.json").read_text())
    graph = read_yaml(package / "graph.yaml")
    readme = (package / "README.md").read_text()

    icon_bytes = (package / manifest["icon"]).read_bytes()
    icon_digest = digest_bytes(icon_bytes)
    icon_path = Path("assets") / f"{icon_digest}.svg"
    (output / icon_path).write_bytes(icon_bytes)

    description_section = markdown_section(readme, "Description")
    description_intro = description_section.split("### Key features", 1)[0].strip()
    key_features = markdown_bullets(markdown_section(readme, "Key features", level=3))
    licenses = licenses_document.get("licenses", [])
    if not isinstance(licenses, list) or not licenses:
        raise ValueError(f"{slug}: licenses.yaml must contain licenses")

    images = [
        f"{image['repository']}:{image['tag']}"
        for image in manifest.get("images", [])
    ]
    projected_licenses = [
        {
            "component": item["component"],
            "license": item["license"],
            "source": item["source"],
        }
        for item in licenses
    ]
    component_names = list(dict.fromkeys(item["component"] for item in projected_licenses))
    projected_form = project_safe_form(slug, form)
    chart_dir = package / manifest["artifacts"]["chartPath"]
    chart_metadata = read_yaml(chart_dir / "Chart.yaml")
    chart_archive = deterministic_chart_archive(chart_dir, output)
    chart_digest = f"sha256:{digest_file(chart_archive)}"

    return {
        "slug": manifest["slug"],
        "name": manifest["name"],
        "ownerName": manifest["ownerName"],
        "publisherName": manifest["publisherName"],
        "icon": {
            "digest": f"sha256:{icon_digest}",
            "mediaType": "image/svg+xml",
            "path": icon_path.as_posix(),
        },
        "categories": manifest["categories"],
        "shortDescription": plain_markdown(markdown_section(readme, "Short description")),
        "description": plain_markdown(description_intro),
        "overviewTitle": OVERVIEW_TITLES[slug],
        "keyFeatures": key_features,
        "tutorial": TEST_TUTORIALS[slug],
        "useCases": markdown_bullets(markdown_section(readme, "Use cases")),
        "links": markdown_links(markdown_section(readme, "Links")),
        "support": plain_markdown(markdown_section(readme, "Support")),
        "estimatedInstallTime": manifest["operational"]["estimatedInstallTime"],
        "maintenance": manifest["operational"]["maintenance"],
        "scaling": "Kubernetes native",
        "technologySummary": ", ".join([*component_names[:3], "Kubernetes"]),
        "license": ", ".join(dict.fromkeys(item["license"] for item in licenses)),
        "licenses": projected_licenses,
        "images": images,
        "formSpec": projected_form,
        "formDigest": f"sha256:{digest_bytes(canonical_json(projected_form))}",
        "chart": {
            "repositoryURL": chart_repository.rstrip("/"),
            "name": chart_metadata["name"],
            "version": manifest["artifacts"]["chartVersion"],
            "digest": chart_digest,
            "archive": chart_archive.relative_to(output).as_posix(),
        },
        "deployment": {
            "engine": graph["engine"],
            "sveltos": graph["sveltos"],
            "fixedValues": graph.get("helm", {}).get("fixedValues", {}),
            "valueMappings": graph.get("helm", {}).get("valueMappings", {}),
            "lifecycle": graph["lifecycle"],
            "access": graph.get("access", {}),
        },
    }


def add_tar_directory(bundle: tarfile.TarFile, name: str) -> None:
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = 0o755
    info.mtime = 0
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    bundle.addfile(info)


def add_tar_file(bundle: tarfile.TarFile, name: str, value: bytes) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(value)
    info.mode = 0o644
    info.mtime = 0
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    bundle.addfile(info, io.BytesIO(value))


def write_archive(output: Path) -> Path:
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.USTAR_FORMAT) as bundle:
        add_tar_directory(bundle, "assets")
        for asset in sorted((output / "assets").glob("*.svg")):
            add_tar_file(bundle, f"assets/{asset.name}", asset.read_bytes())
        add_tar_file(bundle, "catalog.json", (output / "catalog.json").read_bytes())

    archive = output / ARCHIVE_NAME
    with archive.open("wb") as destination:
        with gzip.GzipFile(
            filename="",
            fileobj=destination,
            mode="wb",
            compresslevel=9,
            mtime=0,
        ) as compressed:
            compressed.write(tar_buffer.getvalue())
    return archive


def default_producer_revision() -> str:
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    dirty = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return f"{revision}+working-tree" if dirty else revision


def sign_catalog_digest(catalog_digest: str, signing_key: Path, key_id: str) -> dict[str, str]:
    with tempfile.NamedTemporaryFile() as digest_file:
        digest_file.write(catalog_digest.encode())
        digest_file.flush()
        result = subprocess.run(
            [
                openssl_command(), "pkeyutl", "-sign", "-rawin",
                "-inkey", str(signing_key), "-in", digest_file.name,
            ],
            check=True,
            capture_output=True,
        )
    return {
        "algorithm": "Ed25519",
        "keyID": key_id,
        "value": base64.b64encode(result.stdout).decode(),
    }


def build(
    output: Path,
    producer_revision: str,
    release_revision: str,
    chart_repository: str,
    signing_key: Path | None = None,
    signing_key_id: str = "",
) -> dict[str, Any]:
    output = output.resolve()
    protected = {ROOT.resolve(), Path.home().resolve(), Path("/").resolve()}
    if output in protected:
        raise ValueError(f"refusing to replace protected output path: {output}")
    if output.exists():
        shutil.rmtree(output)
    (output / "assets").mkdir(parents=True)

    core = {
        "schemaVersion": 1,
        "producer": "supergate-hub/cluster-stacks",
        "producerRevision": producer_revision,
        "releaseRevision": release_revision,
        "releaseMode": "oci",
        "categoryLabels": category_labels(),
        "applications": [application_projection(slug, output, chart_repository) for slug in APPLICATIONS],
    }
    catalog_digest = digest_bytes(canonical_json(core))
    catalog = {**core, "catalogDigest": f"sha256:{catalog_digest}"}
    if signing_key is not None:
        if not signing_key_id:
            raise ValueError("--signing-key-id is required with --signing-key")
        catalog["signature"] = sign_catalog_digest(catalog["catalogDigest"], signing_key, signing_key_id)
    (output / "catalog.json").write_bytes(pretty_json(catalog))

    archive = write_archive(output)
    release_files = [
        output / "catalog.json",
        *sorted((output / "assets").glob("*.svg")),
        *sorted((output / "charts").glob("*.tgz")),
    ]
    release = {
        "schemaVersion": 1,
        "name": "applications-catalog-ui-test",
        "producer": core["producer"],
        "producerRevision": producer_revision,
        "releaseRevision": release_revision,
        "catalogDigest": catalog["catalogDigest"],
        "artifact": {
            "path": archive.name,
            "digest": f"sha256:{digest_file(archive)}",
            "mediaType": "application/vnd.supergate.application-catalog.v1+tar+gzip",
        },
        "charts": [application["chart"] for application in catalog["applications"]],
        "files": [
            {
                "path": path.relative_to(output).as_posix(),
                "sha256": digest_file(path),
            }
            for path in release_files
        ],
    }
    (output / "release.json").write_bytes(pretty_json(release))
    return release


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--producer-revision", default=None)
    parser.add_argument("--release-revision", default="test.1")
    parser.add_argument("--chart-repository", default="oci://127.0.0.1:5000/launcher/charts")
    parser.add_argument("--signing-key", type=Path, default=None)
    parser.add_argument("--signing-key-id", default="")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    release = build(
        args.output,
        args.producer_revision or default_producer_revision(),
        args.release_revision,
        args.chart_repository,
        args.signing_key,
        args.signing_key_id,
    )
    print(json.dumps(release, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

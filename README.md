# cluster-stacks

User-selectable Kubernetes application packages for Launcher-managed clusters.

## Applications

- `headlamp/`: Kubernetes web UI and resource management.
- `argo-cd/`: declarative continuous delivery for Kubernetes.
- `mlflow/`: experiment tracking and model registry with in-cluster storage.

Every top-level directory is a deployable application package. Repository-wide
schema, validation, and overview files stay at the repository root so catalog
scanners can treat directories as applications without exceptions.

## Category taxonomy

Application categories use a small product-area taxonomy rather than
application-specific tags. A manifest must select one primary category and may
select one supporting category.

| Manifest value | Display label | Scope |
| --- | --- | --- |
| `ai-ml` | AI & ML | Model development, training, agents, and AI lifecycle tools. |
| `development` | Development | IDEs, notebooks, CI/CD, and developer tooling. |
| `serving` | Serving | Model inference and application-serving runtimes. |
| `orchestration` | Orchestration | Delivery, workflows, scheduling, and control planes. |
| `observability` | Observability | Metrics, logs, traces, dashboards, and diagnostics. |
| `data` | Data | Databases, storage, streaming, and data lifecycle tools. |
| `infrastructure` | Infrastructure | Cluster, networking, security, and platform operations. |

Do not create a new category for an individual technology or use case. Add a
category only when a durable product area cannot fit this taxonomy.

## Structure

```text
cluster-stacks/
├── headlamp/
│   ├── manifest.yaml
│   ├── icon.svg
│   ├── README.md
│   ├── values.form.json
│   ├── graph.yaml
│   ├── licenses.yaml
│   └── chart/
├── argo-cd/
├── mlflow/
├── APPLICATION-FORM.md
├── application-manifest.schema.json
├── validate-applications.sh
└── README.md
```

Each application directory is self-contained. Its metadata, detail-page
content, installation form, deployment graph, license data, root Helm chart,
and every chart dependency required for rendering are versioned together.

Two chart layouts are supported:

- A thin wrapper with pinned dependency archives under `chart/charts/`, as used
  by Headlamp.
- A vendored upstream chart with `templates/`, its schema, and unpacked
  dependencies under `chart/charts/`, as used by Argo CD and MLflow.

Both layouts must include `Chart.lock` when the root chart declares
dependencies. Validation and installation use only committed chart content;
they do not download dependencies at runtime.

See [Application form contract](APPLICATION-FORM.md) for the supported form
keywords, widget allowlist, mapping rules, and no-secret policy.

## Catalog release

Launcher consumes one deterministic catalog payload plus deterministic Helm chart
archives. The same compiler output drives local contract tests and OCI publication
to Harbor, avoiding copied frontend product data.

```bash
python3 build_catalog_test_release.py \
  --output /tmp/application-catalog-v1 \
  --producer-revision 1d8311a-test \
  --release-revision test.1 \
  --chart-repository oci://harbor.example/launcher/charts
```

The output contains `catalog.json`, digest-addressed SVG assets, deterministic
chart archives, `application-catalog-test-v1.tar.gz`, and `release.json` with
checksums. Production builds also pass an Ed25519 key and key ID, then publish the
catalog and charts with `publish_catalog_release.sh`.

The supported automation entry points are:

```bash
make check

make build-catalog \
  CATALOG_OUTPUT=/secure/staging/application-catalog-v1 \
  CATALOG_RELEASE_REVISION=2026.07.22.1 \
  CATALOG_CHART_REPOSITORY=oci://harbor.example/launcher/charts \
  CATALOG_SIGNING_KEY=/secure/keys/catalog-ed25519.pem \
  CATALOG_SIGNING_KEY_ID=catalog-2026

make publish-catalog-validate \
  CATALOG_OUTPUT=/secure/staging/application-catalog-v1 \
  CATALOG_REF=oci://harbor.example/launcher/catalog:2026.07.22.1

COSIGN_KEY_REF=/secure/keys/charts-cosign.key \
  ./publish_catalog_release.sh \
    --release-dir /secure/staging/application-catalog-v1 \
    --catalog-ref oci://harbor.example/launcher/catalog:2026.07.22.1 \
    --immutable-tags-confirmed
```

The publisher authenticates through the standard Helm, ORAS, and Cosign stores,
never command-line passwords. It verifies each uploaded Helm content-layer
digest against `catalog.json` and signs resolved manifest digests. Harbor tag
immutability is a mandatory deployment gate because Sveltos v1.12.0 consumes a
semantic chart version. Configure retention so catalog releases and chart tags
referenced by active `ApplicationInstallation` objects are not garbage-collected.

The catalog projection deliberately exposes only approved, non-secret guided
fields. Target cluster, installation name, namespace, and uninstall data policy
remain Launcher-owned fields; password and unrestricted YAML widgets are never
included.

## Installation flow

1. CI validates and compiles package files into deterministic catalog and chart
   artifacts, publishes them under immutable Harbor tags, and signs their
   resolved manifest digests.
2. The Launcher backend periodically resolves the configured catalog channel,
   verifies its signature and contents, and atomically serves projections.
3. The UI reads list, detail, form, and lifecycle DTOs from Launcher APIs.
4. Launcher validates submitted fields against the pinned form and graph,
   resolves the selected CAPI Cluster UID, and writes `ApplicationInstallation`.
5. cluster-operator creates one namespaced Sveltos Profile in `Continuous` mode.
6. Sveltos installs or removes the pinned OCI Helm chart in the target cluster.

The model creates one Helm release in a dedicated namespace and exposes reviewed
application settings only. It does not accept secrets or arbitrary YAML, create
clusters, or configure provider-specific networking. Drift detection, automatic
repair, and runtime-health semantics are not enabled.

## Validation

```bash
make check
```

The validator checks package structure, local SVG safety, metadata references,
README sections, version consistency, form security rules, deterministic test
release output, committed dependency locks and artifacts, JSON and YAML syntax,
and Helm rendering. All chart checks are offline. Use `--structure-only` when
Helm is unavailable.

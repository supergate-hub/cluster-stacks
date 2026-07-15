# cluster-stacks

User-selectable Kubernetes application packages for Launcher-managed clusters.

## Applications

- `headlamp/`: Kubernetes web UI and resource management.
- `argo-cd/`: declarative continuous delivery for Kubernetes.
- `mlflow/`: experiment tracking and model registry with in-cluster storage.

Every top-level directory is a deployable application package. Repository-wide
schema, validation, and overview files stay at the repository root so catalog
scanners can treat directories as applications without exceptions.

## Structure

```text
cluster-stacks/
├── headlamp/
│   ├── manifest.yaml
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
content, installation form, deployment graph, license data, and thin Helm
wrapper are versioned together.

See [Application form contract](APPLICATION-FORM.md) for the supported form
keywords, widget registry, mapping rules, and sensitive-value requirements.

## Installation flow

1. The catalog indexer reads `manifest.yaml` and its referenced content files.
2. The UI renders a shared detail page from `README.md` and `licenses.yaml`.
3. The UI builds the installation form from `values.form.json`.
4. The backend resolves `graph.yaml` against an existing Kubernetes cluster.
5. The package's wrapper chart installs its pinned upstream chart dependency.

The initial model creates one Helm release in a dedicated namespace and exposes
only reviewed application settings. It does not create clusters, ingresses,
DNS records, identity resources, or provider-specific networking.

## Validation

```bash
./validate-applications.sh
```

The validator checks package structure, metadata references, README sections,
version consistency, JSON and YAML syntax, and Helm rendering. Use
`--structure-only` when network access is unavailable.

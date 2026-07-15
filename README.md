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
keywords, widget registry, mapping rules, and sensitive-value requirements.

## Installation flow

1. The catalog indexer reads `manifest.yaml` and its referenced content files.
2. The UI renders a shared detail page from `README.md` and `licenses.yaml`.
3. The UI builds the installation form from `values.form.json`.
4. If the application opts into advanced values, the YAML editor reads the
   package's `chart/values.yaml` as its canonical reference and submits only
   user overrides.
5. The backend resolves `graph.yaml` against an existing Kubernetes cluster.
6. The backend renders the self-contained chart using the committed
   dependencies.

The initial model creates one Helm release in a dedicated namespace and exposes
reviewed application settings. An application may additionally expose an
explicit advanced YAML override editor. It does not create clusters, ingresses,
DNS records, identity resources, or provider-specific networking.

## Validation

```bash
./validate-applications.sh
```

The validator checks package structure, metadata references, README sections,
version consistency, form security rules, committed dependency locks and
artifacts, JSON and YAML syntax, and Helm rendering. All chart checks are
offline. Use `--structure-only` when Helm is unavailable.

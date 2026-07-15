# MLflow

## Description

MLflow is an open-source platform for managing the machine learning lifecycle.
This package installs an MLflow tracking server with an in-cluster PostgreSQL
backend and MinIO artifact storage so that experiments, parameters, metrics,
models, and artifacts survive pod restarts.

### Key features

- Record experiment runs, parameters, metrics, tags, and artifacts.
- Compare runs and visualize results in a shared web interface.
- Register, version, and promote trained models.
- Use PostgreSQL for metadata and S3-compatible object storage for artifacts.
- Require username and password authentication for the tracking server.

The first package version is a self-contained single-replica deployment. It is
suited to team evaluation and moderate internal workloads; external databases,
external object storage, backups, and high availability are later deployment
profiles.

## Short description

Experiment tracking and model registry with persistent in-cluster storage.

## Tutorial

1. Select an existing Kubernetes cluster with a default StorageClass.
2. Keep the default release name and namespace, or enter DNS-compatible values.
3. Set the MLflow administrator username and a password of at least 12
   characters.
4. Review the PostgreSQL and artifact volume sizes. Optionally choose a specific
   StorageClass.
5. Install the application and wait for MLflow, PostgreSQL, and MinIO workloads
   to become ready.

The password field is sensitive. The deployment backend must redact it from
logs and API responses and pass it only as a Helm secret value.

## Usage

The service is private by default. Forward it for a local browser session:

```bash
kubectl -n mlflow port-forward service/mlflow 5000:80
```

Open `http://localhost:5000` and sign in with the credentials entered during
installation. A Python client can use the same endpoint:

```bash
export MLFLOW_TRACKING_URI=http://localhost:5000
export MLFLOW_TRACKING_USERNAME=admin
export MLFLOW_TRACKING_PASSWORD='<your-password>'
```

Back up both the PostgreSQL volume and the MinIO volume before upgrades or
cluster maintenance. This package does not configure an automated backup job.

## Use cases

- Share experiment results across a machine learning team.
- Compare model parameters and evaluation metrics.
- Store and version model artifacts inside the cluster.
- Maintain a central model registry for development workflows.

## Links

- [Project website](https://mlflow.org/)
- [Documentation](https://mlflow.org/docs/latest/)
- [Source repository](https://github.com/mlflow/mlflow)
- [Helm chart documentation](https://community-charts.github.io/docs/charts/mlflow/)

## Support

The platform team supports package installation and the pinned chart defaults.
For MLflow defects or feature requests, use the MLflow project's issue tracker.
Chart-specific problems should be reported to the chart source repository.

## Legal

The package includes components under Apache-2.0, MIT, PostgreSQL, and
AGPL-3.0 licenses. See `licenses.yaml` for the component-level records and
source links.

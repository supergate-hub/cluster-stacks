# Argo CD

## Description

Argo CD is a declarative continuous delivery controller for Kubernetes. It
compares resources in a Git repository with live cluster state and can apply
the declared state automatically or after approval.

### Key features

- Continuously detect drift between Git and Kubernetes resources.
- Synchronize plain YAML, Kustomize, Helm, Jsonnet, and custom config plugins.
- Show application health, sync state, resource relationships, and history.
- Control access with projects, roles, and single sign-on integrations.
- Manage applications through a web UI, CLI, API, or Kubernetes resources.

This package installs a single-cluster, non-HA configuration. The ApplicationSet
controller is included by the chart, while notifications and Dex are disabled
by default to keep the initial footprint small.

## Short description

Declarative GitOps continuous delivery and drift reconciliation for Kubernetes.

## Tutorial

1. Select an existing Kubernetes cluster.
2. Keep the default release name and namespace, or enter DNS-compatible values.
3. Optionally set an administrator password and enable notifications.
4. Use **Customize values** only when you need settings outside the guided form.
5. Install the application and wait for all Argo CD workloads to become ready.

For the default release and namespace:

```bash
kubectl -n argo-cd get secret argo-cd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

The command above is needed only when the administrator password was left empty.
The login username is `admin`. Change generated passwords after the first login
and configure repository credentials through Argo CD rather than this catalog
form.

Advanced settings are stored as YAML overrides. The chart's `values.yaml` is the
canonical reference shown by the editor; it is not copied into the form file.
Guided settings for the administrator password, notifications, Dex, and the
private server service take precedence over advanced YAML.

## Usage

The API server is private by default. Forward its HTTPS service for a local
session:

```bash
kubectl -n argo-cd port-forward service/argo-cd-server 8080:443
```

Open `https://localhost:8080`, or use the CLI with the same endpoint. A platform
gateway or separately managed ingress can provide persistent remote access.

Create Argo CD `Application` or `ApplicationSet` resources after connecting a
Git repository and defining the intended destination clusters and namespaces.

## Use cases

- Deploy applications from reviewed Git revisions.
- Detect and reconcile configuration drift.
- Visualize rollout health and resource dependencies.
- Operate many similar applications with ApplicationSet generators.

## Links

- [Documentation](https://argo-cd.readthedocs.io/)
- [Source repository](https://github.com/argoproj/argo-cd)
- [Helm chart source](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd)
- [Getting started guide](https://argo-cd.readthedocs.io/en/stable/getting_started/)

## Support

The platform team supports package installation and the pinned chart defaults.
For controller defects or feature requests, use the Argo CD project's issue
tracker.

## Legal

Argo CD and its Helm chart are distributed under the Apache License 2.0. See
`licenses.yaml` for structured license records and source links.

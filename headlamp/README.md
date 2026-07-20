# Headlamp

## Description

Headlamp is a web-based Kubernetes user interface. It provides a visual way to
inspect cluster resources, review workloads, read logs, and perform operations
allowed by the Kubernetes identity used to sign in.

### Key features

- Browse workloads, configuration, storage, networking, and custom resources.
- Inspect object details, events, logs, and YAML from one interface.
- Use the permissions of the signed-in Kubernetes identity.
- Extend the interface with Headlamp plugins.
- Run entirely inside the selected cluster behind a `ClusterIP` service.

The installation form makes the access role explicit. `view` is the default;
`cluster-admin` should be selected only when users need unrestricted cluster
management from the UI.

## Short description

A Kubernetes web UI for inspecting and managing resources with role-based
access.

## Tutorial

1. Select an existing Kubernetes cluster.
2. Keep the default release name and namespace, or enter DNS-compatible values.
3. Choose `Read-only` or `Full cluster administration` access.
4. Use **Customize values** only when you need settings outside the guided form.
5. Install the application and wait for the Helm release to become ready.
6. Create a token for the Headlamp service account and use it on the sign-in
   screen.

For the default release and namespace:

```bash
kubectl -n headlamp create token headlamp
```

The package does not enable service-account-token impersonation. Each user must
authenticate, and the selected ClusterRole limits what that token can do.

Advanced settings are stored as YAML overrides. The chart's `values.yaml` is
the canonical reference shown by the editor; it is not copied into the form
file. The guided cluster access role and the package's private-service defaults
take precedence over advanced YAML.

## Usage

The service is private by default. For a local session, forward it to your
machine:

```bash
kubectl -n headlamp port-forward service/headlamp 4466:80
```

Open `http://localhost:4466` and sign in with a Kubernetes token. A platform
gateway or a separately managed ingress can expose the service when persistent
remote access is required.

## Use cases

- Give developers read-only visibility into workloads and events.
- Investigate failed pods, logs, configuration, and resource status.
- Provide administrators with a visual interface for cluster operations.
- Explore custom resources installed by operators.

## Links

- [Project website](https://headlamp.dev/)
- [Documentation](https://headlamp.dev/docs/latest/)
- [Source repository](https://github.com/kubernetes-sigs/headlamp)
- [Helm chart](https://artifacthub.io/packages/helm/headlamp/headlamp)

## Support

The platform team supports package installation and the pinned chart defaults.
For application defects or feature requests, use the Headlamp project's issue
tracker.

## Legal

Headlamp is distributed under the Apache License 2.0. See `licenses.yaml` for
the structured license record and source link.

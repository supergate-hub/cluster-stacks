# cluster-stacks

GitOps manifests for Launcher platform cluster provisioning.

## Structure

```
cluster-stacks/
├── base/                    # Reusable templates
│   ├── slurm-cluster/       # Slinky CRD templates (Controller, NodeSet, RestApi)
│   └── k8s-tenant/          # Kamaji CRD templates (future)
├── clusters/                # Per-cluster overlays (ArgoCD watches this)
│   └── slurm/
│       └── {cluster-name}/  # Kustomize overlay per cluster
├── operators/               # Operator installation guides
│   ├── slinky/              # Slinky slurm-operator
│   └── argocd/              # ArgoCD ApplicationSet definitions
└── README.md
```

## How it works

1. Launcher BE creates a new directory under `clusters/slurm/{name}/`
2. ArgoCD ApplicationSet detects the new directory
3. ArgoCD creates an Application and syncs the manifests
4. Slinky Operator provisions the SLURM cluster

## Prerequisites

- Kubernetes v1.29+
- cert-manager
- Slinky slurm-operator (see `operators/slinky/install.yaml`)
- ArgoCD with ApplicationSet controller

## Creating a cluster

```bash
# Copy base template and customize
cp -r base/slurm-cluster clusters/slurm/my-cluster
# Edit placeholders: CLUSTER_NAME, CLUSTER_NAMESPACE, etc.
# Commit and push — ArgoCD handles the rest
```

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
├── catalog/                 # Tenant add-on Helm chart wrappers
│   ├── compute-csi-plugin/  # OpenStack Cinder CSI default StorageClass
│   ├── openstack-cinder-csi/ # Launcher controller-managed Cinder CSI catalog
│   └── ...
├── appsets/                 # ArgoCD ApplicationSets for infra/addons
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

## Default Tenant Addons

`appsets/tenant-addons.yaml` installs the baseline tenant addons for every
Launcher-managed SLURM cluster registered in ArgoCD.

- `local-path-provisioner`: fallback explicit local PV provisioner.
- `compute-csi-plugin`: OpenStack Cinder CSI driver, installed into
  `kube-system` with default StorageClass `compute-csi-default-sc`.
- `cert-manager`: webhook/certificate bootstrap.
- `slinky-crds` and `slinky-operator`: SLURM operator resources.

`compute-csi-plugin` expects Launcher to create
`kube-system/openstack-cloud-config` in the tenant cluster before ArgoCD syncs
the addon. The Secret must contain `cloud.conf`; `cacert` is optional.

## Controller-managed OpenStack Cinder CSI

`catalog/openstack-cinder-csi` is the catalog path used by Launcher controller
when a `LauncherCluster` requests the `openstack-cinder-csi` addon. It uses the
same upstream chart as `compute-csi-plugin`, but renders the StorageClasses and
resource names expected by the Launcher addon health policy:

- `openstack-cinder-csi-controllerplugin`
- `openstack-cinder-csi-nodeplugin`
- `cinder.csi.openstack.org`
- `csi-cinder-sc-delete`
- `csi-cinder-sc-retain`

`appsets/tenant-cinder-csi.yaml` is a standalone fallback for clusters that are
not already managed by the Launcher controller addon reconciler. It installs the
same catalog chart only when the ArgoCD cluster Secret has both labels:

```yaml
launcher.supergate.io/cinder-csi: enabled
launcher.supergate.io/addon-owner: applicationset
```

Do not enable the standalone ApplicationSet path for a cluster where Launcher is
already creating the `<cluster>-openstack-cinder-csi` Application.

The tenant cluster must already contain `kube-system/openstack-cloud-config`
with `cloud.conf` and `clouds.yaml` keys. The Cinder CSI driver reads
INI-style `cloud.conf`; the CAPO `clouds.yaml` Secret is not accepted directly
by the driver.

## Creating a cluster

```bash
# Copy base template and customize
cp -r base/slurm-cluster clusters/slurm/my-cluster
# Edit placeholders: CLUSTER_NAME, CLUSTER_NAMESPACE, etc.
# Commit and push — ArgoCD handles the rest
```

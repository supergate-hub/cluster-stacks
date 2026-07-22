# Application form contract

Status: v1

`values.form.json` is the catalog-owned, non-secret portion of an application
installation form. Launcher renders it with `@gravity-ui/dynamic-forms` and its
own visual adapters. It is JSON-Schema-inspired, but it is not JSON Schema.

Launcher owns target cluster, release name, namespace, data policy, confirmation,
and lifecycle controls outside this document. Package forms must never redefine
those fields.

## Responsibilities

| Concern | Owner |
| --- | --- |
| Application-specific inputs and safe defaults | `values.form.json` |
| Form-to-Helm mapping and platform safeguards | `graph.yaml` |
| Target, release name, namespace, and data policy | Launcher |
| Secret generation and storage | Target-cluster chart/templates or an approved secret provider |
| Helm execution and last-operation status | cluster-operator and Sveltos |

The browser and Launcher backend never accept an application secret value. There
is no password widget, secret widget, arbitrary YAML editor, or raw Helm values
escape hatch in v1.

## Document shape

Every form is an ordered object of application-specific sections:

```json
{
  "type": "object",
  "required": true,
  "defaultValue": {},
  "viewSpec": {
    "type": "base",
    "order": ["configuration"]
  },
  "properties": {}
}
```

Supported data keywords are `type`, `properties`, `required`, `defaultValue`,
`enum`, `enumNames`, `pattern`, `patternError`, `minLength`, and `minimum`.
`required` is a field-level boolean and `defaultValue` is used instead of JSON
Schema's `default`.

## View specification

Supported `viewSpec` properties are:

| Property | Purpose |
| --- | --- |
| `type` | Selects one of the supported renderers below. |
| `layout` | Uses `section` or `row` placement. |
| `layoutTitle` | Visible section or field title. |
| `layoutDescription` | Non-sensitive help text. |
| `order` | Child rendering order. |

The v1 widget allowlist is intentionally small:

| `viewSpec.type` | Value | Usage |
| --- | --- | --- |
| `base` | object, string, or number | Sections and ordinary Launcher-styled inputs. |
| `select` | string | One value from `enum`, with optional `enumNames`. |
| `switch` | boolean | A non-sensitive toggle. |

Any other widget fails catalog compilation. In particular, `password`,
`yaml_input`, `cluster_select`, `inputProps`, and random-secret controls are not
part of this contract.

## Mapping to Helm values

`graph.yaml` maps form paths to reviewed Helm value paths:

```yaml
schemaVersion: 1
engine: sveltos
sveltos:
  apiVersion: config.projectsveltos.io/v1beta1
  syncMode: Continuous
  driftDetection: false
  healthChecks: false
helm:
  fixedValues:
    server.service.type: ClusterIP
  valueMappings:
    headlamp.clusterRoleBinding.clusterRoleName: configuration.clusterRoleName
```

The compiler combines only `helm.fixedValues` and validated `helm.valueMappings`.
Unknown form paths, unknown submitted keys, type mismatches, and secret-like keys
are rejected. Launcher persists the normalized result in
`ApplicationInstallation.spec.values`; the operator adds only its reserved
`launcher.dataPolicy` value before creating the Sveltos Profile.

Sveltos always uses `Continuous`. `ContinuousWithDriftDetection`, drift detection,
automatic drift repair, health checks, and reloaders are outside v1. Installed
means the last explicit Launcher operation succeeded; it is not runtime health.

## Secret policy

Secret-like field names include password, token, secret, credential, API key, and
kubeconfig variants. Such fields are rejected at compile time and again at the
Launcher API and CRD admission boundaries.

When an application needs an initial credential, the chart creates or references
it inside the target cluster. For example, the MLflow chart generates a random
password on first install and preserves the existing Secret on update. Launcher
may later expose a separately authorized credential-retrieval action, but it does
not return credentials in catalog or installation DTOs.

## Compatibility and author checklist

The catalog compiler publishes `schemaVersion: 1` plus a digest of the projected
form. A field rename, type change, or renderer change is breaking and requires a
new compatible catalog revision. Adding an optional allowlisted field is backward
compatible.

Before submitting a package:

- Expose only reviewed application-specific values.
- Keep target, release, namespace, and data policy out of the form.
- Use safe non-secret defaults and the allowlisted widgets only.
- Map every submitted field explicitly in `graph.yaml`.
- Generate credentials inside the target cluster or use an approved provider.
- Declare `Continuous` with drift detection and health checks disabled.
- Commit every Helm dependency and run `./validate-applications.sh`.

Headlamp, Argo CD, and MLflow are the canonical v1 examples.

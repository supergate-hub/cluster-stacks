# Application form contract

Status: draft v1

`values.form.json` is the declarative installation-form contract for an
application package. Application authors write this file; it is not generated
from Helm `values.yaml`. The UI renders the form automatically after loading the
file and the deployment backend maps the submitted values through `graph.yaml`.
When an application exposes advanced Helm configuration, `chart/values.yaml`
is the canonical editor reference and the form stores only the user's YAML
overrides, never a copied snapshot of the full defaults.

The format is based on
[`@gravity-ui/dynamic-forms`](https://gravity-ui.com/libraries/dynamic-forms)
and adds a small registry of platform-specific widgets. It is JSON
Schema-inspired, but it is not a standard JSON Schema document.

## Responsibilities

| Concern | Owner |
| --- | --- |
| Available inputs, defaults, validation, and layout | Application package `values.form.json` |
| Supported field and layout renderers | Launcher UI widget registry |
| Mapping submitted values to typed parameters | Application package `graph.yaml` |
| Mapping parameters to Helm values | Application package `graph.yaml` |
| Redaction and transport of sensitive values | Launcher UI and deployment backend |

An application package may use only widgets that are registered in the UI.
Adding an arbitrary `viewSpec.type` to a package does not make that widget
available automatically.

## Base document

Every form is an object with ordered top-level sections:

```json
{
  "type": "object",
  "required": true,
  "defaultValue": {},
  "viewSpec": {
    "type": "base",
    "order": ["targetCluster", "general", "configuration"]
  },
  "properties": {}
}
```

The top-level section order should be:

1. `targetCluster`
2. `general`
3. Application-specific sections

`general` contains `appname` and `namespace`. Both must use a Kubernetes
DNS-compatible validation pattern.

## Data keywords

The current contract supports these data keywords:

| Keyword | Purpose |
| --- | --- |
| `type` | `object`, `string`, `number`, or `boolean`. |
| `properties` | Child fields of an object. |
| `required` | Field-level boolean requirement. |
| `defaultValue` | Initial value displayed by the form. |
| `enum` | Allowed values for a select field. |
| `enumNames` | Display labels corresponding to `enum`. |
| `pattern` | Regular expression for string validation. |
| `patternError` | User-facing message when `pattern` fails. |
| `minLength` | Minimum string length. |
| `minimum` | Minimum numeric value. |

Important differences from standard JSON Schema include:

- `required` is a boolean on each field rather than an array on its parent.
- `defaultValue` is used instead of `default`.
- `viewSpec`, `patternError`, and `enumNames` are renderer extensions.

A generic JSON Schema renderer will therefore not reproduce this form
contract without an adapter.

## View specification

`viewSpec` controls how a field is rendered without changing its submitted
value.

| Property | Purpose |
| --- | --- |
| `type` | Selects a registered renderer. |
| `layout` | Selects placement such as `section` or `row`. |
| `layoutTitle` | Visible field or section title. |
| `layoutDescription` | Help text displayed with the field. |
| `order` | Defines child rendering order. |
| `generateRandomValueButton` | Allows the UI to generate a random secret. |
| `inputProps` | Supplies renderer-specific options for platform widgets. |

### Required widget registry

The initial application packages require the following widgets:

| `viewSpec.type` | Input/output | Contract |
| --- | --- | --- |
| `base` | Scalar or object | Default renderer used with `row` and `section` layouts. |
| `cluster_select` | Object | Selects an existing cluster and returns `clusterId` and `name`. |
| `select` | String | Renders the values declared by `enum` and optional `enumNames`. |
| `switch` | Boolean | Renders a boolean toggle. |
| `password` | String | Masks input; the mapped graph parameter must be sensitive. |
| `yaml_input` | String | Opens the platform YAML editor and returns a YAML override document; the mapped graph parameter must be sensitive. |

The UI must register these widgets before the corresponding application forms
can be used.

`cluster_select` is a platform widget. Its submitted value has this shape even
though its child fields are not repeated in the application form:

```json
{
  "clusterId": "cluster-identifier",
  "name": "cluster-name"
}
```

`yaml_input` is a Launcher platform widget, not a renderer supplied by
`@gravity-ui/dynamic-forms`. The UI must register it explicitly. Its current
`inputProps` contract is:

| Property | Required | Purpose |
| --- | --- | --- |
| `sourcePath` | Yes | Application-relative path to the canonical Helm defaults. It must be `chart/values.yaml`. |
| `editMode` | Yes | Must be `overrides`; the submitted string contains only user changes. |
| `buttonText` | No | Label for the button that opens the editor. |
| `dialogTitle` | No | Title displayed in the editor dialog. |
| `description` | No | Help text shown in the editor. |

The YAML field should default to an empty mapping (`"{}\n"`). The UI may show
the canonical values as reference or autocomplete context, but it must not copy
the entire file into form state. This keeps chart upgrades and editor defaults
in sync.

Example:

```json
{
  "type": "string",
  "required": true,
  "defaultValue": "{}\n",
  "viewSpec": {
    "type": "yaml_input",
    "layout": "row",
    "layoutTitle": "Helm values",
    "inputProps": {
      "buttonText": "Customize values",
      "sourcePath": "chart/values.yaml",
      "editMode": "overrides"
    }
  }
}
```

New widgets must define their input type, output shape, validation behavior,
and sensitive-data behavior in this document before an application uses them.

## Mapping to a deployment

Form values are not passed directly to Helm. The data flow is:

```text
values.form.json
  -> submitted form object
  -> graph.yaml ui.mapping
  -> typed graph parameters
  -> helm_chart rawValues and structured values
  -> packaged root chart
```

For example, the Headlamp form maps its selected access role as follows:

```text
configuration.clusterRoleName
  -> clusterRoleName
  -> headlamp.clusterRoleBinding.clusterRoleName
```

The MLflow administrator password follows the same mapping path, but its graph
parameter is marked sensitive:

```yaml
parameters:
  adminPassword:
    type: string
    sensitive: true

ui:
  mapping:
    adminPassword: authentication.adminPassword
```

Every `ui.mapping` entry must satisfy all of these rules:

1. The source path exists in `values.form.json`, or is part of a registered
   widget's documented output shape.
2. The target parameter exists in `graph.yaml`.
3. Field and parameter types match.
4. A password or secret field maps to a parameter with `sensitive: true`.
5. Every guided parameter that changes Helm values is explicitly mapped.
6. Arbitrary Helm overrides are accepted only when the application explicitly
   declares the `yaml_input` contract described below.

## Advanced Helm values

Advanced Helm values are opt-in per application. A package that enables them
must connect the YAML editor, a sensitive string parameter, and the Helm release
explicitly:

```yaml
components:
  helmRelease:
    type: helm_chart
    spec:
      rawValues: "${{ .parameters.rawValues }}"
      values:
        notifications:
          enabled: "${{ .parameters.notificationsEnabled }}"

parameters:
  rawValues:
    type: string
    sensitive: true

ui:
  mapping:
    rawValues: setup.compose.data
```

The deployment backend must parse `rawValues` as a YAML mapping and merge in
this order, from lowest to highest precedence:

```text
chart/values.yaml defaults
  < user rawValues overrides
  < graph.yaml structured values
```

Structured values include guided settings, platform-required safeguards, and
sensitive inputs. They therefore take precedence when the same key appears in
advanced YAML. The UI should explain this near the editor, and the backend must
reject invalid YAML or a non-mapping root before Helm rendering.

Argo CD is the canonical advanced-values example. Headlamp and MLflow currently
use guided forms only.

## Sensitive values

Sensitive fields must:

- use the `password` widget or another registered secret widget;
- have no committed default value;
- map to a graph parameter with `sensitive: true`;
- be redacted from logs, API responses, events, and deployment status;
- be transmitted only to the component that creates the Helm release.

Because arbitrary YAML may contain credentials, the entire `rawValues`
parameter is sensitive even when its current content has no secrets. It follows
the same redaction, transport, and retention rules as password parameters.

The form schema controls presentation only. The UI and backend remain
responsible for enforcing redaction and storage policy.

## Compatibility and versioning

The files currently implement the draft v1 contract without an explicit
version field. Until version negotiation is implemented, the catalog reader
must treat all `values.form.json` files as v1.

Changes are classified as follows:

- Adding an optional field or enum label is backward compatible.
- Adding a widget requires the UI widget registry to be deployed first.
- Renaming a field, changing its type, or changing a widget output is breaking.
- Breaking changes require a new form-contract version and migration policy.

The UI must pin a compatible `@gravity-ui/dynamic-forms` version. Application
packages must not rely on renderer behavior that is absent from the documented
contract.

## Author checklist

Before submitting an application form:

- Keep cluster selection and general release fields first.
- Expose only reviewed values required by the supported deployment profile.
- Provide safe defaults for non-sensitive fields.
- Use clear labels, descriptions, validation errors, and deterministic order.
- Confirm every form output has a matching `graph.yaml` mapping.
- Mark every secret parameter as sensitive.
- Keep `chart/values.yaml` as the only full Helm-default source.
- For `yaml_input`, submit overrides only and apply structured values last.
- Commit `Chart.lock` and every declared chart dependency.
- Run `./validate-applications.sh`.

The existing Headlamp, Argo CD, and MLflow packages are the canonical v1
examples.

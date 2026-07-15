# Application form contract

Status: draft v1

`values.form.json` is the declarative installation-form contract for an
application package. Application authors write this file; it is not generated
from Helm `values.yaml`. The UI renders the form automatically after loading the
file and the deployment backend maps the submitted values through `graph.yaml`.

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

### Required widget registry

The initial application packages require the following widgets:

| `viewSpec.type` | Input/output | Contract |
| --- | --- | --- |
| `base` | Scalar or object | Default renderer used with `row` and `section` layouts. |
| `cluster_select` | Object | Selects an existing cluster and returns `clusterId` and `name`. |
| `select` | String | Renders the values declared by `enum` and optional `enumNames`. |
| `switch` | Boolean | Renders a boolean toggle. |
| `password` | String | Masks input; the mapped graph parameter must be sensitive. |

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

New widgets must define their input type, output shape, validation behavior,
and sensitive-data behavior in this document before an application uses them.

## Mapping to a deployment

Form values are not passed directly to Helm. The data flow is:

```text
values.form.json
  -> submitted form object
  -> graph.yaml ui.mapping
  -> typed graph parameters
  -> helm_chart values
  -> wrapper chart values
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
5. Every parameter that changes Helm values is explicitly mapped; arbitrary
   unreviewed Helm values are not accepted.

## Sensitive values

Sensitive fields must:

- use the `password` widget or another registered secret widget;
- have no committed default value;
- map to a graph parameter with `sensitive: true`;
- be redacted from logs, API responses, events, and deployment status;
- be transmitted only to the component that creates the Helm release.

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
- Run `./validate-applications.sh`.

The existing Headlamp, Argo CD, and MLflow packages are the canonical v1
examples.

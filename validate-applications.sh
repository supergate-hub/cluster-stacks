#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
applications=(headlamp argo-cd mlflow)
structure_only=false

if [[ "${1:-}" == "--structure-only" ]]; then
  structure_only=true
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--structure-only]" >&2
  exit 2
fi

for command in jq rg yq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "missing required command: $command" >&2
    exit 1
  fi
done

fail() {
  echo "$1" >&2
  exit 1
}

is_application_directory() {
  local directory_name="$1"
  local application

  for application in "${applications[@]}"; do
    if [[ "$directory_name" == "$application" ]]; then
      return 0
    fi
  done

  return 1
}

is_allowed_category() {
  local candidate="$1"
  local allowed_category

  for allowed_category in "${allowed_categories[@]}"; do
    if [[ "$candidate" == "$allowed_category" ]]; then
      return 0
    fi
  done

  return 1
}

validate_vendored_dependencies() {
  local application="$1"
  local chart_dir="$2"
  local dependency_count

  dependency_count="$(yq eval '.dependencies // [] | length' "$chart_dir/Chart.yaml")"
  if [[ "$dependency_count" == "0" ]]; then
    return
  fi

  if [[ ! -f "$chart_dir/Chart.lock" ]]; then
    fail "$application: chart dependencies require chart/Chart.lock"
  fi

  while IFS=$'\t' read -r dependency_name dependency_repository; do
    local locked_version
    local locked_repository
    local unpacked_chart
    local packaged_chart

    locked_version="$(DEPENDENCY_NAME="$dependency_name" yq eval -r \
      '.dependencies[] | select(.name == strenv(DEPENDENCY_NAME)) | .version' \
      "$chart_dir/Chart.lock")"
    locked_repository="$(DEPENDENCY_NAME="$dependency_name" yq eval -r \
      '.dependencies[] | select(.name == strenv(DEPENDENCY_NAME)) | .repository' \
      "$chart_dir/Chart.lock")"

    if [[ -z "$locked_version" || "$locked_version" == "null" ]]; then
      fail "$application: $dependency_name is missing from chart/Chart.lock"
    fi

    if [[ "$locked_repository" != "$dependency_repository" ]]; then
      fail "$application: $dependency_name repository differs between Chart.yaml and Chart.lock"
    fi

    unpacked_chart="$chart_dir/charts/$dependency_name/Chart.yaml"
    packaged_chart="$chart_dir/charts/$dependency_name-$locked_version.tgz"

    if [[ -f "$unpacked_chart" ]]; then
      local unpacked_name
      local unpacked_version

      unpacked_name="$(yq eval -r '.name' "$unpacked_chart")"
      unpacked_version="$(yq eval -r '.version' "$unpacked_chart")"
      if [[ "$unpacked_name" != "$dependency_name" ||
            "$unpacked_version" != "$locked_version" ]]; then
        fail "$application: unpacked $dependency_name does not match Chart.lock version $locked_version"
      fi
    elif [[ ! -f "$packaged_chart" ]]; then
      fail "$application: missing vendored dependency $dependency_name@$locked_version"
    fi
  done < <(yq eval -r '.dependencies[] | [.name, .repository] | @tsv' "$chart_dir/Chart.yaml")
}

mapped_parameter_for() {
  local graph_file="$1"
  local field_path="$2"

  FORM_FIELD_PATH="$field_path" yq eval -r \
    '.ui.mapping | to_entries | .[] | select(.value == strenv(FORM_FIELD_PATH)) | .key' \
    "$graph_file"
}

validate_form_security() {
  local application="$1"
  local package_dir="$2"
  local form_file="$package_dir/values.form.json"
  local graph_file="$package_dir/graph.yaml"

  while IFS=$'\x1f' read -r field_path has_default; do
    local parameter_name

    if [[ "$has_default" == "true" ]]; then
      fail "$application: password field $field_path must not have a committed default"
    fi

    parameter_name="$(mapped_parameter_for "$graph_file" "$field_path")"
    if [[ -z "$parameter_name" || "$parameter_name" == *$'\n'* ]]; then
      fail "$application: password field $field_path must map to exactly one graph parameter"
    fi

    if ! PARAMETER_NAME="$parameter_name" yq eval --exit-status \
      '.parameters[strenv(PARAMETER_NAME)].type == "string" and
       .parameters[strenv(PARAMETER_NAME)].sensitive == true' \
      "$graph_file" >/dev/null; then
      fail "$application: password parameter $parameter_name must be a sensitive string"
    fi
  done < <(jq -r '
    paths(objects) as $path
    | getpath($path) as $field
    | select($field.viewSpec?.type? == "password")
    | [
        ($path | map(select(. != "properties")) | join(".")),
        ($field | has("defaultValue") | tostring)
      ]
    | join("\u001f")
  ' "$form_file")

  while IFS=$'\x1f' read -r field_path source_path edit_mode; do
    local parameter_name
    local raw_values_reference
    local expected_reference

    if [[ "$source_path" != "chart/values.yaml" ]]; then
      fail "$application: YAML editor $field_path must use chart/values.yaml as its source"
    fi

    if [[ ! -f "$package_dir/$source_path" ]]; then
      fail "$application: YAML editor source does not exist: $source_path"
    fi

    if [[ "$edit_mode" != "overrides" ]]; then
      fail "$application: YAML editor $field_path must use override mode"
    fi

    parameter_name="$(mapped_parameter_for "$graph_file" "$field_path")"
    if [[ -z "$parameter_name" || "$parameter_name" == *$'\n'* ]]; then
      fail "$application: YAML editor $field_path must map to exactly one graph parameter"
    fi

    if ! PARAMETER_NAME="$parameter_name" yq eval --exit-status \
      '.parameters[strenv(PARAMETER_NAME)].type == "string" and
       .parameters[strenv(PARAMETER_NAME)].sensitive == true' \
      "$graph_file" >/dev/null; then
      fail "$application: YAML override parameter $parameter_name must be a sensitive string"
    fi

    raw_values_reference="$(yq eval -r '.components.helmRelease.spec.rawValues' "$graph_file")"
    expected_reference="\${{ .parameters.${parameter_name} }}"
    if [[ "$raw_values_reference" != "$expected_reference" ]]; then
      fail "$application: helmRelease.spec.rawValues must consume parameter $parameter_name"
    fi
  done < <(jq -r '
    paths(objects) as $path
    | getpath($path) as $field
    | select($field.viewSpec?.type? == "yaml_input")
    | [
        ($path | map(select(. != "properties")) | join(".")),
        ($field.viewSpec.inputProps.sourcePath // ""),
        ($field.viewSpec.inputProps.editMode // "")
      ]
    | join("\u001f")
  ' "$form_file")
}

jq empty "$repo_root/application-manifest.schema.json"

allowed_categories=()
while IFS= read -r category; do
  allowed_categories+=("$category")
done < <(jq -r '.properties.categories.items.oneOf[].const' \
  "$repo_root/application-manifest.schema.json")

minimum_categories="$(jq -r '.properties.categories.minItems' \
  "$repo_root/application-manifest.schema.json")"
maximum_categories="$(jq -r '.properties.categories.maxItems' \
  "$repo_root/application-manifest.schema.json")"

for top_level_directory in "$repo_root"/*/; do
  directory_name="$(basename "$top_level_directory")"
  if ! is_application_directory "$directory_name"; then
    fail "unexpected top-level directory: $directory_name"
  fi
done

required_files=(
  manifest.yaml
  README.md
  values.form.json
  graph.yaml
  licenses.yaml
  chart/Chart.yaml
  chart/values.yaml
)

required_sections=(
  Description
  "Short description"
  Tutorial
  Usage
  "Use cases"
  Links
  Support
  Legal
)

for application in "${applications[@]}"; do
  package_dir="$repo_root/$application"

  for relative_path in "${required_files[@]}"; do
    if [[ ! -f "$package_dir/$relative_path" ]]; then
      fail "$application: missing $relative_path"
    fi
  done

  jq empty "$package_dir/values.form.json"
  yq eval '.' "$package_dir/manifest.yaml" >/dev/null
  yq eval '.' "$package_dir/graph.yaml" >/dev/null
  yq eval '.' "$package_dir/licenses.yaml" >/dev/null
  yq eval '.' "$package_dir/chart/Chart.yaml" >/dev/null
  yq eval '.' "$package_dir/chart/values.yaml" >/dev/null

  if ! yq eval --exit-status '
    .content.description == "README.md" and
    .content.form == "values.form.json" and
    .content.deployment == "graph.yaml" and
    .content.licenses == "licenses.yaml" and
    .artifacts.chartPath == "chart"
  ' "$package_dir/manifest.yaml" >/dev/null; then
    fail "$application: manifest content references do not match the package contract"
  fi

  manifest_slug="$(yq eval -r '.slug' "$package_dir/manifest.yaml")"
  if [[ "$manifest_slug" != "$application" ]]; then
    fail "$application: manifest slug must match its directory"
  fi

  category_count="$(yq eval '.categories | length' "$package_dir/manifest.yaml")"
  if (( category_count < minimum_categories || category_count > maximum_categories )); then
    fail "$application: categories must contain between $minimum_categories and $maximum_categories entries"
  fi

  seen_categories="|"
  while IFS= read -r category; do
    if ! is_allowed_category "$category"; then
      fail "$application: unsupported category: $category"
    fi
    if [[ "$seen_categories" == *"|$category|"* ]]; then
      fail "$application: duplicate category: $category"
    fi
    seen_categories="${seen_categories}${category}|"
  done < <(yq eval -r '.categories[]' "$package_dir/manifest.yaml")

  manifest_chart_version="$(yq eval -r '.artifacts.chartVersion' "$package_dir/manifest.yaml")"
  chart_version="$(yq eval -r '.version' "$package_dir/chart/Chart.yaml")"
  if [[ "$manifest_chart_version" != "$chart_version" ]]; then
    fail "$application: manifest and root chart versions must match"
  fi

  manifest_application_version="$(yq eval -r '.artifacts.applicationVersion' "$package_dir/manifest.yaml")"
  chart_application_version="$(yq eval -r '.appVersion' "$package_dir/chart/Chart.yaml")"
  if [[ "$manifest_application_version" != "$chart_application_version" ]]; then
    fail "$application: manifest and root chart application versions must match"
  fi

  validate_vendored_dependencies "$application" "$package_dir/chart"
  validate_form_security "$application" "$package_dir"

  for section in "${required_sections[@]}"; do
    if ! rg --quiet "^## ${section}$" "$package_dir/README.md"; then
      fail "$application: README is missing the '$section' section"
    fi
  done

  if ! rg --quiet '^### Key features$' "$package_dir/README.md"; then
    fail "$application: README is missing the 'Key features' subsection"
  fi

  echo "$application: structure valid"
done

if [[ "$structure_only" == true ]]; then
  exit 0
fi

if ! command -v helm >/dev/null 2>&1; then
  fail "missing required command: helm"
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

export HELM_CONFIG_HOME="$temporary_dir/helm/config"
export HELM_CACHE_HOME="$temporary_dir/helm/cache"
export HELM_DATA_HOME="$temporary_dir/helm/data"

for application in "${applications[@]}"; do
  chart_dir="$repo_root/$application/chart"
  dependency_output="$(helm dependency list "$chart_dir")"
  if printf '%s\n' "$dependency_output" | rg --quiet '(missing|wrong version)'; then
    printf '%s\n' "$dependency_output" >&2
    fail "$application: vendored chart dependencies are incomplete"
  fi

  helm lint --with-subcharts "$chart_dir"

  template_arguments=()
  case "$application" in
    headlamp)
      template_arguments+=(
        --set-string headlamp.clusterRoleBinding.clusterRoleName=view
      )
      ;;
    argo-cd)
      template_arguments+=(
        --set-string adminPassword=validation-password
        --set notifications.enabled=false
      )
      ;;
    mlflow)
      template_arguments+=(
        --set auth.enabled=true
        --set-string auth.adminUsername=admin
        --set-string auth.adminPassword=validation-password
        --set-string postgresql.primary.persistence.size=8Gi
        --set-string minio.persistence.size=20Gi
      )
      ;;
  esac

  helm template "$application" "$chart_dir" \
    --namespace "$application" \
    "${template_arguments[@]}" >/dev/null
  echo "$application: chart valid"
done

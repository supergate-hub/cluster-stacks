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

jq empty "$repo_root/application-manifest.schema.json"

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
      echo "$application: missing $relative_path" >&2
      exit 1
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
    echo "$application: manifest content references do not match the package contract" >&2
    exit 1
  fi

  manifest_slug="$(yq eval -r '.slug' "$package_dir/manifest.yaml")"
  if [[ "$manifest_slug" != "$application" ]]; then
    echo "$application: manifest slug must match its directory" >&2
    exit 1
  fi

  manifest_chart_version="$(yq eval -r '.artifacts.chartVersion' "$package_dir/manifest.yaml")"
  wrapper_chart_version="$(yq eval -r '.version' "$package_dir/chart/Chart.yaml")"
  dependency_chart_version="$(yq eval -r '.dependencies[0].version' "$package_dir/chart/Chart.yaml")"
  if [[ "$manifest_chart_version" != "$wrapper_chart_version" ||
        "$manifest_chart_version" != "$dependency_chart_version" ]]; then
    echo "$application: manifest, wrapper, and dependency chart versions must match" >&2
    exit 1
  fi

  manifest_application_version="$(yq eval -r '.artifacts.applicationVersion' "$package_dir/manifest.yaml")"
  wrapper_application_version="$(yq eval -r '.appVersion' "$package_dir/chart/Chart.yaml")"
  if [[ "$manifest_application_version" != "$wrapper_application_version" ]]; then
    echo "$application: manifest and wrapper application versions must match" >&2
    exit 1
  fi

  for section in "${required_sections[@]}"; do
    if ! rg --quiet "^## ${section}$" "$package_dir/README.md"; then
      echo "$application: README is missing the '$section' section" >&2
      exit 1
    fi
  done

  if ! rg --quiet '^### Key features$' "$package_dir/README.md"; then
    echo "$application: README is missing the 'Key features' subsection" >&2
    exit 1
  fi

  echo "$application: structure valid"
done

if [[ "$structure_only" == true ]]; then
  exit 0
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "missing required command: helm" >&2
  exit 1
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

export HELM_CONFIG_HOME="$temporary_dir/helm/config"
export HELM_CACHE_HOME="$temporary_dir/helm/cache"
export HELM_DATA_HOME="$temporary_dir/helm/data"

helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ >/dev/null
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo add community https://community-charts.github.io/helm-charts >/dev/null
helm repo update >/dev/null

for application in "${applications[@]}"; do
  package_copy="$temporary_dir/$application"
  cp -R "$repo_root/$application" "$package_copy"
  helm dependency update --skip-refresh "$package_copy/chart" >/dev/null
  helm lint "$package_copy/chart"

  template_arguments=()
  case "$application" in
    headlamp)
      template_arguments+=(
        --set-string headlamp.clusterRoleBinding.clusterRoleName=view
      )
      ;;
    argo-cd)
      template_arguments+=(
        --set argo-cd.applicationSet.enabled=true
        --set argo-cd.notifications.enabled=false
      )
      ;;
    mlflow)
      template_arguments+=(
        --set mlflow.auth.enabled=true
        --set-string mlflow.auth.adminUsername=admin
        --set-string mlflow.auth.adminPassword=validation-password
        --set-string mlflow.postgresql.primary.persistence.size=8Gi
        --set-string mlflow.minio.persistence.size=20Gi
      )
      ;;
  esac

  helm template "$application" "$package_copy/chart" \
    --namespace "$application" \
    "${template_arguments[@]}" >/dev/null
  echo "$application: chart valid"
done

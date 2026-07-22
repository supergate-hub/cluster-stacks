#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: publish_catalog_release.sh --release-dir DIR --catalog-ref OCI_REF [--validate-only] [--immutable-tags-confirmed]

The release must already be compiled with --signing-key. Helm and cosign publish
each chart by its immutable version; oras and cosign publish the catalog archive.
Registry authentication is intentionally inherited from the standard Helm/ORAS/
Cosign credential stores and is never accepted on this command line. Set
COSIGN_KEY_REF to a file, KMS URI, or env:// reference for the public-key
signature that Sveltos verifies; COSIGN_PASSWORD may be supplied separately.

Production publication requires --immutable-tags-confirmed. This is an explicit
deployment assertion that the Harbor chart and catalog repositories reject tag
replacement.
EOF
  exit 2
}

release_dir=""
catalog_ref=""
validate_only=false
immutable_tags_confirmed=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-dir) release_dir="${2:-}"; shift 2 ;;
    --catalog-ref) catalog_ref="${2:-}"; shift 2 ;;
    --validate-only) validate_only=true; shift ;;
    --immutable-tags-confirmed) immutable_tags_confirmed=true; shift ;;
    *) usage ;;
  esac
done

[[ -n "$release_dir" && -n "$catalog_ref" ]] || usage
[[ -f "$release_dir/catalog.json" && -f "$release_dir/release.json" ]] || {
  echo "release directory is missing catalog.json or release.json" >&2
  exit 1
}

for command in jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "missing required command: $command" >&2
    exit 1
  }
done

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

jq -e '
  .schemaVersion == 1 and
  .releaseMode == "oci" and
  (.catalogDigest | startswith("sha256:"))
' "$release_dir/catalog.json" >/dev/null
jq -e '
  .signature.algorithm == "Ed25519" and
  (.signature.keyID | length > 0) and
  (.signature.value | length > 0)
' "$release_dir/catalog.json" >/dev/null || {
  echo "production publication requires an embedded Ed25519 catalog signature" >&2
  exit 1
}

while IFS=$'\t' read -r path expected; do
  actual="$(sha256_file "$release_dir/$path")"
  [[ "$actual" == "$expected" ]] || {
    echo "release checksum mismatch: $path" >&2
    exit 1
  }
done < <(jq -r '.files[] | [.path, .sha256] | @tsv' "$release_dir/release.json")

if [[ "$validate_only" == true ]]; then
  echo "catalog release is signed and internally consistent"
  exit 0
fi

[[ "$immutable_tags_confirmed" == true ]] || {
  echo "production publication requires --immutable-tags-confirmed" >&2
  exit 1
}

for command in helm oras cosign; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "missing required publication command: $command" >&2
    exit 1
  }
done
: "${COSIGN_KEY_REF:?COSIGN_KEY_REF is required for public-key Cosign signatures}"

while IFS=$'\t' read -r archive repository name version expected_digest; do
  [[ "$repository" == oci://* ]] || {
    echo "chart repository must use oci://: $repository" >&2
    exit 1
  }
  helm push "$release_dir/$archive" "$repository"
  chart_ref="${repository#oci://}/$name:$version"
  actual_layer_digest="$(oras manifest fetch "$chart_ref" | jq -r --arg media "application/vnd.cncf.helm.chart.content.v1.tar+gzip" '[.layers[] | select(.mediaType == $media)] | if length == 1 then .[0].digest else empty end')"
  [[ "$actual_layer_digest" == "$expected_digest" ]] || {
    echo "published Helm content digest mismatch: $chart_ref" >&2
    exit 1
  }
  chart_manifest_digest="$(oras manifest fetch --descriptor "$chart_ref" | jq -r '.digest')"
  [[ "$chart_manifest_digest" == sha256:* ]] || {
    echo "could not resolve immutable chart manifest digest: $chart_ref" >&2
    exit 1
  }
  # Sign the immutable repository digest, not the mutable tag spelling used to
  # discover it. Removing only the final colon suffix keeps registry ports
  # intact (for example harbor.example:8443/launcher/charts/headlamp).
  chart_digest_ref="${chart_ref%:*}@$chart_manifest_digest"
  cosign sign --yes --key "$COSIGN_KEY_REF" "$chart_digest_ref"
done < <(jq -r '.applications[].chart | [.archive, .repositoryURL, .name, .version, .digest] | @tsv' "$release_dir/catalog.json")

normalized_catalog_ref="${catalog_ref#oci://}"
artifact_path="$(jq -r '.artifact.path' "$release_dir/release.json")"
artifact_media_type="$(jq -r '.artifact.mediaType' "$release_dir/release.json")"
oras push "$normalized_catalog_ref" \
  --artifact-type application/vnd.supergate.application-catalog.v1 \
  "$release_dir/$artifact_path:$artifact_media_type"
catalog_manifest_digest="$(oras manifest fetch --descriptor "$normalized_catalog_ref" | jq -r '.digest')"
[[ "$catalog_manifest_digest" == sha256:* ]] || {
  echo "could not resolve immutable catalog manifest digest: $normalized_catalog_ref" >&2
  exit 1
}
catalog_digest_ref="${normalized_catalog_ref%:*}@$catalog_manifest_digest"
cosign sign --yes --key "$COSIGN_KEY_REF" "$catalog_digest_ref"

echo "published signed catalog release: $normalized_catalog_ref"

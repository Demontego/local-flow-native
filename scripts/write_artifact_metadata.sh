#!/usr/bin/env bash
set -euo pipefail

artifact="${1:?usage: write_artifact_metadata.sh <artifact> <output-dir>}"
output_dir="${2:?usage: write_artifact_metadata.sh <artifact> <output-dir>}"
mkdir -p "$output_dir"

name="$(basename "$artifact")"
version="$(git describe --tags --always --dirty)"
checksum="$(shasum -a 256 "$artifact" | awk '{print $1}')"

printf '%s  %s\n' "$checksum" "$name" > "$output_dir/$name.sha256"
cargo metadata --format-version 1 --no-deps > "$output_dir/rust-sbom.json"
printf '{"artifact":"%s","version":"%s","sha256":"%s"}\n' \
  "$name" "$version" "$checksum" > "$output_dir/$name.metadata.json"

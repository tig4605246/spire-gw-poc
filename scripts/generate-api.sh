#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
source versions.env

# `go run module@version` keeps the generator pinned without checking a binary
# into the repository or coupling generator dependencies to controller runtime.
# controller-gen intentionally skips methods already present in the package;
# remove only its known output so repeated generation cannot preserve stale code.
rm -f "$ROOT/api/v1alpha1/zz_generated.deepcopy.go"
go run "sigs.k8s.io/controller-tools/cmd/controller-gen@${CONTROLLER_GEN_VERSION}" \
  object:headerFile=/dev/null \
  paths=./api/v1alpha1
go run "sigs.k8s.io/controller-tools/cmd/controller-gen@${CONTROLLER_GEN_VERSION}" \
  crd:crdVersions=v1 \
  paths=./api/v1alpha1 \
  output:crd:dir=config/crd

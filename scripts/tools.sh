#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/versions.env"

case "$(uname -s)" in Linux) os=linux ;; *) printf 'only Linux is supported by this POC tool bootstrap\n' >&2; exit 1 ;; esac
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) printf 'unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;; esac
for command in curl sha256sum tar; do
  command -v "$command" >/dev/null || { printf 'missing required command: %s\n' "$command" >&2; exit 1; }
done

tools_dir="$repo_root/.tools"
bin_dir="$tools_dir/bin"
mkdir -p "$bin_dir"
temp_dir="$(mktemp -d "$tools_dir/download.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

download_verified() {
  local url="$1" checksum_url="$2" archive="$3" checksum expected
  checksum="$temp_dir/checksum"
  curl --fail --location --retry 3 --silent --show-error "$checksum_url" -o "$checksum"
  expected="$(awk 'NR == 1 { print $1 }' "$checksum")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || { printf 'invalid SHA-256 at %s\n' "$checksum_url" >&2; exit 1; }
  curl --fail --location --retry 3 --silent --show-error "$url" -o "$archive"
  printf '%s  %s\n' "$expected" "$archive" | sha256sum --check --status - || { printf 'checksum mismatch for %s\n' "$url" >&2; exit 1; }
}

if [[ ! -x "$bin_dir/kind" ]] || ! "$bin_dir/kind" version 2>/dev/null | grep -Fq "v${KIND_VERSION#v}"; then
  archive="$temp_dir/kind-$os-$arch"
  base="kind-$os-$arch"
  download_verified "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/${base}" "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/${base}.sha256sum" "$archive"
  install -m 0755 "$archive" "$bin_dir/kind"
fi

helm_base="helm-${HELM_VERSION}-${os}-${arch}"
if [[ ! -x "$bin_dir/helm" ]] || ! "$bin_dir/helm" version --short 2>/dev/null | grep -Fq "$HELM_VERSION"; then
  archive="$temp_dir/$helm_base.tar.gz"
  download_verified "https://get.helm.sh/${helm_base}.tar.gz" "https://get.helm.sh/${helm_base}.tar.gz.sha256sum" "$archive"
  tar -xzf "$archive" -C "$temp_dir"
  install -m 0755 "$temp_dir/$os-$arch/helm" "$bin_dir/helm"
fi

istio_base="istio-${ISTIO_VERSION}-${os}-${arch}"
if [[ ! -x "$bin_dir/istioctl" ]] || ! "$bin_dir/istioctl" version --remote=false 2>/dev/null | grep -Fq "$ISTIO_VERSION"; then
  archive="$temp_dir/$istio_base.tar.gz"
  download_verified "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/${istio_base}.tar.gz" "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/${istio_base}.tar.gz.sha256" "$archive"
  tar -xzf "$archive" -C "$temp_dir"
  install -m 0755 "$temp_dir/istio-${ISTIO_VERSION}/bin/istioctl" "$bin_dir/istioctl"
fi

printf 'installed pinned tools in %s\n' "$bin_dir"

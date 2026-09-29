#!/usr/bin/env bash
# Publish owlpane-agent Helm chart to GHCR (version from Chart.yaml).
# Requires: gh auth login, helm 3 with OCI support.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(awk '/^version:/{print $2}' Chart.yaml | tr -d '"')"
CHART_TGZ="owlpane-agent-${VERSION}.tgz"

echo "==> lint + package owlpane-agent ${VERSION}"
helm lint .
helm package .

OWNER="$(gh api user -q .login)"
TOKEN="$(gh auth token)"
echo "==> GHCR login (${OWNER})"
echo "$TOKEN" | helm registry login ghcr.io -u "$OWNER" --password-stdin

echo "==> push ${CHART_TGZ}"
helm push "${CHART_TGZ}" "oci://ghcr.io/${OWNER}"

TAG="agent-v${VERSION}"
git tag -f -a "${TAG}" -m "owlpane-agent Helm chart ${VERSION}"
echo "==> pushed oci://ghcr.io/${OWNER}/owlpane-agent:${VERSION}"
echo "Optional: git push origin -f ${TAG}"

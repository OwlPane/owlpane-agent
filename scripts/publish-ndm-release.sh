#!/usr/bin/env bash
# One-shot publish for owlpane-agent 0.2.0 + ndm/flow images 0.1.0.
# Requires: gh auth login, docker buildx, helm 3.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OWNER="$(gh api user -q .login)"
TOKEN="$(gh auth token)"

echo "==> tests"
bash scripts/test-ndm.sh
go test ./... -C docker/flow
helm lint .

echo "==> GHCR login"
echo "$TOKEN" | docker login ghcr.io -u "$OWNER" --password-stdin
echo "$TOKEN" | helm registry login ghcr.io -u "$OWNER" --password-stdin

echo "==> images"
docker buildx build --platform linux/amd64,linux/arm64 \
  -t "ghcr.io/${OWNER}/owlpane-ndm:0.1.0" -t "ghcr.io/${OWNER}/owlpane-ndm:latest" \
  --push docker/ndm
docker buildx build --platform linux/amd64,linux/arm64 \
  -t "ghcr.io/${OWNER}/owlpane-ndm-flow:0.1.0" -t "ghcr.io/${OWNER}/owlpane-ndm-flow:latest" \
  --push docker/flow

echo "==> chart"
helm package .
helm push "owlpane-agent-0.2.0.tgz" "oci://ghcr.io/${OWNER}"

echo "==> git tags (triggers CI publish workflows on future pushes)"
git tag -f -a agent-v0.2.0 -m "owlpane-agent Helm chart 0.2.0"
git tag -f -a ndm-v0.1.0 -m "owlpane-ndm image 0.1.0"
git tag -f -a ndm-flow-v0.1.0 -m "owlpane-ndm-flow image 0.1.0"
git push origin main
git push origin -f agent-v0.2.0 ndm-v0.1.0 ndm-flow-v0.1.0

echo "DONE: ghcr.io/${OWNER}/owlpane-agent:0.2.0, owlpane-ndm:0.1.0, owlpane-ndm-flow:0.1.0"

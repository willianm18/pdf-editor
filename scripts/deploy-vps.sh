#!/bin/bash
# Rebuild the web app image from the latest deploy-clean commit and redeploy
# it on the VPS. Run this ON THE VPS (as root), after pushing changes to
# deploy-clean from your machine.
#
# Usage: bash deploy-vps.sh
#
# What it does:
#   1. Pulls the latest deploy-clean into the local clone.
#   2. Rebuilds + pushes the stirling-pdf-rembg image to GHCR.
#   3. Pulls that image into the Coolify-managed service and recreates the
#      stirling-pdf container (a plain `restart` does NOT pick up a new
#      image — the container must be recreated).
#
# REPO_DIR / SERVICE_DIR are specific to this VPS instance. If SERVICE_DIR
# ever stops existing (e.g. the service was recreated in Coolify with a new
# UUID), find the new one with:
#   grep -rl "stirling-pdf-rembg" /data/coolify --include="docker-compose*.yml"

set -euo pipefail

REPO_DIR="/tmp/pdf-editor"
SERVICE_DIR="/data/coolify/services/l1icq3ewesxof80w6tswg3zh"
BRANCH="deploy-clean"
IMAGE="ghcr.io/willianm18/stirling-pdf-rembg:latest"

echo "==> Pulling latest ${BRANCH}"
cd "${REPO_DIR}"
git fetch origin
git checkout "${BRANCH}"
git pull origin "${BRANCH}"
git log -1 --oneline

echo "==> Building ${IMAGE}"
docker build -t "${IMAGE}" -f docker/embedded/Dockerfile .

echo "==> Pushing ${IMAGE}"
docker push "${IMAGE}"

echo "==> Redeploying on Coolify (${SERVICE_DIR})"
cd "${SERVICE_DIR}"
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d --force-recreate stirling-pdf

echo "==> Done. Check https://pdf.willianramthun.store"

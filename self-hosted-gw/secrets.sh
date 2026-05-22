#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# API Platform Gateway — Production Secrets Setup
#
# Creates all Kubernetes Secrets required by values.yaml.
# Run this once before `helm install`, and again after rotating any credential.
#
# Usage:
#   export NAMESPACE=ap-gateway
#   bash kubernetes/production/secrets.sh
#
# Each secret is created with --dry-run=client -o yaml | kubectl apply -f -
# so re-running is idempotent (updates existing secrets in place).
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

NAMESPACE="${NAMESPACE:-ap-gateway}"

echo "Creating secrets in namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ── 1. Encryption key ─────────────────────────────────────────────────────────
# AES-GCM 256-bit key required by the controller to encrypt secrets at rest.
# Keep the generated .bin file offline after creating the secret.
echo ""
echo "[1/4] Encryption key (gateway-encryption-keys)"

if [ ! -f "./default-aesgcm256-v1.bin" ]; then
  openssl rand -out ./default-aesgcm256-v1.bin 32
  echo "  Generated new AES-GCM key: ./default-aesgcm256-v1.bin"
  echo "  Store this file in a secure offline location and delete it from this machine."
else
  echo "  Using existing ./default-aesgcm256-v1.bin"
fi

kubectl create secret generic gateway-encryption-keys \
  --namespace "$NAMESPACE" \
  --from-file=default-aesgcm256-v1.bin=./default-aesgcm256-v1.bin \
  --dry-run=client -o yaml | kubectl apply -f -

# ── 2. Admin credentials (basic auth) ─────────────────────────────────────────
# Only needed when using basic auth (config.controller.auth.basic.enabled=true).
# The plain password is stored here for team reference and rotation.
# The bcrypt HASH (not the plain password) goes into values.yaml.
echo ""
echo "[2/4] Admin credentials (gateway-admin-credentials)"
echo "  This secret stores the plain password for rotation reference only."
echo "  Copy the bcrypt hash printed below into values.yaml."
echo ""

ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
if [ -z "$ADMIN_PASSWORD" ]; then
  echo "  ADMIN_PASSWORD is not set. Set it before running:"
  echo "    export ADMIN_PASSWORD='your-secure-password'"
  echo "  Skipping gateway-admin-credentials secret."
else
  kubectl create secret generic gateway-admin-credentials \
    --namespace "$NAMESPACE" \
    --from-literal=username=admin \
    --from-literal=password="$ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo ""
  echo "  Bcrypt hash for values.yaml:"
  if command -v htpasswd &>/dev/null; then
    htpasswd -nbB admin "$ADMIN_PASSWORD" | cut -d: -f2
  else
    docker run --rm httpd:alpine htpasswd -nbB admin "$ADMIN_PASSWORD" | cut -d: -f2
  fi
  echo ""
  echo "  Set this hash in values-production.yaml:"
  echo "    gateway.config.controller.auth.basic.users[0].password"
fi

# ── 3. PostgreSQL password ────────────────────────────────────────────────────
echo ""
echo "[3/4] PostgreSQL password (gateway-postgres-password)"

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
if [ -z "$POSTGRES_PASSWORD" ]; then
  echo "  POSTGRES_PASSWORD is not set. Set it before running:"
  echo "    export POSTGRES_PASSWORD='your-db-password'"
  echo "  Skipping gateway-postgres-password secret."
else
  kubectl create secret generic gateway-postgres-password \
    --namespace "$NAMESPACE" \
    --from-literal=password="$POSTGRES_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  Created gateway-postgres-password"
fi

# ── 4. Control plane token ────────────────────────────────────────────────────
echo ""
echo "[4/4] Control plane registration token (gateway-cp-token)"

CP_TOKEN="${CP_TOKEN:-}"
if [ -z "$CP_TOKEN" ]; then
  echo "  CP_TOKEN is not set. Set it before running:"
  echo "    export CP_TOKEN='your-control-plane-token'"
  echo "  Skipping gateway-cp-token secret."
else
  kubectl create secret generic gateway-cp-token \
    --namespace "$NAMESPACE" \
    --from-literal=token="$CP_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  Created gateway-cp-token"
fi

echo ""
echo "Done. Verify secrets:"
echo "  kubectl get secrets -n $NAMESPACE"

#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# API Platform Gateway — Production Secrets Setup
#
# Creates ALL Kubernetes Secrets required by values.yaml:
#   1. gateway-encryption-keys        AES-GCM 256-bit key for data-at-rest
#   2. gateway-admin-credentials      Plain admin password (rotation reference)
#   3. gateway-postgres-password      PostgreSQL password
#   4. gateway-cp-token               Control plane registration token
#   5. gateway-tls                    TLS cert + key for the controller
#   6. apim-oauth-client-secret-secret  APIM OAuth2 client credentials
#
# Run once before `helm install`, and again after rotating any credential.
# Each secret uses --dry-run=client | kubectl apply — idempotent on re-run.
#
# ── Quick start ───────────────────────────────────────────────────────────────
#
#   Option A — Export variables then run (non-interactive, good for CI):
#
#     export NAMESPACE=ap-gateway
#     export ADMIN_PASSWORD='YourSecureAdminPassword'
#     export POSTGRES_PASSWORD='YourDBPassword'
#     export CP_TOKEN='YourControlPlaneToken'
#     export TLS_CERT_PATH=./gateway.crt
#     export TLS_KEY_PATH=./gateway.key
#     export APIM_CLIENT_ID='YourOAuthClientId'
#     export APIM_CLIENT_SECRET='YourOAuthClientSecret'
#     bash secrets.sh
#
#   Option B — Run interactively (prompts for any unset variable):
#
#     bash secrets.sh
#
#   Skip TLS secret if you are using cert-manager to issue certificates:
#
#     export SKIP_TLS=true
#     bash secrets.sh
#
# ── After running ─────────────────────────────────────────────────────────────
#   • The script prints the bcrypt hash — paste it into values.yaml
#   • A Key Vault table is printed at the end for manual vault entry
#   • Follow the values.yaml checklist printed at the end
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Terminal colours ──────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
  CYN='\033[0;36m'; BOLD='\033[1m';   NC='\033[0m'
else
  RED=''; YEL=''; GRN=''; CYN=''; BOLD=''; NC=''
fi

section() { echo -e "\n${BOLD}── $* ──${NC}"; }
info()    { echo -e "${CYN}  ▶  $*${NC}"; }
ok()      { echo -e "${GRN}  ✓  $*${NC}"; }
warn()    { echo -e "${YEL}  ⚠  $*${NC}"; }
fatal()   { echo -e "${RED}  ✗  $*${NC}" >&2; exit 1; }

# ── Interactive prompts ───────────────────────────────────────────────────────
# Usage: prompt_val  VAR_NAME "Prompt text" [default]
# Usage: prompt_secret VAR_NAME "Prompt text"
# If the variable is already set (exported) the prompt is skipped.

prompt_val() {
  local var="$1" prompt="$2" default="${3:-}"
  [[ -n "${!var:-}" ]] && return
  if [[ -t 0 ]]; then
    local val
    read -rp "  ${prompt}${default:+ [${default}]}: " val
    printf -v "$var" '%s' "${val:-${default}}"
  else
    [[ -n "$default" ]] && printf -v "$var" '%s' "$default" \
      || fatal "${var} is not set and stdin is not a terminal. Export it before running."
  fi
}

prompt_secret() {
  local var="$1" prompt="$2"
  [[ -n "${!var:-}" ]] && return
  if [[ -t 0 ]]; then
    local val
    read -rsp "  ${prompt}: " val; echo
    printf -v "$var" '%s' "$val"
  else
    fatal "${var} is not set and stdin is not a terminal. Export it before running."
  fi
}

# ── Collect inputs ────────────────────────────────────────────────────────────
echo -e "\n${BOLD}=== API Platform Gateway — Production Secret Setup ===${NC}"
echo "  Unset variables will be prompted below."
echo "  Press Ctrl-C to abort at any time."

NAMESPACE="${NAMESPACE:-}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
TLS_CERT_PATH="${TLS_CERT_PATH:-}"
TLS_KEY_PATH="${TLS_KEY_PATH:-}"
SKIP_TLS="${SKIP_TLS:-false}"   # set to 'true' when using cert-manager
# APIM connection — used to auto-fetch client credentials and CP token via API
APIM_HOST="${APIM_HOST:-}"         # e.g. https://apim.example.com:9443
APIM_ADMIN_USER="${APIM_ADMIN_USER:-admin}"
APIM_ADMIN_PASS="${APIM_ADMIN_PASS:-}"
# Override: export these to skip the APIM API calls and supply values directly
APIM_CLIENT_ID="${APIM_CLIENT_ID:-}"
APIM_CLIENT_SECRET="${APIM_CLIENT_SECRET:-}"
CP_TOKEN="${CP_TOKEN:-}"

prompt_val    NAMESPACE          "Kubernetes namespace"             "ap-gateway"
prompt_secret ADMIN_PASSWORD     "Gateway admin password           (blank to skip)"
prompt_secret POSTGRES_PASSWORD  "PostgreSQL password              (blank to skip)"

if [[ "$SKIP_TLS" != "true" ]]; then
  prompt_val  TLS_CERT_PATH  "Path to TLS certificate file (blank to skip)" ""
  prompt_val  TLS_KEY_PATH   "Path to TLS private key file  (blank to skip)" ""
fi

echo ""
echo "  Provide the APIM control plane host to auto-fetch OAuth2 client credentials"
echo "  and the CP token via API calls. Leave blank to enter them manually instead."
prompt_val APIM_HOST "APIM host URL, e.g. https://apim.example.com:9443  (blank to skip)" ""

if [[ -n "$APIM_HOST" ]]; then
  prompt_val    APIM_ADMIN_USER "APIM admin username" "admin"
  prompt_secret APIM_ADMIN_PASS "APIM admin password"
else
  # Manual fallback when no APIM host is given
  prompt_val    APIM_CLIENT_ID     "APIM OAuth2 client ID     (blank to skip)" ""
  prompt_secret APIM_CLIENT_SECRET "APIM OAuth2 client secret (blank to skip)"
  prompt_secret CP_TOKEN           "Control plane token        (blank to skip)"
fi

CREATE_TLS=false
if [[ "$SKIP_TLS" != "true" && -n "$TLS_CERT_PATH" && -n "$TLS_KEY_PATH" ]]; then
  [[ -f "$TLS_CERT_PATH" ]] || fatal "TLS_CERT_PATH file not found: $TLS_CERT_PATH"
  [[ -f "$TLS_KEY_PATH"  ]] || fatal "TLS_KEY_PATH file not found: $TLS_KEY_PATH"
  CREATE_TLS=true
fi

CREATE_APIM_OAUTH=false
[[ -n "$APIM_CLIENT_ID" && -n "$APIM_CLIENT_SECRET" ]] && CREATE_APIM_OAUTH=true

# ── APIM Bootstrap ────────────────────────────────────────────────────────────
# Calls DCR to register an OAuth2 client (→ APIM_CLIENT_ID, APIM_CLIENT_SECRET)
# then calls the token endpoint to get an access token (→ CP_TOKEN).
# Skipped when APIM_HOST is blank or when the target vars are already exported.
if [[ -n "$APIM_HOST" ]]; then
  section "APIM Bootstrap  →  DCR registration + CP token fetch"

  APIM_HOST="${APIM_HOST%/}"  # strip trailing slash

  command -v jq   &>/dev/null || fatal "jq is required for JSON parsing.  Install: brew install jq"
  command -v curl &>/dev/null || fatal "curl is required."

  # ── Step 1: DCR — register an OAuth2 client ────────────────────────────────
  if [[ -n "$APIM_CLIENT_ID" && -n "$APIM_CLIENT_SECRET" ]]; then
    info "APIM_CLIENT_ID already set — skipping DCR registration."
  else
    info "POST ${APIM_HOST}/client-registration/v0.17/register"
    DCR_RESPONSE=$(curl -sk -X POST "${APIM_HOST}/client-registration/v0.17/register" \
      -H "Content-Type: application/json" \
      -u "${APIM_ADMIN_USER}:${APIM_ADMIN_PASS}" \
      -d "{
        \"clientName\": \"gateway-controller\",
        \"owner\": \"${APIM_ADMIN_USER}\",
        \"grantType\": \"client_credentials password refresh_token\",
        \"saasApp\": true
      }") || fatal "curl failed — check that APIM_HOST is reachable."

    DCR_ERROR=$(echo "$DCR_RESPONSE" | jq -r '.error // empty' 2>/dev/null || true)
    if [[ -n "$DCR_ERROR" ]]; then
      DCR_DESC=$(echo "$DCR_RESPONSE" | jq -r '.error_description // .message // .error')
      fatal "DCR registration failed: ${DCR_DESC}"
    fi

    APIM_CLIENT_ID=$(echo "$DCR_RESPONSE"     | jq -r '.clientId     // empty')
    APIM_CLIENT_SECRET=$(echo "$DCR_RESPONSE" | jq -r '.clientSecret // empty')

    [[ -z "$APIM_CLIENT_ID"     ]] && fatal "DCR response missing clientId.     Raw: ${DCR_RESPONSE}"
    [[ -z "$APIM_CLIENT_SECRET" ]] && fatal "DCR response missing clientSecret. Raw: ${DCR_RESPONSE}"

    ok "DCR registration successful"
    echo "  clientId:     ${APIM_CLIENT_ID}"
    echo "  clientSecret: ${APIM_CLIENT_SECRET:0:4}$(printf '%0.s*' {1..12})"
    CREATE_APIM_OAUTH=true
  fi

  # ── Step 2: Create gateway environment in APIM (optional) ────────────────────
  # POST /api/am/admin/v4/gateways — the response contains the CP registration token.
  # Skip if CP_TOKEN is already set or if the user declines.
  if [[ -n "$CP_TOKEN" ]]; then
    info "CP_TOKEN already set — skipping gateway creation."
  else
    echo ""
    CREATE_GW="n"
    if [[ -t 0 ]]; then
      read -rp "  Create a new gateway environment in APIM now? [y/N]: " CREATE_GW
    fi

    if [[ "$CREATE_GW" == "y" || "$CREATE_GW" == "Y" ]]; then
      echo ""
      echo "  Enter gateway environment details:"

      GW_NAME="${GW_NAME:-}"
      GW_DISPLAY_NAME="${GW_DISPLAY_NAME:-}"
      GW_VHOST="${GW_VHOST:-}"
      GW_BASE_URL="${GW_BASE_URL:-}"
      GW_VERSION="${GW_VERSION:-1.1.0}"
      GW_DESCRIPTION="${GW_DESCRIPTION:-}"

      prompt_val GW_NAME        "  Gateway name (no spaces, used as identifier)" "prod-gateway"
      GW_DISPLAY_NAME="${GW_DISPLAY_NAME:-$GW_NAME}"
      prompt_val GW_DISPLAY_NAME "  Display name (shown in APIM console)" "$GW_NAME"
      prompt_val GW_VHOST       "  Virtual host with port, e.g. gateway.example.com:8443" ""
      prompt_val GW_BASE_URL    "  Base URL, e.g. https://gateway.example.com:8443" "https://${GW_VHOST}"
      prompt_val GW_VERSION     "  Gateway controller version" "1.1.0"
      prompt_val GW_DESCRIPTION "  Description (optional, blank to leave empty)" ""

      [[ -z "$GW_VHOST"    ]] && fatal "GW_VHOST is required for gateway creation."
      [[ -z "$GW_BASE_URL" ]] && fatal "GW_BASE_URL is required for gateway creation."

      info "POST ${APIM_HOST}/api/am/admin/v4/gateways"
      GW_RESPONSE=$(curl -sk -X POST "${APIM_HOST}/api/am/admin/v4/gateways" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -u "${APIM_ADMIN_USER}:${APIM_ADMIN_PASS}" \
        -d "{
          \"name\": \"${GW_NAME}\",
          \"displayName\": \"${GW_DISPLAY_NAME}\",
          \"description\": \"${GW_DESCRIPTION}\",
          \"vhost\": \"${GW_VHOST}\",
          \"properties\": {
            \"gatewayController\": {
              \"enabled\": true,
              \"baseUrl\": \"${GW_BASE_URL}\",
              \"version\": \"${GW_VERSION}\"
            }
          },
          \"permissions\": {
            \"permissionType\": \"PUBLIC\",
            \"roles\": []
          }
        }") || fatal "curl failed — check that APIM_HOST is reachable."

      GW_ERROR=$(echo "$GW_RESPONSE" | jq -r '.error // .code // empty' 2>/dev/null || true)
      if [[ -n "$GW_ERROR" ]]; then
        GW_DESC=$(echo "$GW_RESPONSE" | jq -r '.description // .message // .error // .code')
        fatal "Gateway creation failed: ${GW_DESC}"
      fi

      GW_ID=$(echo "$GW_RESPONSE"  | jq -r '.id    // empty')
      CP_TOKEN=$(echo "$GW_RESPONSE" | jq -r '.registrationToken // empty')

      [[ -z "$GW_ID"    ]] && fatal "Gateway creation response missing id.    Raw: ${GW_RESPONSE}"
      [[ -z "$CP_TOKEN" ]] && fatal "Gateway creation response missing registrationToken. Raw: ${GW_RESPONSE}"

      ok "Gateway environment created"
      echo "  id:    ${GW_ID}"
      echo "  name:  ${GW_NAME}"
      echo "  token: ${CP_TOKEN:0:8}$(printf '%0.s*' {1..16})  (stored in gateway-cp-token secret)"
    else
      # ── Step 3: OAuth2 token fallback ──────────────────────────────────────
      # If the user skipped gateway creation, get a client-credentials token instead.
      info "Fetching OAuth2 access token from APIM as CP token fallback..."
      TOKEN_RESPONSE=$(curl -sk -X POST "${APIM_HOST}/oauth2/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -u "${APIM_CLIENT_ID}:${APIM_CLIENT_SECRET}" \
        -d "grant_type=client_credentials") || fatal "curl failed on token endpoint."

      TOKEN_ERROR=$(echo "$TOKEN_RESPONSE" | jq -r '.error // empty' 2>/dev/null || true)
      if [[ -n "$TOKEN_ERROR" ]]; then
        TOKEN_DESC=$(echo "$TOKEN_RESPONSE" | jq -r '.error_description // .error')
        fatal "Token request failed: ${TOKEN_DESC}"
      fi

      CP_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')
      [[ -z "$CP_TOKEN" ]] && fatal "Token response missing access_token. Raw: ${TOKEN_RESPONSE}"

      TOKEN_EXPIRES=$(echo "$TOKEN_RESPONSE" | jq -r '.expires_in // "unknown"')
      ok "Access token obtained  (expires_in: ${TOKEN_EXPIRES}s)"
      warn "Tokens expire. The controller uses the DCR client credentials to refresh at runtime."
    fi
  fi
fi

# ── Namespace ─────────────────────────────────────────────────────────────────
section "Namespace"
info "Ensuring namespace '$NAMESPACE' exists"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ── 1. Encryption key ─────────────────────────────────────────────────────────
section "[1/6] Encryption key  →  gateway-encryption-keys"
echo "  AES-GCM 256-bit key used by the controller to encrypt secrets at rest."

KEY_FILE="./default-aesgcm256-v1.bin"
KEY_GENERATED=false

if [[ ! -f "$KEY_FILE" ]]; then
  openssl rand -out "$KEY_FILE" 32
  KEY_GENERATED=true
  ok "Generated new AES-GCM-256 key: $KEY_FILE"
  warn "IMPORTANT: Back up this file to secure offline storage, then delete it from this machine."
else
  info "Re-using existing key file: $KEY_FILE"
fi

kubectl create secret generic gateway-encryption-keys \
  --namespace "$NAMESPACE" \
  --from-file=default-aesgcm256-v1.bin="$KEY_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -
ok "Applied secret: gateway-encryption-keys"

# Encode for Key Vault table
AES_KEY_B64=$(base64 < "$KEY_FILE")

# ── 2. Admin credentials ──────────────────────────────────────────────────────
section "[2/6] Admin credentials  →  gateway-admin-credentials"
echo "  Stores the plain password for rotation reference only."
echo "  The bcrypt HASH (generated below) goes into values.yaml — NOT the plain password."

BCRYPT_HASH=""
if [[ -n "$ADMIN_PASSWORD" ]]; then
  kubectl create secret generic gateway-admin-credentials \
    --namespace "$NAMESPACE" \
    --from-literal=username="$ADMIN_USERNAME" \
    --from-literal=password="$ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "Applied secret: gateway-admin-credentials"

  echo ""
  echo "  Generating bcrypt hash for values.yaml..."
  if command -v htpasswd &>/dev/null; then
    BCRYPT_HASH=$(htpasswd -nbB "$ADMIN_USERNAME" "$ADMIN_PASSWORD" | cut -d: -f2)
  else
    BCRYPT_HASH=$(docker run --rm httpd:alpine htpasswd -nbB "$ADMIN_USERNAME" "$ADMIN_PASSWORD" 2>/dev/null | cut -d: -f2)
  fi

  if [[ -n "$BCRYPT_HASH" ]]; then
    echo ""
    echo -e "  ${BOLD}Bcrypt hash — paste into values.yaml:${NC}"
    echo "  ${BCRYPT_HASH}"
    echo ""
    echo "  Location in values.yaml:"
    echo "    gateway.config.controller.auth.basic.users[0].password: \"${BCRYPT_HASH}\""
  else
    warn "Could not generate bcrypt hash (htpasswd and docker not found)."
    warn "Generate manually: docker run --rm httpd:alpine htpasswd -nbB admin 'PASSWORD' | cut -d: -f2"
  fi
else
  warn "ADMIN_PASSWORD not provided — skipping gateway-admin-credentials."
fi

# ── 3. PostgreSQL password ────────────────────────────────────────────────────
section "[3/6] PostgreSQL password  →  gateway-postgres-password"

if [[ -n "$POSTGRES_PASSWORD" ]]; then
  kubectl create secret generic gateway-postgres-password \
    --namespace "$NAMESPACE" \
    --from-literal=password="$POSTGRES_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "Applied secret: gateway-postgres-password"
else
  warn "POSTGRES_PASSWORD not provided — skipping gateway-postgres-password."
fi

# ── 4. Control plane token ────────────────────────────────────────────────────
section "[4/6] Control plane token  →  gateway-cp-token"

if [[ -n "$CP_TOKEN" ]]; then
  kubectl create secret generic gateway-cp-token \
    --namespace "$NAMESPACE" \
    --from-literal=token="$CP_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "Applied secret: gateway-cp-token"
else
  warn "CP_TOKEN not provided — skipping gateway-cp-token."
fi

# ── 5. TLS certificate ────────────────────────────────────────────────────────
section "[5/6] TLS certificate  →  gateway-tls"

if [[ "$CREATE_TLS" == "true" ]]; then
  kubectl create secret tls gateway-tls \
    --namespace "$NAMESPACE" \
    --cert="$TLS_CERT_PATH" \
    --key="$TLS_KEY_PATH" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "Applied secret: gateway-tls (from $TLS_CERT_PATH)"
elif [[ "$SKIP_TLS" == "true" ]]; then
  warn "SKIP_TLS=true — skipping gateway-tls (expected: cert-manager will issue the certificate)."
  warn "Ensure values.yaml sets: gateway.controller.tls.certificateProvider: cert-manager"
else
  warn "TLS_CERT_PATH / TLS_KEY_PATH not provided — skipping gateway-tls."
  warn "Create it manually before deploying:"
  echo "    kubectl create secret tls gateway-tls \\"
  echo "      --namespace $NAMESPACE \\"
  echo "      --cert=./gateway.crt --key=./gateway.key"
fi

# ── 6. APIM OAuth2 credentials ────────────────────────────────────────────────
section "[6/6] APIM OAuth2 credentials  →  apim-oauth-client-secret-secret"
echo "  Used by the controller for Bottom-Up deployment (gateway → APIM sync)."
echo "  Skip if you are using Top-Down deployment (APIM pushes to gateway)."

if [[ "$CREATE_APIM_OAUTH" == "true" ]]; then
  kubectl create secret generic apim-oauth-client-secret-secret \
    --namespace "$NAMESPACE" \
    --from-literal=APIP_GW_CONTROLLER_CONTROLPLANE_APIM__OAUTH2__CLIENT__ID="$APIM_CLIENT_ID" \
    --from-literal=APIP_GW_CONTROLLER_CONTROLPLANE_APIM__OAUTH2__CLIENT__SECRET="$APIM_CLIENT_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "Applied secret: apim-oauth-client-secret-secret"
else
  warn "APIM_CLIENT_ID / APIM_CLIENT_SECRET not provided — skipping apim-oauth-client-secret-secret."
  warn "If you need Bottom-Up deployment, generate credentials via DCR and re-run:"
  echo ""
  echo "    # Register a DCR client against APIM to get clientId/clientSecret:"
  echo "    curl -k -X POST https://<APIM_HOST>/client-registration/v0.17/register \\"
  echo "      -H 'Content-Type: application/json' \\"
  echo "      -u admin:admin \\"
  echo "      -d '{"
  echo "        \"clientName\": \"gateway-controller\","
  echo "        \"owner\": \"admin\","
  echo "        \"grantType\": \"client_credentials password refresh_token\","
  echo "        \"saasApp\": true"
  echo "      }'"
fi

# ── Verify all secrets created ────────────────────────────────────────────────
section "Verification"
info "Secrets in namespace '$NAMESPACE':"
kubectl get secrets -n "$NAMESPACE" \
  --field-selector type=Opaque \
  -o custom-columns='NAME:.metadata.name,KEYS:.data' 2>/dev/null || true

# ── values.yaml checklist ─────────────────────────────────────────────────────
section "values.yaml — Required Updates Checklist"
cat <<'CHECKLIST'
  Update the following fields in values.yaml before running helm install:

  AUTHENTICATION
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │ gateway.config.controller.auth.basic.users[0].password                     │
  │   → paste the bcrypt hash printed above (never the plain password)          │
  │                                                                             │
  │ gateway.config.controller.auth.basic.users[1].password                     │
  │   → bcrypt hash for additional users (repeat hash generation per user)     │
  └─────────────────────────────────────────────────────────────────────────────┘

  CONTROL PLANE
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │ gateway.controller.controlPlane.host                                        │
  │   → APIM service host:port (e.g. apim-service.apim.svc.cluster.local:9443) │
  │                                                                             │
  │ gateway.config.controller.controlplane.gateway_name                        │
  │   → Friendly display name shown in the APIM console (e.g. "prod-gateway") │
  │                                                                             │
  │ gateway.config.controller.server.gateway_id                                │
  │   → Unique machine ID for this gateway instance (e.g. "prod-gateway-01")  │
  └─────────────────────────────────────────────────────────────────────────────┘

  DATABASE (PostgreSQL)
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │ gateway.config.controller.storage.postgres.host                            │
  │   → PostgreSQL hostname (e.g. gateway-postgres.postgres.database.azure.com)│
  │                                                                             │
  │ gateway.config.controller.storage.postgres.sslmode                         │
  │   → Change from "disable" to "require" for production                      │
  └─────────────────────────────────────────────────────────────────────────────┘

  TLS
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │ gateway.controller.tls.certificateProvider                                 │
  │   → "secret"      if using a pre-existing TLS secret (gateway-tls)         │
  │   → "cert-manager" if using cert-manager to issue the certificate          │
  └─────────────────────────────────────────────────────────────────────────────┘

  IMAGES
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │ gateway.controller.image.tag                                                │
  │ gateway.gatewayRuntime.image.tag                                            │
  │   → Pin both to the specific release tag (e.g. "1.2.0")                   │
  └─────────────────────────────────────────────────────────────────────────────┘

  LOAD BALANCER (if cloud-hosted)
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │ gateway.gatewayRuntime.service.annotations                                 │
  │   → Add cloud-specific LB annotations, e.g. for Azure:                    │
  │       service.beta.kubernetes.io/azure-load-balancer-internal: "true"     │
  └─────────────────────────────────────────────────────────────────────────────┘

CHECKLIST

# ── Key Vault secrets table ───────────────────────────────────────────────────
section "Key Vault — Secrets Reference Table"
echo "  Store the following in your Key Vault for disaster recovery and rotation."
echo "  The bcrypt hash is safe to store in plain config (it is not reversible)."
echo ""

PAD=44

printf "  ${BOLD}%-${PAD}s  %-36s  %s${NC}\n" "K8S SECRET / KEY" "VALUE TO STORE IN VAULT" "PURPOSE"
printf "  %s\n" "$(printf '─%.0s' {1..120})"

# 1. Encryption key (base64 of the binary)
printf "  %-${PAD}s  %-36s  %s\n" \
  "gateway-encryption-keys" \
  "(see below — long value)" \
  "AES-GCM 256-bit key for data-at-rest encryption"
printf "  %-${PAD}s  %s\n" \
  "  key: default-aesgcm256-v1.bin (base64)" \
  "$AES_KEY_B64"

echo ""

# 2. Admin credentials
printf "  %-${PAD}s  %-36s  %s\n" \
  "gateway-admin-credentials / username" \
  "$ADMIN_USERNAME" \
  "Gateway admin username"
printf "  %-${PAD}s  %-36s  %s\n" \
  "gateway-admin-credentials / password" \
  "${ADMIN_PASSWORD:0:4}$(printf '%0.s*' {1..12})  (redacted)" \
  "Gateway admin plain password (rotation reference)"
if [[ -n "$BCRYPT_HASH" ]]; then
  printf "  %-${PAD}s  %-36s  %s\n" \
    "values.yaml: auth.basic.users[0].password" \
    "$BCRYPT_HASH" \
    "Bcrypt hash — paste into values.yaml"
fi

echo ""

# 3. PostgreSQL
printf "  %-${PAD}s  %-36s  %s\n" \
  "gateway-postgres-password / password" \
  "${POSTGRES_PASSWORD:0:4}$(printf '%0.s*' {1..12})  (redacted)" \
  "PostgreSQL gateway user password"

echo ""

# 4. Control plane token
printf "  %-${PAD}s  %-36s  %s\n" \
  "gateway-cp-token / token" \
  "${CP_TOKEN:0:8}$(printf '%0.s*' {1..12})  (redacted)" \
  "WSO2 APIM control plane registration token"

echo ""

# 5. TLS
if [[ "$CREATE_TLS" == "true" ]]; then
  printf "  %-${PAD}s  %-36s  %s\n" \
    "gateway-tls / tls.crt" \
    "(contents of $TLS_CERT_PATH)" \
    "TLS certificate for the gateway controller"
  printf "  %-${PAD}s  %-36s  %s\n" \
    "gateway-tls / tls.key" \
    "(contents of $TLS_KEY_PATH)" \
    "TLS private key — treat as highly sensitive"
else
  printf "  %-${PAD}s  %-36s  %s\n" \
    "gateway-tls / tls.crt + tls.key" \
    "(not created — provide cert & key paths)" \
    "TLS certificate and key"
fi

echo ""

# 6. APIM OAuth
if [[ "$CREATE_APIM_OAUTH" == "true" ]]; then
  printf "  %-${PAD}s  %-36s  %s\n" \
    "apim-oauth-client-secret-secret" \
    "" \
    "APIM OAuth2 DCR credentials (Bottom-Up deployment)"
  printf "  %-${PAD}s  %-36s  %s\n" \
    "  key: APIM_OAUTH2_CLIENT_ID" \
    "$APIM_CLIENT_ID" \
    "DCR client ID"
  printf "  %-${PAD}s  %-36s  %s\n" \
    "  key: APIM_OAUTH2_CLIENT_SECRET" \
    "${APIM_CLIENT_SECRET:0:4}$(printf '%0.s*' {1..12})  (redacted)" \
    "DCR client secret"
else
  printf "  %-${PAD}s  %-36s  %s\n" \
    "apim-oauth-client-secret-secret" \
    "(not created — see DCR instructions above)" \
    "APIM OAuth2 credentials (Bottom-Up deployment only)"
fi

echo ""
printf "  %s\n" "$(printf '─%.0s' {1..120})"
echo ""
warn "Sensitive values above are partially redacted for display safety."
warn "Retrieve full values from 'kubectl get secret <name> -n $NAMESPACE -o jsonpath=...' if needed."
echo ""
ok "Done. Next step: helm install ap-gateway oci://ghcr.io/wso2/api-platform/helm-charts/gateway \\"
echo "       --version 1.2.0 --namespace $NAMESPACE --create-namespace \\"
echo "       --values ./values.yaml --wait --timeout 5m"
echo ""

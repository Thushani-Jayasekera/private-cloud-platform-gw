# API Platform Gateway - Production Deployment Guide

This guide covers deploying the API Platform Gateway (controller, runtime) using Helm charts in a production environment, including security hardening, database configuration, resource tuning, and horizontal pod autoscaling.

---

## Prerequisites

Before starting, ensure the following tools are installed locally:

*   Kubernetes CLI (kubectl)
*   Helm 3+
*   OpenSSL
*   Access to an AKS cluster
*   Cluster admin permissions

Useful verification commands:

```bash
kubectl cluster-info
kubectl get nodes
helm version
```

Use at least two worker nodes for high availability. Recommended minimum production topology:1
Node Pool	Purpose	Recommended Size
systempool	Kubernetes system workloads	1–2 nodes
gatewaypool	Gateway runtime + controller	Minimum 2 nodes

This ensures:
- No single-node failure outage
- Safer autoscaling
- Improved workload isolation

## Architecture Overview

The gateway chart deploys two main workloads:

### Step 1: Install cert-manager (optional)

cert-manager automates TLS certificate provisioning and renewal within Kubernetes clusters.

Please install cert-manager unless you plan to manually generate certificates and manage them as Kubernetes secrets.

```bash
helm repo add jetstack [https://charts.jetstack.io](https://charts.jetstack.io) --force-update
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

#### Verify all cert-manager pods are running

```bash
kubectl get pods -n cert-manager
```

#### Verify Installation
```bash
kubectl get pods -n cert-manager
```

### Step 2: Create Encryption Keys1

Encryption keys are required in production (developmentMode=false). The controller uses AES-GCM 256-bit keys to encrypt sensitive data at rest.

#### Generate a 256-bit AES key

```bash
openssl rand -out default-aesgcm256-v1.bin 32
```

#### Create the Kubernetes secret

```bash
kubectl create secret generic gateway-encryption-keys \
  --namespace <your-namespace> \
  --from-file=default-aesgcm256-v1.bin=./default-aesgcm256-v1.bin
```

#### Clean up the local key file

```bash
rm ./default-aesgcm256-v1.bin
```

Reference the secret in your values file:

```yaml
gateway:
  controller:
    encryptionKeys:
      enabled: true
      secretName: gateway-encryption-keys
      mountPath: /app/data/aesgcm-keys
```

The config must align the file path with the secret key name:

```yaml
gateway:
  config:
    controller:
      encryption:
        providers:
          - type: aesgcm
            keys:
              - version: aesgcm256-v1
                file: /app/data/aesgcm-keys/default-aesgcm256-v1.bin
```

To rotate keys:
Generate a new key
Increment the version
Update the Kubernetes Secret
Redeploy the Helm release

### Step 3: Configure TLS Certificates1

You must configure TLS before exposing the gateway externally.

Choose one of the following approaches.

#### Option A: cert-manager

For production with a trusted CA (e.g., Let's Encrypt or internal PKI), create a ClusterIssuer and reference it:

```yaml
gateway:
  controller:
    tls:
      enabled: true
      certificateProvider: cert-manager
      certManager:
        create: true
        createIssuer: false          # Use your own issuer
        issuerRef:
          name: letsencrypt-prod    # Your ClusterIssuer name
          kind: ClusterIssuer
        commonName: gateway.example.com
        dnsNames:
          - gateway.example.com
        duration: 2160h             # 90 days
        renewBefore: 720h           # Renew 30 days before expiry
```

#### Option B: Existing TLS Secret

If you manage certificates externally (e.g., via a corporate PKI or Vault):

Create TLS Secret:

```bash
kubectl create secret tls gateway-tls \
  --namespace <your-namespace> \
  --cert=./gateway.crt \
  --key=./gateway.key
```

```yaml
gateway:
  controller:
    tls:
      enabled: true
      certificateProvider: secret
      secret:
        name: gateway-tls
        certKey: tls.crt
        keyKey: tls.key
```

### Configure Upstream Custom CA Certificates

If your backend services use certificates signed by a private CA:

```bash
kubectl create configmap gateway-upstream-certs \
  --namespace <your-namespace> \
  --from-file=private-ca.crt=./my-ca.crt
```

```yaml
gateway:
  controller:
    upstreamCerts:
      enabled: true
      configMapName: gateway-upstream-certs
```

### Step 4: Configure Authentication1

Note: Choose an authentication strategy based on organizational requirements.

Security requirement: The default credentials (admin/admin) must be replaced before deploying to any non-development environment. The controller logs a warning at startup if default or no authentication is configured.

#### Option A: IDP / OAuth21

The safest option, no credentials to manage in the cluster at all. Replace basic auth with your identity provider:

```yaml
gateway:
  config:
    controller:
      auth:
        basic:
          enabled: false
        idp:
          enabled: true
          jwks_url: "[https://idp.example.com/.well-known/jwks.json](https://idp.example.com/.well-known/jwks.json)"
          issuer: "[https://idp.example.com](https://idp.example.com)"
          roles_claim: "scope"
          role_mapping:
            admin: ["gateway:admin"]
            developer: ["gateway:developer"]
            consumer:\["gateway:consumer"\]
```

Gateway Controller OpenAPI - https://github.com/wso2/api-platform/blob/d525c16e449547be68edea6ce1ec31062457fa63/gateway/gateway-controller/api/management-openapi.yaml#L1

#### Option B: Basic Auth with Hashed Passwords1

If basic auth is required, never use plain-text passwords. The controller supports bcrypt hashes, the hash is safe to store in a ConfigMap (it is not reversible), while the plain password is stored only in a Kubernetes Secret for team reference and rotation.1. Generate a bcrypt hash

-- Requires apache2-utils (apt) or httpd-tools (yum) — or use Docker
```bash
htpasswd -nbB admin 'your-secure-password' | cut -d: -f2
```
--- Output: $2y$10$...

On macOS without htpasswd:
```bash
docker run --rm httpd:alpine htpasswd -nbB admin 'your-secure-password' | cut -d: -f2
```

2. Store the plain password in a Kubernetes Secret

The plain password should never appear in Helm values or ConfigMaps. Keep it in a Secret for rotation reference only:

```bash
kubectl create secret generic gateway-admin-credentials \
  --namespace <your-namespace> \
  --from-literal=username=admin \
  --from-literal=password='your-secure-password'
```

3. Configure the chart with the bcrypt hash1

Only the hash goes into the Helm values, this is what ends up in the ConfigMap:

```yaml
gateway:
  config:
    controller:
      auth:
        basic:
          enabled: true
          users:
            - username: "admin"
              password: "$2y$10$..."   # bcrypt hash — safe to store in ConfigMap
              password_hashed: true
              roles: ["admin"]
```

Note: Because basic auth users are an array of structs, they cannot be overridden via environment variables. The hash must be supplied through Helm values. Rotate credentials by generating a new hash, updating the values, and running helm upgrade.

### Step 5: Database Configuration1

The gateway controller supports two persistent storage backends: SQLite (default, single-instance) and PostgreSQL (recommended for production with HA).

#### Option A: PostgreSQL (Recommended for Production)

PostgreSQL removes the single-replica constraint and is the right choice for production deployments that require high availability.

1. Create the database

Connect to PostgreSQL
```bash
psql "host=gateway-postgres.postgres.database.azure.com \
port=5432 \
dbname=gateway_controller \
user=gateway \
sslmode=require"
```

Create the application database, user and set privileges

```bash
CREATE DATABASE gateway_controller;
CREATE USER gateway WITH PASSWORD 'your-db-password';
GRANT ALL PRIVILEGES ON DATABASE gateway_controller TO gateway;
```

2. Store the password in a Kubernetes Secret
```bash
kubectl create secret generic gateway-postgres-password \
  --namespace <your-namespace> \
  --from-literal=password='your-db-password'
```

3. Configure the chart

```bash
gateway:
  config:
    controller:
      storage:
        type: postgres
        postgres:
          host: "gateway-postgres.postgres.database.azure.com"
          port: 5432
          database: "gateway_controller"
          user: "gateway"
          sslmode: require      # Never use "disable" in production
          connect_timeout: 5s
          max_open_conns: 10
          max_idle_conns: 5
          conn_max_lifetime: 30m
          conn_max_idle_time: 5m
          application_name: gateway-controller

  controller:
    storage:
      type: postgres
    postgres:
      passwordSecretRef:
        name: gateway-postgres-password
        key: password
    # Disable the SQLite PVC — not needed with PostgreSQL
    persistence:
      enabled: false
```

Using a DSN instead of individual fields

If your PostgreSQL connection string is managed externally (e.g., from a secrets manager):

```bash
kubectl create secret generic gateway-postgres-dsn \
  --namespace <your-namespace> \
  --from-literal=password='your-db-password'
```

```yaml
gateway:
  config:
    controller:
      storage:
        type: postgres
        postgres:
          dsn: "postgres://gateway:@postgres.example.internal:5432/gateway_controller?sslmode=require"
  controller:
    postgres:
      passwordSecretRef:
        name: gateway-postgres-dsn
        key: password
```

When dsn is set, it takes precedence over all individual connection fields. The password env var is still injected from the secret.

#### Connection pool tuning
Parameter	Default	When to adjust
max_open_conns	25	Increase for high-throughput deployments
max_idle_conns	5	Should be ≤ max_open_conns
conn_max_lifetime	30m	Reduce if your PostgreSQL has aggressive idle timeouts
conn_max_idle_time1	5m1	Reduce if connection churn is a concern

### Step 6: Control Plane Connection

The controller syncs API artifacts from the WSO2 APIM control plane.Using a Secret (Recommended)

```bash
kubectl create secret generic gateway-cp-token \
  --namespace <your-namespace> \
  --from-literal=token='your-registration-token'
```

```yaml
gateway:
  controller:
    controlPlane:
      host: apim.example.com
      port: 8443
      token:
        secretName: gateway-cp-token
        key: token

  config:
    controller:
      controlplane:
        reconnect_initial: 1s
        reconnect_max: 5m
        polling_interval: 15m
        deployment_push_enabled: false
        sync_batch_size: 50
        gateway_name: "prod-gateway"
```

The WSO2 API Platform gateway supports two fundamentally different deployment approaches, distinguished by the direction of API flow:Top-Down Deployment (Control Plane → Gateway)

The platform-API (central control plane) pushes APIs to the gateway via WebSocket connection.Bottom-Up Deployment (Gateway → On-Prem APIM)

REST APIs deployed directly to the gateway are automatically synced back to on-prem WSO2 APIM. (If configured with on prem control plane type. Cloud control plane is not having this support at the moment.).Configs to add if Bottom-Up Deployment approach is used:

```yaml
gateway:
  config:
    controller:
      server:
        gateway_id: "prod-gateway"
      controlplane:
        apim_oauth2_client_id: "your-client-id"
        apim_oauth2_client_secret: "your-client-secret"
    gateway_name: "prod-gateway"
```

Instead of using apim_oauth2_client_id and apim_oauth2_client_secret, you can configure authentication using the Resource Owner Password Credentials flow by providing a username and password.

```yaml
       # OAuth2 Option 2: Resource Owner Password Credentials flow
        apim_oauth2_username: ""
        apim_oauth2_password: ""
```
Store OAuth2 credentials in a Kubernetes secret and inject via extraEnvFrom rather than plain values.

#### Create apim-oauth-secret.yaml

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: apim-oauth-client-secret-secret
  namespace: ap-gateway  # adjust to match your deployment namespace
type: Opaque
stringData:
  # Generate these values by registering a DCR client against APIM:
  # The response contains clientId and clientSecret — paste them below.
  APIP_GW_CONTROLLER_CONTROLPLANE_APIM__OAUTH2__CLIENT__ID: "HCyqItmC6zio5mOfFHyorYhtbQIa"
  APIP_GW_CONTROLLER_CONTROLPLANE_APIM__OAUTH2__CLIENT__SECRET: "xx"
```

```bash
kubectl apply -f apim-oauth-secret.yaml
```

```yaml
gateway:
  config:
    controller:
      deployment:
        extraEnvFrom:
         - secretRef:
            name: apim-oauth-client-secret-secret
```

#### How to Generate apim_oauth2_client_id and apim_oauth2_client_secret1

```bash
$(echo -n '<apim username>:<apim password>' | base64)
```

```bash
curl -k -X POST https://<APIM HOST>/client-registration/v0.17/register \
    -H "Content-Type: application/json" \
    -u admin:admin \
    -d '{
      "clientName": "gateway-controller",
      "owner": "admin",
      "grantType": "client_credentials password refresh_token",
      "saasApp": true
    }'
```

### Step 7: Resource Limits and Requests1

Note: Choose values based on organizational requirements.1

Always set resource limits in production to prevent runaway resource consumption.Gateway Controller1

```yaml
gateway:
  controller:
    deployment:
      resources:
        requests:
          cpu: 250m
          memory: 256Mi
        limits:
          cpu: 500m
          memory: 512Mi
```

Gateway Runtime

The runtime hosts Envoy and the policy engine. It processes all API traffic, so allocate generously.

```yaml
gateway:
  gatewayRuntime:
    deployment:
      resources:
        requests:
          cpu: 500m
          memory: 512Mi
        limits:
          cpu: 2000m
          memory: 2Gi
```

### Step 8 - Configure Pod Affinity Rules (Recommended)1

To ensure the Gateway Controller and Gateway Runtime pods are distributed across different nodes, configure pod anti-affinity rules.1

This prevents multiple controller replicas from being scheduled on the same node.

```yaml
affinity:
 podAntiAffinity:
   preferredDuringSchedulingIgnoredDuringExecution:
     - weight: 100
       podAffinityTerm:
         labelSelector:
           matchLabels:
             app.kubernetes.io/component: controller
         topologyKey: kubernetes.io/hostname
```

### Step 9 - Configure Autoscaling and Pod Disruption Budget (Recommended)1

This step ensures the Gateway components can scale safely and remain highly available during disruptions such as node upgrades, pod evictions, or rolling updates

#### Horizontal Pod Autoscaler (HPA)

HPA automatically adjusts the number of replicas based on CPU/memory utilization.

Recommended Configuration for gateway controller (gateway.controller) and gateway runtime (gateway.gatewayRuntime)

```yaml
hpa:
 enabled: true
 minReplicas: 2
 maxReplicas: 5
 targetCPUUtilizationPercentage: 70
 targetMemoryUtilizationPercentage: ""
 customMetrics: []
 behavior: {}
```

2. Pod Disruption Budget (PDB)1

PDB ensures at least one pod remains available during:
- Node upgrades
- Cluster autoscaling events
- Voluntary evictions
- Maintenance operations

```yaml
podDisruptionBudget:
enabled: true
minAvailable: 50%
maxUnavailable: ""
```

### Production values.yaml Reference

Changed values
- passwords/ secret references
- Authentication mechanism
- Deployment - node selectors, affinity rules, resources, liveness probe, readiness probe
- HPA
- Pod disruption budget

Sample production-values.yaml -  Platform API Gateway Setup Guide


### Step 10: Deploy the ChartInstall from OCI Registry

```bash
helm install ap-gateway oci://ghcr.io/wso2/api-platform/helm-charts/gateway \
  --version 1.1.1 \
  --namespace ap-gateway \
  --create-namespace \
  --values ./production-values.yaml \
  --wait \
  --timeout 5m
```

Install from Local Chart (Only for testing purposes)

```bash
helm install ap-gateway ./kubernetes/helm/gateway-helm-chart \
  --namespace ap-gateway \
  --create-namespace \
  --values ./production-values.yaml \
  --wait \
  --timeout 5m
```

### Verify the Deployment1

#### Check all pods are running
kubectl get pods -n ap-gateway

####  Check controller health
kubectl port-forward -n ap-gateway svc/ap-gateway-controller 9092:9092
curl http://localhost:9092/api/admin/v0.9/health

####  Check runtime service external IP
```bash
kubectl get svc -n ap-gateway ap-gateway-gateway-runtime
Post-deployment Verification1
```

####  All pods running
```bash
kubectl get pods -n ap-gateway
```

####  Controller health check (admin port 9092)
```bash
kubectl exec -n ap-gateway deploy/ap-gateway-controller -- \
  wget -qO- http://localhost:9092/api/admin/v0.9/health
```

####  Runtime service endpoint
```bash
kubectl get svc -n ap-gateway
```

####  Check certificates are issued (cert-manager)
```bash
kubectl get certificate -n ap-gateway
```

####  HPA status (if applied)
```bash
kubectl get hpa -n ap-gateway
```

####  View controller logs
```bash
kubectl logs -n ap-gateway deploy/ap-gateway-controller --follow
```

####  View runtime logs

```bash
kubectl logs -n ap-gateway deploy/ap-gateway-gateway-runtime --follow
```

Verify the Rest API (Developer)1

```bash
kubectl port-forward -n ap-gateway svc/ap-gateway-controller 9090:9090
```

Create a test API:
```bash
curl -X POST http://localhost:9090/rest-apis \
  -u <username>:<password> \
  -H "Content-Type: application/yaml" \
  --data-binary @./petstore-api.yaml
```

List all APIs:
```bash
curl -s http://localhost:9090/rest-apis \
  -u <username>:<password> | jq '[.[] | {name: .metadata.name, state: .status.state}]'
```

### Upgrade Procedure

#### Pull latest chart values schema to see what changed
helm show values oci://ghcr.io/wso2/api-platform/helm-charts/gateway --version <new-version>

#### Diff current release vs new chart (requires helm-diff plugin)
helm diff upgrade ap-gateway oci://ghcr.io/wso2/api-platform/helm-charts/gateway \
  --version <new-version> \
  --namespace ap-gateway \
  --values ./production-values.yaml

#### Upgrade
helm upgrade ap-gateway oci://ghcr.io/wso2/api-platform/helm-charts/gateway \
  --version <new-version> \
  --namespace ap-gateway \
  --values ./production-values.yaml \
  --wait \
  --timeout 5m

#### Rollback if needed
helm rollback ap-gateway --namespace ap-gateway
The controller pod restarts on upgrade. Because the gateway runtime syncs policy configuration via xDS from the controller, keep the runtime replicaCount at ≥ 2 so in-flight requests continue to be served during controller restarts.1
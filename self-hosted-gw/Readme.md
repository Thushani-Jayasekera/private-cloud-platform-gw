API Platform Gateway - Production Deployment Guide

This guide covers deploying the API Platform Gateway (controller, runtime) using Helm charts in a production environment, including security hardening, database configuration, resource tuning, and horizontal pod autoscaling.

Table of Contents
Prerequisites
Architecture Overview
Pre-deployment Checklist
Step 1: Install cert-manager
Step 2: Create Encryption Keys
Step 3: Configure TLS Certificates
Step 4: Configure Authentication
Step 5: Database Configuration
Step 6: Control Plane Connection
Step 7: Resource Limits and Requests
Step 8: Deploy the Chart
Step 9: Horizontal Pod Autoscaling (HPA)
Production values.yaml Reference
Post-deployment Verification
Upgrade Procedure

Cluster
dataplane

Prerequisites
Tool
Version
Kubernetes
1.24+
Helm
3.12+
kubectl
Matching cluster version
cert-manager
1.14+ (for TLS automation)
metrics-server
Any (required for HPA CPU/memory scaling)



















Architecture Overview
The gateway chart deploys two main workloads:




Pre-deployment Checklist
Before installing:
gateway.developmentMode: false is set in your values file
Default admin:admin credentials are replaced (IDP or bcrypt-hashed basic auth)
Encryption key secret is created (required when developmentMode=false)
TLS certificates are provisioned (cert-manager or existing secret)
Resource limits are defined for both controller and runtime
Control plane host and token are configured
PersistentVolume provisioner is available for the controller (SQLite), or PostgreSQL is provisioned
metrics-server is running in the cluster (for HPA)

Step 1: Install cert-manager
cert-manager automates TLS certificate provisioning and renewal.

helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true

# Verify all cert-manager pods are running
kubectl get pods -n cert-manager

Note: cert-manager is an open-source Kubernetes add-on that automates the management and issuance of TLS/SSL certificates within Kubernetes clusters.


Step 2: Create Encryption Keys

Encryption keys are required in production (developmentMode=false). The controller uses AES-GCM 256-bit keys to encrypt sensitive data at rest.

# Generate a 256-bit AES key
openssl rand -out default-aesgcm256-v1.bin 32

# Create the Kubernetes secret
kubectl create secret generic gateway-encryption-keys \
  --namespace <your-namespace> \
  --from-file=default-aesgcm256-v1.bin=./default-aesgcm256-v1.bin

# Clean up the local key file
rm ./default-aesgcm256-v1.bin

Reference the secret in your values file:

gateway:
  controller:
    encryptionKeys:
      enabled: true
      secretName: gateway-encryption-keys
      mountPath: /app/data/aesgcm-keys

The config must align the file path with the secret key name:
gateway:
  config:
    controller:
      encryption:
        providers:
          - type: aesgcm
            keys:
              - version: aesgcm256-v1
                file: /app/data/aesgcm-keys/default-aesgcm256-v1.bin
Key rotation: To rotate keys, add a new key entry with an incremented version (e.g., aesgcm256-v2), update the secret, and re-deploy. The controller reads all key versions; the first entry is used for new encryptions.


Step 3: Configure TLS Certificates

Option A: cert-manager (Recommended)
For production with a trusted CA (e.g., Let's Encrypt or internal PKI), create a ClusterIssuer and reference it:
YAML
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

Option B: Existing TLS Secret
If you manage certificates externally (e.g., via a corporate PKI or Vault):
Bash
kubectl create secret tls gateway-tls \
  --namespace <your-namespace> \
  --cert=./gateway.crt \
  --key=./gateway.key
YAML
gateway:
  controller:
    tls:
      enabled: true
      certificateProvider: secret
      secret:
        name: gateway-tls
        certKey: tls.crt
        keyKey: tls.key

Upstream TLS (Custom CA)
If your backend services use certificates signed by a private CA:

kubectl create configmap gateway-upstream-certs \
  --namespace <your-namespace> \
  --from-file=private-ca.crt=./my-ca.crt

gateway:
  controller:
    upstreamCerts:
      enabled: true
      configMapName: gateway-upstream-certs



Step 4: Configure Authentication

Note: Decide options on customer requirement

Security requirement: The default credentials (admin/admin) must be replaced before deploying to any non-development environment. The controller logs a warning at startup if default or no authentication is configured.
Option A: IDP / OAuth2 
The safest option,  no credentials to manage in the cluster at all. Replace basic auth with your identity provider:

gateway:
  config:
    controller:
      auth:
        basic:
          enabled: false
        idp:
          enabled: true
          jwks_url: "https://idp.example.com/.well-known/jwks.json"
          issuer: "https://idp.example.com"
          roles_claim: "scope"
          role_mapping:
            admin: ["gateway:admin"]
            readonly: ["gateway:read"]

Option B: Basic Auth with Hashed Passwords
If basic auth is required, never use plain-text passwords. The controller supports bcrypt hashes, the hash is safe to store in a ConfigMap (it is not reversible), while the plain password is stored only in a Kubernetes Secret for team reference and rotation.
1. Generate a bcrypt hash

# Requires apache2-utils (apt) or httpd-tools (yum) — or use Docker
htpasswd -nbB admin 'your-secure-password' | cut -d: -f2
# Output: $2y$10$...
On macOS without htpasswd:

docker run --rm httpd:alpine htpasswd -nbB admin 'your-secure-password' | cut -d: -f2

2. Store the plain password in a Kubernetes Secret
The plain password should never appear in Helm values or ConfigMaps. Keep it in a Secret for rotation reference only:

kubectl create secret generic gateway-admin-credentials \
  --namespace <your-namespace> \
  --from-literal=username=admin \
  --from-literal=password='your-secure-password'

3. Configure the chart with the bcrypt hash
Only the hash goes into the Helm values, this is what ends up in the ConfigMap:
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

Note: Because basic auth users are an array of structs, they cannot be overridden via environment variables. The hash must be supplied through Helm values. Rotate credentials by generating a new hash, updating the values, and running helm upgrade.

Step 5: Database Configuration
The gateway controller supports two persistent storage backends: SQLite (default, single-instance) and PostgreSQL (recommended for production with HA).
Option A: PostgreSQL (Recommended for Production)
PostgreSQL removes the single-replica constraint and is the right choice for production deployments that require high availability.
1. Create the database

CREATE DATABASE gateway_controller;
CREATE USER gateway WITH PASSWORD 'your-db-password';
GRANT ALL PRIVILEGES ON DATABASE gateway_controller TO gateway;
2. Store the password in a Kubernetes Secret

kubectl create secret generic gateway-postgres-password \
  --namespace <your-namespace> \
  --from-literal=password='your-db-password'

3. Configure the chart
gateway:
  config:
    controller:
      storage:
        type: postgres
        postgres:
          host: "postgres.example.internal"
          port: 5432
          database: "gateway_controller"
          user: "gateway"
          sslmode: require              # Never use "disable" in production
          connect_timeout: 5s
          max_open_conns: 25
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

Using a DSN instead of individual fields
If your PostgreSQL connection string is managed externally (e.g., from a secrets manager):

kubectl create secret generic gateway-postgres-dsn \
  --namespace <your-namespace> \
  --from-literal=password='your-db-password'

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
When dsn is set, it takes precedence over all individual connection fields. The password env var is still injected from the secret.
Connection pool tuning
Parameter
Default
When to adjust
max_open_conns
25
Increase for high-throughput deployments
max_idle_conns
5
Should be ≤ max_open_conns
conn_max_lifetime
30m
Reduce if your PostgreSQL has aggressive idle timeouts
conn_max_idle_time
5m
Reduce if connection churn is a concern



Step 6: Control Plane Connection
The controller syncs API artifacts from the WSO2 APIM control plane.
Using a Secret (Recommended)

kubectl create secret generic gateway-cp-token \
  --namespace <your-namespace> \
  --from-literal=token='your-registration-token'

gateway:
  controller:
    controlPlane:
      host: apim.example.com
      port: 8443
      token:
        secretName: gateway-cp-token
        key: token

gateway:
  config:
    controller:
      controlplane:
        insecure_skip_verify: false     # Must be false in production
        reconnect_initial: 1s
        reconnect_max: 5m
        polling_interval: 15m
        deployment_push_enabled: true
        sync_batch_size: 50
        gateway_name: "prod-gateway"


OAuth2 Client Credentials

gateway:
  config:
    controller:
      controlplane:
        apim_oauth2_client_id: "your-client-id"
        apim_oauth2_client_secret: "your-client-secret"

Store OAuth2 credentials in a Kubernetes secret and inject via extraEnvFrom rather than plain values.


Step 7: Resource Limits and Requests
Note: Decide options on customer requirement

Always set resource limits in production to prevent runaway resource consumption.
Gateway Controller
YAML
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

Gateway Runtime
The runtime hosts Envoy and the policy engine. It processes all API traffic, so allocate generously.
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


Sizing Guidelines
Traffic (req/s)
Runtime CPU Request
Runtime Memory Request
< 100
250m
256Mi
100 – 1,000
500m
512Mi
1,000 – 5,000
1000m
1Gi
> 5,000
2000m+
2Gi+



Step 8: Deploy the Chart
Install from OCI Registry

helm install ap-gateway oci://ghcr.io/wso2/api-platform/helm-charts/gateway \
  --version 1.2.0 \
  --namespace ap-gateway \
  --create-namespace \
  --values ./production-values.yaml \
  --wait \
  --timeout 5m

Install from Local Chart

helm install ap-gateway ./kubernetes/helm/gateway-helm-chart \
  --namespace ap-gateway \
  --create-namespace \
  --values ./production-values.yaml \
  --wait \
  --timeout 5m

Verify the Deployment

# Check all pods are running
kubectl get pods -n ap-gateway

# Check controller health
kubectl port-forward -n ap-gateway svc/ap-gateway-controller 9092:9092
curl http://localhost:9092/api/admin/v0.9/health

# Check runtime service external IP
kubectl get svc -n ap-gateway ap-gateway-gateway-runtime


Step 9: Horizontal Pod Autoscaling (HPA)

Prerequisite: metrics-server must be deployed in the cluster.

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
The gateway chart does not include HPA resources; they are applied separately to give you full control over the scaling policy.
HPA for Gateway Runtime
The gateway runtime is stateless and safe to scale horizontally. When using SQLite, the controller must remain at 1 replica (single writer). When using PostgreSQL, the controller can run multiple replicas.
hpa-gateway-runtime.yaml:
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ap-gateway-gateway-runtime
  namespace: ap-gateway
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ap-gateway-gateway-runtime  # Must match the deployment name
  minReplicas: 2
  maxReplicas: 10
  metrics:
    # Scale on CPU utilization
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    # Scale on memory utilization
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60       # Wait 60s before scaling up
      policies:
        - type: Pods
          value: 2
          periodSeconds: 60               # Add up to 2 pods per 60s
    scaleDown:
      stabilizationWindowSeconds: 300      # Wait 5m before scaling down
      policies:
        - type: Pods
          value: 1
          periodSeconds: 120              # Remove 1 pod per 2m

kubectl apply -f hpa-gateway-runtime.yaml

Verify HPA Status

kubectl get hpa -n ap-gateway
kubectl describe hpa ap-gateway-gateway-runtime -n ap-gateway

Expected output:
NAME                        REFERENCE                          TARGETS         MINPODS   MAXPODS   REPLICAS
ap-gateway-gateway-runtime  Deployment/ap-gateway-gateway-runtime  45%/70%, 30%/80%  2       10        3

Pod Disruption Budget (Recommended with HPA)
Prevent all runtime pods from being evicted simultaneously during node maintenance:
pdb-gateway-runtime.yaml:
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ap-gateway-gateway-runtime
  namespace: ap-gateway
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: gateway
      app.kubernetes.io/component: gateway-runtime
Bash
kubectl apply -f pdb-gateway-runtime.yaml

Pod Anti-Affinity (Recommended for HA)
Spread runtime replicas across nodes to avoid a single-node failure taking down all instances. Add to your values file:
YAML
gateway:
  gatewayRuntime:
    deployment:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app.kubernetes.io/component: gateway-runtime
                topologyKey: kubernetes.io/hostname


Production values.yaml Reference
The following is a complete annotated production values file. Save it as production-values.yaml and fill in the placeholders.
# ──────────────────────────────────────────────────────────────────
# API Platform Gateway — Production values
# Chart version: 1.2.0
# ──────────────────────────────────────────────────────────────────

nameOverride: ""
fullnameOverride: ""

imagePullSecrets: []

# Disable development mode — enforces encryption key requirement
gateway:
  developmentMode: false

  config:
    controller:
      auth:
        basic:
          enabled: false
        idp:
          enabled: true
          jwks_url: "https://idp.example.com/.well-known/jwks.json"
          issuer: "https://idp.example.com"
          roles_claim: "scope"
          role_mapping: {}

      server:
        api_port: 9090
        xds_port: 18000
        shutdown_timeout: 30s
        gateway_id: "prod-gateway"

      policy_server:
        port: 18001
        tls:
          enabled: false

      storage:
        type: postgres               # Switch to sqlite for single-instance deployments
        sqlite:
          path: ./data/gateway.db
        postgres:
          host: "postgres.example.internal"
          port: 5432
          database: "gateway_controller"
          user: "gateway"
          sslmode: require
          max_open_conns: 25
          max_idle_conns: 5
          conn_max_lifetime: 30m
          conn_max_idle_time: 5m

      controlplane:
        insecure_skip_verify: false
        reconnect_initial: 1s
        reconnect_max: 5m
        polling_interval: 15m
        deployment_push_enabled: true
        sync_batch_size: 50
        gateway_name: "prod-gateway"

      encryption:
        providers:
          - type: aesgcm
            keys:
              - version: aesgcm256-v1
                file: /app/data/aesgcm-keys/default-aesgcm256-v1.bin

      logging:
        level: info
        format: json

    router:
      gateway_host: "*"
      access_logs:
        enabled: true
        format: json
      listener_port: 8080
      https_enabled: true
      https_port: 8443
      downstream_tls:
        cert_path: "./listener-certs/default-listener.crt"
        key_path: "./listener-certs/default-listener.key"
        minimum_protocol_version: TLS1_2
        maximum_protocol_version: TLS1_3
        # Remove weak ciphers — keep only AEAD ciphers
        ciphers: "ECDHE-ECDSA-AES256-GCM-SHA384,ECDHE-RSA-AES256-GCM-SHA384,ECDHE-ECDSA-AES128-GCM-SHA256,ECDHE-RSA-AES128-GCM-SHA256"
      upstream:
        tls:
          minimum_protocol_version: TLS1_2
          maximum_protocol_version: TLS1_3
          ciphers: "ECDHE-ECDSA-AES256-GCM-SHA384,ECDHE-RSA-AES256-GCM-SHA384,ECDHE-ECDSA-AES128-GCM-SHA256,ECDHE-RSA-AES128-GCM-SHA256"
          trusted_cert_path: /etc/ssl/certs/ca-certificates.crt
          verify_host_name: true
          disable_ssl_verification: false
        timeouts:
          route_timeout_ms: 60000
          route_idle_timeout_ms: 300000
          connect_timeout_ms: 5000
      policy_engine:
        mode: uds
        timeout_ms: 60000
        failure_mode_allow: false    # Fail closed — deny requests if policy engine is unavailable
        route_cache_action: RETAIN

    policy_engine:
      server:
        extproc_port: 9001
      admin:
        enabled: true
        port: 9002
        allowed_ips:
          - "127.0.0.1"             # Restrict admin to localhost only in production
      config_mode:
        mode: xds
      xds:
        connect_timeout: 10s
        request_timeout: 5s
        initial_reconnect_delay: 1s
        max_reconnect_delay: 60s
        tls:
          enabled: false
      logging:
        level: info
        format: json

  # ── Gateway Controller ──────────────────────────────────────────
  controller:
    image:
      repository: ghcr.io/wso2/api-platform/gateway-controller
      tag: "1.2.0"
      pullPolicy: IfNotPresent       # Avoid Always in production for stability

    service:
      type: ClusterIP
      ports:
        rest: 9090
        xds: 18000
        policy: 18001
        admin: 9092
        metrics: 9091

    controlPlane:
      host: "apim.example.com"       # Your control plane hostname
      port: 8443
      token:
        secretName: "gateway-cp-token"
        key: token

    tls:
      enabled: true
      certificateProvider: cert-manager
      certManager:
        create: true
        createIssuer: false
        issuerRef:
          name: letsencrypt-prod
          kind: ClusterIssuer
        commonName: "gateway.example.com"
        dnsNames:
          - "gateway.example.com"
        duration: 2160h
        renewBefore: 720h

    upstreamCerts:
      enabled: false

    encryptionKeys:
      enabled: true
      secretName: "gateway-encryption-keys"
      mountPath: /app/data/aesgcm-keys

    logging:
      level: info

    storage:
      type: postgres                 # Use sqlite for single-instance; postgres removes this constraint
      sqlitePath: ./data/gateway.db  # Ignored when type=postgres

    # PostgreSQL password secret — required when storage.type=postgres
    postgres:
      passwordSecretRef:
        name: "gateway-postgres-password"
        key: password

    persistence:
      enabled: false                 # Set to true with a storageClass if using SQLite

    deployment:
      enabled: true
      replicaCount: 1                # Can be >1 when using PostgreSQL storage
      volumeMountPath: /app/data
      extraEnv: []
      extraEnvFrom: []
      resources:
        requests:
          cpu: 250m
          memory: 256Mi
        limits:
          cpu: 500m
          memory: 512Mi
      livenessProbe:
        httpGet:
          path: /api/admin/v0.9/health
          port: admin
        initialDelaySeconds: 10
        periodSeconds: 10
        timeoutSeconds: 5
        failureThreshold: 3
      readinessProbe:
        httpGet:
          path: /api/admin/v0.9/health
          port: admin
        initialDelaySeconds: 5
        periodSeconds: 5
        timeoutSeconds: 3
        failureThreshold: 3
      podSecurityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      nodeSelector: {}
      tolerations: []
      affinity: {}

  # ── Gateway Runtime ─────────────────────────────────────────────
  gatewayRuntime:
    image:
      repository: ghcr.io/wso2/api-platform/gateway-runtime
      tag: "1.2.0"
      pullPolicy: IfNotPresent

    service:
      type: LoadBalancer
      annotations: {}                # Add cloud LB annotations here (e.g., AWS NLB)
      ports:
        http: 8080
        https: 8443
        envoyAdmin: 9901
        policyEngineAdmin: 9002
        policyEngineMetrics: 9003

    policies:
      llmPricing:
        enabled: true

    deployment:
      enabled: true
      replicaCount: 2                # Minimum 2 for HA; HPA will scale beyond this
      env:
        logLevel: info
        moesifKey: ""
      extraEnv: []
      extraEnvFrom: []
      resources:
        requests:
          cpu: 500m
          memory: 512Mi
        limits:
          cpu: 2000m
          memory: 2Gi
      livenessProbe:
        exec:
          command: ["health-check.sh"]
        initialDelaySeconds: 30
        periodSeconds: 10
        timeoutSeconds: 5
        failureThreshold: 3
      readinessProbe:
        exec:
          command: ["health-check.sh"]
        initialDelaySeconds: 10
        periodSeconds: 5
        timeoutSeconds: 3
        failureThreshold: 6
      podSecurityContext:
        runAsNonRoot: true
        runAsUser: 1000
      # Spread pods across nodes for HA
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app.kubernetes.io/component: gateway-runtime
                topologyKey: kubernetes.io/hostname
      nodeSelector: {}
      tolerations: []


Post-deployment Verification

# All pods running
kubectl get pods -n ap-gateway

# Controller health check (admin port 9092)
kubectl exec -n ap-gateway deploy/ap-gateway-controller -- \
  wget -qO- http://localhost:9092/api/admin/v0.9/health

# Runtime service endpoint
kubectl get svc -n ap-gateway

# Check certificates are issued (cert-manager)
kubectl get certificate -n ap-gateway

# HPA status (if applied)
kubectl get hpa -n ap-gateway

# View controller logs
kubectl logs -n ap-gateway deploy/ap-gateway-controller --follow

# View runtime logs
kubectl logs -n ap-gateway deploy/ap-gateway-gateway-runtime --follow

Verify the Management API (Developer)
The management API is on port 9090 under the base path /api/management/v0.9/.
kubectl port-forward -n ap-gateway svc/ap-gateway-controller 9090:9090

Create a test API:
curl -s -X POST http://localhost:9090/api/management/v0.9/rest-apis \
  -u admin:admin \
  -H "Content-Type: application/yaml" \
  --data-binary @kubernetes/helm/gateway-helm-chart/files/examples/petstore-api.yaml | jq .status

List all APIs:
curl -s http://localhost:9090/api/management/v0.9/rest-apis \
  -u admin:admin | jq '[.[] | {name: .metadata.name, state: .status.state}]'
If using PostgreSQL, confirm the API is persisted in the database:

kubectl exec -n ap-gateway pod/postgres -- \
  psql -U gateway -d gateway_controller \
  -c "SELECT a.handle, a.display_name, a.version, a.desired_state FROM artifacts a JOIN rest_apis r ON a.gateway_id = r.gateway_id AND a.uuid = r.uuid;"


Upgrade Procedure

# Pull latest chart values schema to see what changed
helm show values oci://ghcr.io/wso2/api-platform/helm-charts/gateway --version <new-version>

# Diff current release vs new chart (requires helm-diff plugin)
helm diff upgrade ap-gateway oci://ghcr.io/wso2/api-platform/helm-charts/gateway \
  --version <new-version> \
  --namespace ap-gateway \
  --values ./production-values.yaml

# Upgrade
helm upgrade ap-gateway oci://ghcr.io/wso2/api-platform/helm-charts/gateway \
  --version <new-version> \
  --namespace ap-gateway \
  --values ./production-values.yaml \
  --wait \
  --timeout 5m

# Rollback if needed
helm rollback ap-gateway --namespace ap-gateway

The controller pod restarts on upgrade. Because the gateway runtime syncs policy configuration via xDS from the controller, keep the runtime replicaCount at ≥ 2 so in-flight requests continue to be served during controller restarts.


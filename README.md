# Private Cloud Platform - WSO2 API Manager Setup

## Overview

WSO2 API Manager 4.7.0 deployed on a local kind Kubernetes cluster with MySQL as the backing database.

---

## Directory Structure

```
.
├── apim-4.7/           # Helm chart values for WSO2 APIM all-in-one deployment
    ├── mysql.sql       # shared_db schema (REG_* + UM_* tables)
│   ├── apimgt_mysql.sql # apim_db schema (IDN_* + AM_* tables)
│   ├── wso2carbon.jks
│   └── client-truststore.jks
├── wso2am-custom/      # Custom Docker image and DB init scripts
│   ├── Dockerfile
└── self-hosted-gw/     # Self-hosted gateway values
```

---

## Changes Made

### 1. Custom Docker Image (`wso2am-custom/Dockerfile`)

The base `wso2/wso2am:4.7.0` image does not include the MySQL JDBC driver. A custom image was built that adds it:

```dockerfile
FROM wso2/wso2am:4.7.0
ADD --chown=wso2carbon:wso2 \
  https://repo1.maven.org/maven2/mysql/mysql-connector-java/8.0.28/mysql-connector-java-8.0.28.jar \
  /home/wso2carbon/wso2am-4.7.0/repository/components/lib/
```

**Built and pushed to:** `thushi1214/productapim:4.7.0`

> **Note:** The image must be built for `linux/arm64` for local kind clusters on Apple Silicon:
> ```bash
> docker build --platform linux/arm64 -t thushi1214/productapim:4.7.0 ./wso2am-custom
> docker push thushi1214/productapim:4.7.0
> kind load docker-image thushi1214/productapim:4.7.0 --name controlplane
> ```

---

### 2. MySQL Database Setup

MySQL 8.0 is deployed as a Helm release (`wso2-mysql`) in the `apim` namespace.

**Databases and users created:**

```sql
CREATE DATABASE apim_db CHARACTER SET latin1;
CREATE DATABASE shared_db CHARACTER SET latin1;

CREATE USER 'sharedadmin'@'%' IDENTIFIED BY 'sharedadmin';
GRANT ALL ON apim_db.* TO 'apimadmin'@'%';
GRANT ALL ON shared_db.* TO 'apimadmin'@'%';
GRANT ALL ON shared_db.* TO 'sharedadmin'@'%';
```

**Schemas loaded:**

```bash
# Registry + User Management tables → shared_db
kubectl cp wso2am-custom/mysql.sql apim/wso2-mysql:/tmp/mysql.sql
kubectl exec -n apim wso2-mysql -- bash -c "mysql -uroot -prootpassword shared_db < /tmp/mysql.sql"

# Identity + APIM tables → apim_db
kubectl cp wso2am-custom/apimgt_mysql.sql apim/wso2-mysql:/tmp/apimgt_mysql.sql
kubectl exec -n apim wso2-mysql -- bash -c "mysql -uroot -prootpassword apim_db < /tmp/apimgt_mysql.sql"
```

Result: `apim_db` (247 tables), `shared_db` (51 tables).

---

### 3. Helm Values (`apim-4.7/values.yaml`)

#### Custom image

```yaml
wso2:
  deployment:
    image:
      registry: "docker.io"
      repository: "thushi1214/productapim"
      tag: "4.7.0"
      digest: ""
      imagePullPolicy: IfNotPresent  # changed from Always — kind cluster has no internet access
```

`imagePullPolicy` changed to `IfNotPresent` because the kind cluster nodes cannot reach Docker Hub at runtime. The image is pre-loaded via `kind load docker-image`.

#### JDBC URLs — `allowPublicKeyRetrieval`

MySQL 8 uses `caching_sha2_password` by default. Without `allowPublicKeyRetrieval=true`, the connector throws:
> `Public Key Retrieval is not allowed`

The `&` must be XML-escaped as `&amp;` because WSO2's config mapper writes the URL into an XML datasource file:

```yaml
databases:
  apim_db:
    url: "jdbc:mysql://wso2-mysql.apim.svc.cluster.local:3306/apim_db?useSSL=false&amp;allowPublicKeyRetrieval=true"
  shared_db:
    url: "jdbc:mysql://wso2-mysql.apim.svc.cluster.local:3306/shared_db?useSSL=false&amp;allowPublicKeyRetrieval=true"
```

#### Startup probe

WSO2 APIM takes ~5–7 minutes to fully start on a resource-constrained kind cluster. The default probe window (60s initial + 5×10s = 110s) was too short:

```yaml
startupProbe:
  initialDelaySeconds: 60
  periodSeconds: 10
  failureThreshold: 90   # 60 + 90×10 = 960s (16 min) window
```

---

### 4. CoreDNS Fix

After a cluster restart, CoreDNS pods were stuck in `0/1 Ready` with `Failed to watch plugin/kubernetes` errors. APIM could not resolve `wso2-mysql.apim.svc.cluster.local`.

**Fix:** Roll restart CoreDNS:
```bash
kubectl rollout restart deployment/coredns -n kube-system
```

---

## Deploying / Upgrading

```bash
helm upgrade apim wso2/wso2am-all-in-one --version 4.7.0-1 \
  -n apim \
  -f apim-4.7/values.yaml
```

## Accessing the Consoles

Add to `/etc/hosts`:
```
<GATEWAY_EXTERNAL_IP>  am.wso2.com gw.wso2.com websub.wso2.com websocket.wso2.com
```

| Console    | URL                                  |
|------------|--------------------------------------|
| Publisher  | https://am.wso2.com/publisher        |
| DevPortal  | https://am.wso2.com/devportal        |
| Admin      | https://am.wso2.com/admin            |

Default credentials: `admin` / `admin`

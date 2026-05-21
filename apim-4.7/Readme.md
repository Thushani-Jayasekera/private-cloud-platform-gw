helm repo add wso2 https://helm.wso2.com && helm repo update

helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.0 -n envoy-gateway-system \
  --set config.envoyGateway.extensionApis.enableBackend=true \
  --set envoyGateway.gateway.experimentalFeatures.enabled=true \
  --create-namespace

kubectl exec -it gateway-postgres-postgresql-0 -n ap-gateway -- \
psql -U gateway -d postgres

postgres=> CREATE DATABASE shared_db;

postgres=> CREATE DATABASE apim_db;

apim=> grant all privileges on database shared_db to gateway;  

apim=> grant all privileges on database apim_db to gateway;  

kubectl exec -i gateway-postgres-postgresql-0 -n ap-gateway -- \
env PGPASSWORD='postgres' \
psql -U gateway -d  shared_db < ./shared_db.sql

kubectl exec -i gateway-postgres-postgresql-0 -n ap-gateway -- \
env PGPASSWORD='postgres' \
psql -U gateway -d  apim_db < ./apim_db.sql


```
databases:
        # -- Database type. eg: mysql, oracle, mssql, postgres
        type: "postgre"
        jdbc:
          # -- JDBC driver class name
          driver: "org.postgresql.Driver"
        # -- APIM AM_DB configurations.
        apim_db:
          # -- APIM AM_DB URL
          url: "jdbc:postgresql://gateway-postgres-postgresql.ap-gateway.svc.cluster.local:5432/apim_db?useSSL=false"
          # -- APIM AM_DB username
          username: "gateway"
          # -- APIM AM_DB password
          password: "postgres"
          # -- APIM database JDBC pool parameters
          poolParameters:
            defaultAutoCommit: true
            testOnBorrow: true
            testWhileIdle: true
            validationInterval: 30000
            maxActive: 100
            maxWait: 60000
            minIdle: 5
        # -- APIM SharedDB configurations.
        shared_db:
          # -- APIM SharedDB URL
          url: "jdbc:postgresql://gateway-postgres-postgresql.ap-gateway.svc.cluster.local:5432/shared_db?useSSL=false"
          # -- APIM SharedDB username
          username: "gateway"
          # -- APIM SharedDB password
          password: "postgres"
          # -- APIM shared database JDBC pool parameters
          poolParameters:
            defaultAutoCommit: true
            testOnBorrow: true
            testWhileIdle: true
            validationInterval: 30000
            maxActive: 100
            maxWait: 60000
            minIdle: 5
```

```
    image:
      # -- Container registry credentials.
      # Specify image pull secrets for private registries
      imagePullSecrets:
        enabled: false
        username: ""
        password: ""
      # -- Container registry hostname
      registry: "docker.io"
      # -- Azure ACR repository name consisting the image
      repository: "thushi1214/wso2am-postgres"
      # -- Docker image tag
      tag: "4.7.0"
      # -- Docker image digest
      digest: "sha256:07c1cd8f5329cc45034a71518868067a0b4a486c97fd8ef573b1233194dbd7ab"
      # -- Refer to the Kubernetes documentation on updating images (https://kubernetes.io/docs/concepts/containers/images/#updating-images)
      imagePullPolicy: Always
```

docker run --rm -v "$(pwd)/keystores:/keystores" --entrypoint bash wso2/wso2am:4.7.0 -c "cp /home/wso2carbon/wso2am-4.7.0/repository/resources/security/wso2carbon.jks /home/wso2carbon/wso2am-4.7.0/repository/resources/security/client-truststore.jks /keystores/"

kubectl create secret generic apim-keystore-secret \
  --from-file=keystores/wso2carbon.jks \
  --from-file=keystores/client-truststore.jks \
  -n apim

openssl rand -hex 32 - replace values.yaml

helm install apim wso2/wso2am-all-in-one \
  --version 4.7.0-1 \
  --namespace apim --create-namespace \
  --dependency-update \
  -f values.yaml

(helm uninstall apim -n apim)

MSSQL Deployment setup

  kubectl apply -f apim-4.7/mysql-schema-configmaps.yaml

  # Apply updated deployment (renames key + projected volumes)
  kubectl apply -f apim-4.7/mysql-deployment.yaml

  # Delete the existing MySQL pod to force re-initialization
  kubectl delete pod -n apim -l app=wso2-mysql


  kubectl exec -n apim apim-wso2am-all-in-one-am-deployment-1-58df79f7c6-wbt77 -- \
        curl -sk -X POST "https://localhost:9443/oauth2/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=password&username=thushani&password=thushani&scope=apim:admin" \
        -u "HCyqItmC6zio5mOfFHyorYhtbQIa:QffIimKDBMHhqk46WcX5bKqFdega" 2>&1)
{
       "access_token": "b854979a-98bf-3625-902c-fdc1d2eaf5ee",
       "refresh_token": "367fa5cc-11f8-3ef3-8614-cc227b04ff6d",
       "scope": "apim:admin",
       "token_type": "Bearer",
       "expires_in": 3600
     }

(kubectl exec -n apim apim-wso2am-all-in-one-am-deployment-1-58df79f7c6-wbt77 -- \
        curl -sk -X POST "https://localhost:9443/api/am/admin/v4/gateways" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer b854979a-98bf-3625-902c-fdc1d2eaf5ee" \
        -d '{
          "name": "prod-gateway",
          "type": "APK",
          "description": "Self-hosted production gateway",
          "displayInApiConsole": false
        }' 2>&1)
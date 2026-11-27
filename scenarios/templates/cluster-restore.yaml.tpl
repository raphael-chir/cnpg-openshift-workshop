apiVersion: postgresql.k8s.enterprisedb.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}-restore
  namespace: ${NAMESPACE}

spec:
  imageName: docker.enterprisedb.com/k8s/postgresql:18
  instances: 1

  enableSuperuserAccess: true

  storage:
    size: 1Gi

  walStorage:
    size: 1Gi

  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: 128MB
      log_checkpoints: "on"
      log_lock_waits: "on"
      log_min_duration_statement: "1000"

  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: "1"
      memory: 1Gi

  bootstrap:
    recovery:
      source: ${CLUSTER_NAME}

  externalClusters:
    - name: ${CLUSTER_NAME}
      barmanObjectStore:
        destinationPath: "s3://cnpg/"
        endpointURL: "http://minio.minio-system.svc.cluster.local:9000"
        serverName: ${CLUSTER_NAME}
        s3Credentials:
          accessKeyId:
            name: minio-creds
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: minio-creds
            key: ACCESS_SECRET_KEY

  backup:
    barmanObjectStore:
      destinationPath: "s3://cnpg/"
      endpointURL: "http://minio.minio-system.svc.cluster.local:9000"
      serverName: ${CLUSTER_NAME}-restore
      s3Credentials:
        accessKeyId:
          name: minio-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: minio-creds
          key: ACCESS_SECRET_KEY
      data:
        immediateCheckpoint: true
    retentionPolicy: "1d"

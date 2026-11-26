apiVersion: postgresql.k8s.enterprisedb.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${NAMESPACE}
spec:
  imageName: docker.enterprisedb.com/k8s/postgresql:17.6
  instances: 3

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
    synchronous:
      method: any
      number: 1
      dataDurability: preferred

  replicationSlots:
    highAvailability:
      enabled: true
    updateInterval: 30

  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: "1"
      memory: 1Gi

  backup:
    barmanObjectStore:
      destinationPath: "s3://cnpg/"
      endpointURL: "http://minio.minio-system.svc.cluster.local:9000"
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

# Foot Cup Sim, user interfaces: Swagger UI (API documentation) and the React UI (the simulator).
# Rendered by setup/init-workshop.sh with envsubst: only ${CLUSTER_NAME} and ${NAMESPACE} are substituted.
# Not here: the Routes, created with "oc create route", and the public URLs. The browser calls PostgREST directly, so both
# Deployments receive the PostgREST Route URL after deployment with "oc set env":
#   worldcup-swagger: URL (the OpenAPI document that Swagger UI loads)
#   worldcup-ui:      API_URL (the image entrypoint writes it into /config.js, read by the browser at runtime)
#
# --- Swagger UI ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worldcup-swagger
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: foot-cup-sim
spec:
  replicas: 1
  selector:
    matchLabels:
      app: worldcup-swagger
  template:
    metadata:
      labels:
        app: worldcup-swagger
    spec:
      containers:
        - name: swagger-ui
          image: docker.io/swaggerapi/swagger-ui:v5.36.0
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /
              port: http
            periodSeconds: 5
          resources:
            requests:
              cpu: 20m
              memory: 32Mi
            limits:
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
---
apiVersion: v1
kind: Service
metadata:
  name: worldcup-swagger
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: foot-cup-sim
spec:
  selector:
    app: worldcup-swagger
  ports:
    - name: http
      port: 8080
      targetPort: http
---
# --- React UI ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worldcup-ui
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: foot-cup-sim
spec:
  replicas: 1
  selector:
    matchLabels:
      app: worldcup-ui
  template:
    metadata:
      labels:
        app: worldcup-ui
    spec:
      containers:
        - name: worldcup-ui
          image: ghcr.io/raphael-chir/worldcup-ui:1.0
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /
              port: http
            periodSeconds: 5
          resources:
            requests:
              cpu: 20m
              memory: 32Mi
            limits:
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
---
apiVersion: v1
kind: Service
metadata:
  name: worldcup-ui
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: foot-cup-sim
spec:
  selector:
    app: worldcup-ui
  ports:
    - name: http
      port: 8080
      targetPort: http

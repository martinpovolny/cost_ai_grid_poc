#!/usr/bin/env bash
set -euo pipefail

# Deploy IPP gateway stack (Istio Gateway + ext_proc + llm-katan) to k3s.
# Expects: kubectl configured, Helm installed, Istio installed,
#           Gateway API CRDs applied, IPP repo cloned at /tmp/ipp,
#           cost-event-consumer deployed in cost-mgmt namespace.

echo "--- Deploying IPP gateway stack ---"

# ── 1. Namespace ──
kubectl create namespace ai-gateway --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace ai-gateway istio-injection=enabled --overwrite

# ── 2. IPP CRDs ──
echo "Applying IPP CRDs..."
kubectl apply -f /tmp/ipp/config/crd/bases/

# ── 3. Istio Gateway ──
echo "Creating Istio Gateway..."
cat <<'K8S' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ai-gateway
  namespace: ai-gateway
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
K8S

echo "Waiting for Gateway to be programmed..."
kubectl wait --for=condition=Programmed gateway/ai-gateway -n ai-gateway --timeout=120s

# ── 4. llm-katan ──
echo "Deploying llm-katan..."
cat <<'K8S' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-katan
  namespace: ai-gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: llm-katan
  template:
    metadata:
      labels:
        app: llm-katan
    spec:
      containers:
        - name: katan
          image: docker.io/library/llm-katan:ci
          imagePullPolicy: Never
          ports:
            - containerPort: 8000
          env:
            # Override K8s-injected LLM_KATAN_PORT=tcp://... collision
            - name: LLM_KATAN_PORT
              value: "8000"
---
apiVersion: v1
kind: Service
metadata:
  name: llm-katan
  namespace: ai-gateway
spec:
  ports:
    - port: 8000
  selector:
    app: llm-katan
K8S

# ── 5. IPP via Helm ──
echo "Installing IPP via Helm..."
cat > /tmp/ipp-values.yaml <<'EOF'
upstreamIpp:
  payloadProcessor:
    image:
      registry: docker.io/library
      repository: ipp-metering
      tag: ci
      pullPolicy: Never
    env:
    - name: GATEWAY_NAME
      value: "ai-gateway"
    - name: GATEWAY_NAMESPACE
      value: "ai-gateway"
    customConfig:
      plugins:
      - type: maas-headers-guard
      - type: body-field-to-header
        name: model-extractor
        parameters:
          fieldName: model
          headerName: X-Gateway-Model-Name
      - type: external-metering
        name: metering
        parameters:
          meteringURL: "http://cost-event-consumer.cost-mgmt.svc:8020"
          featureKey: "inference-tokens"
          source: "maas-gateway"
          failOpen: true
      - type: api-translation
      profiles:
      - name: default
        plugins:
          request:
          - pluginRef: maas-headers-guard
          - pluginRef: model-extractor
          - pluginRef: metering
          - pluginRef: api-translation
          response:
          - pluginRef: metering
          - pluginRef: api-translation
  provider:
    name: istio
    istio:
      envoyFilter:
        operation: INSERT_FIRST
  inferenceGateway:
    name: ai-gateway
EOF

helm install payload-processing /tmp/ipp/deploy/payload-processing \
    --namespace ai-gateway \
    --dependency-update \
    -f /tmp/ipp-values.yaml

# Disable Istio sidecar on the IPP pod itself
kubectl patch deployment payload-processing -n ai-gateway --type=merge \
    -p='{"spec":{"template":{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}}}'

# ── 6. HTTPRoute ──
echo "Creating HTTPRoute..."
cat <<'K8S' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llm-route
  namespace: ai-gateway
spec:
  parentRefs:
    - name: ai-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1/
      backendRefs:
        - name: llm-katan
          port: 8000
K8S

# ── 7. Wait for everything ──
echo "Waiting for deployments..."
kubectl wait --for=condition=available deployment/llm-katan -n ai-gateway --timeout=180s
kubectl wait --for=condition=available deployment/payload-processing -n ai-gateway --timeout=180s

echo ""
echo "--- IPP gateway stack deployed ---"
kubectl get pods -n ai-gateway
kubectl get gateway -n ai-gateway

#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Default values
IMAGE_TAG="latest"
REPLICAS=2
PORT=8080
SERVICE_TYPE="LoadBalancer"
CPU_REQUEST="100m"
CPU_LIMIT="300m"
MEMORY_REQUEST="256Mi"
MEMORY_LIMIT="512Mi"
LIVENESS_PATH="/"
READINESS_PATH="/"
LB_TIMEOUT=300  # Maximum wait time for LoadBalancer IP (in seconds)

# Display usage information
function show_usage {
  echo "Usage: $0 -a APP_NAME -p PORT [-t IMAGE_TAG] [-r REPLICAS] [-s SERVICE_TYPE] [--cpu-request CPU_REQUEST] [--cpu-limit CPU_LIMIT] [--memory-request MEMORY_REQUEST] [--memory-limit MEMORY_LIMIT] [--liveness-path LIVENESS_PATH] [--readiness-path READINESS_PATH]"
  echo ""
  echo "Required arguments:"
  echo "  -a APP_NAME    Name of the application (used for ECR repository name)"
  echo "  -p PORT        Container port to expose"
  echo ""
  echo "Optional arguments:"
  echo "  -t IMAGE_TAG        Tag for the image to deploy (default: latest)"
  echo "  -r REPLICAS         Number of replicas to deploy (default: 2)"
  echo "  -s SERVICE_TYPE     Kubernetes service type (default: LoadBalancer)"
  echo "  --cpu-request       CPU request for containers (default: 100m)"
  echo "  --cpu-limit         CPU limit for containers (default: 300m)"
  echo "  --memory-request    Memory request for containers (default: 256Mi)"
  echo "  --memory-limit      Memory limit for containers (default: 512Mi)"
  echo "  --liveness-path     Path for liveness probe (default: /)"
  echo "  --readiness-path    Path for readiness probe (default: /)"
  echo "  -h                  Show this help message"
  exit 1
}

# Parse command line arguments
while (( "$#" )); do
  case "$1" in
    -a|--app-name)
      APP_NAME=$2
      shift 2
      ;;
    -p|--port)
      PORT=$2
      shift 2
      ;;
    -t|--image-tag)
      IMAGE_TAG=$2
      shift 2
      ;;
    -r|--replicas)
      REPLICAS=$2
      shift 2
      ;;
    -s|--service-type)
      SERVICE_TYPE=$2
      shift 2
      ;;
    --cpu-request)
      CPU_REQUEST=$2
      shift 2
      ;;
    --cpu-limit)
      CPU_LIMIT=$2
      shift 2
      ;;
    --memory-request)
      MEMORY_REQUEST=$2
      shift 2
      ;;
    --memory-limit)
      MEMORY_LIMIT=$2
      shift 2
      ;;
    --liveness-path)
      LIVENESS_PATH=$2
      shift 2
      ;;
    --readiness-path)
      READINESS_PATH=$2
      shift 2
      ;;
    -h|--help)
      show_usage
      ;;
    -*|--*=) # unsupported flags
      echo "Error: Unsupported flag $1" >&2
      show_usage
      ;;
    *) # preserve positional arguments
      PARAMS="$PARAMS $1"
      shift
      ;;
  esac
done

# Check required arguments
if [ -z "$APP_NAME" ] || [ -z "$PORT" ]; then
  echo "Error: APP_NAME and PORT are required arguments"
  show_usage
fi

# Get AWS account ID and region
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=$(aws configure get region)

echo "=== Deploying $APP_NAME to EKS ==="
echo "APP_NAME: $APP_NAME"
echo "PORT: $PORT"
echo "IMAGE_TAG: $IMAGE_TAG"
echo "REPLICAS: $REPLICAS"
echo "SERVICE_TYPE: $SERVICE_TYPE"
echo "AWS_ACCOUNT_ID: $AWS_ACCOUNT_ID"
echo "AWS_REGION: $AWS_REGION"
echo ""

echo "=== Step 1: Creating deployment manifest ==="
# Create deployment manifest
cat > "/tmp/${APP_NAME}-deployment.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: default
  labels:
    app: ${APP_NAME}
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      containers:
      - name: ${APP_NAME}
        image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${APP_NAME}:${IMAGE_TAG}
        ports:
        - containerPort: ${PORT}
        resources:
          requests:
            memory: "${MEMORY_REQUEST}"
            cpu: "${CPU_REQUEST}"
          limits:
            memory: "${MEMORY_LIMIT}"
            cpu: "${CPU_LIMIT}"
        readinessProbe:
          httpGet:
            path: ${READINESS_PATH}
            port: ${PORT}
          initialDelaySeconds: 10
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: ${LIVENESS_PATH}
            port: ${PORT}
          initialDelaySeconds: 15
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: default
  labels:
    app: ${APP_NAME}
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol: "HTTP"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-path: "/_stcore/health"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-port: "8501"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval: "15"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-timeout: "5"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-healthy-threshold: "2"
    service.beta.kubernetes.io/aws-load-balancer-healthcheck-unhealthy-threshold: "2"
spec:
  type: ${SERVICE_TYPE}
  ports:
  - port: 80
    targetPort: ${PORT}
    protocol: TCP
  selector:
    app: ${APP_NAME}
EOF

echo "=== Step 2: Deploying application to EKS ==="

# Use --force flag and pipe to cat to avoid interactive prompts
kubectl delete deployment streamlit-app --force 2>/dev/null | cat || true
kubectl delete service streamlit-app --force 2>/dev/null | cat || true

kubectl apply -f "/tmp/${APP_NAME}-deployment.yaml" | cat

echo "=== Step 3: Waiting for deployment to be ready ==="
kubectl rollout status "deployment/${APP_NAME}" --timeout=300s | cat

# Check if LoadBalancer is assigned an external IP
if [ "$SERVICE_TYPE" = "LoadBalancer" ]; then
  echo "=== Step 4: Waiting for LoadBalancer to get an external IP ==="
  SECONDS=0
  EXTERNAL_IP=""
  
  while [ -z "$EXTERNAL_IP" ] || [ "$EXTERNAL_IP" = "<pending>" ]; do
    if [ "$SECONDS" -ge "$LB_TIMEOUT" ]; then
      echo "⛔ ERROR: LoadBalancer did not receive an external IP within $LB_TIMEOUT seconds."
      exit 1
    fi
    echo "⏳ Waiting for LoadBalancer external IP... (elapsed time: $SECONDS seconds)"
    sleep 10
    #wait-for-lb $(kubectl get service -n ui ui-nlb -o jsonpath="{.status.loadBalancer.ingress[*].hostname}{'\n'}")
    EXTERNAL_IP=$(kubectl get service "${APP_NAME}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null | cat || echo "")
  done

  echo ""
  echo "====================== DEPLOYMENT COMPLETE ======================"
  echo "✅ Application is accessible at: http://${EXTERNAL_IP}"
  echo "==============================================================="
else
  echo ""
  echo "====================== DEPLOYMENT COMPLETE ======================"
  echo "Service type is $SERVICE_TYPE. Access your application accordingly."
  echo "To use port-forwarding: kubectl port-forward service/${APP_NAME} 8080:80"
  echo "==============================================================="
fi

# Cleanup
rm -f "/tmp/${APP_NAME}-deployment.yaml"

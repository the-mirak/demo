#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Default values
DOCKERFILE_PATH="Dockerfile"
IMAGE_TAG="latest"
ENABLE_CACHE="true"
CLEANUP_AFTER_BUILD="true"
USE_IRSA="true"

# Parse command line arguments
while getopts ":a:s:d:t:c:p:inh" opt; do
  case ${opt} in
    a) APP_NAME=$OPTARG ;;
    s) S3_BUCKET=$OPTARG ;;
    d) DOCKERFILE_PATH=$OPTARG ;;
    t) IMAGE_TAG=$OPTARG ;;
    c) ENABLE_CACHE=$OPTARG ;;
    p) APP_PATH=$OPTARG ;;
    i) USE_IRSA="true" ;;
    n) CLEANUP_AFTER_BUILD="false" ;;
    h) show_usage ;;
    \?) echo "Invalid option: -$OPTARG" 1>&2; show_usage ;;
    :) echo "Option -$OPTARG requires an argument." 1>&2; show_usage ;;
  esac
done

# Ensure required parameters
if [ -z "$APP_NAME" ] || [ -z "$S3_BUCKET" ]; then
  echo "❌ Error: APP_NAME and S3_BUCKET are required"
  show_usage
fi

# Get AWS account details
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region)

echo "=== Step 1: Ensuring ECR repositories exist ==="

# Ensure the main application repository exists
aws ecr describe-repositories --repository-names "$APP_NAME" >/dev/null 2>&1 || \
aws ecr create-repository --repository-name "$APP_NAME"

# Ensure the per-app cache repository exists (`<APP_NAME>/cache`)
CACHE_REPO="${APP_NAME}/cache"
aws ecr describe-repositories --repository-names "$CACHE_REPO" >/dev/null 2>&1 || \
aws ecr create-repository --repository-name "$CACHE_REPO"

echo "✅ ECR repositories are set up successfully!"

# Step 2: Upload Build Context to S3
echo "=== Step 2: Uploading build context to S3 ==="
tar -czf "/tmp/${APP_NAME}.tar.gz" -C "${APP_PATH}" .
aws s3 cp "/tmp/${APP_NAME}.tar.gz" "s3://${S3_BUCKET}/${APP_NAME}.tar.gz"

# Step 3: Generate Kaniko Pod Manifest
echo "=== Step 3: Creating Kaniko pod manifest ==="
cat > "/tmp/${APP_NAME}-kaniko-pod.yaml" << EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${APP_NAME}-kaniko-builder
  namespace: default
spec:
  serviceAccountName: kaniko-builder
  restartPolicy: Never
  containers:
  - name: kaniko
    image: gcr.io/kaniko-project/executor:latest
    args:
    - "--dockerfile=${DOCKERFILE_PATH}"
    - "--context=s3://${S3_BUCKET}/${APP_NAME}.tar.gz"
    - "--destination=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${APP_NAME}:${IMAGE_TAG}"
    - "--cache=${ENABLE_CACHE}"
    - "--cache-repo=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${CACHE_REPO}"
    - "--cleanup"
EOF

# Step 4: Delete Existing Pod if It Exists
echo "=== Step 4: Deleting any existing Kaniko pod ==="
kubectl delete pod "${APP_NAME}-kaniko-builder" --namespace default --ignore-not-found | cat

# Step 5: Run Kaniko Build
echo "=== Step 5: Running Kaniko Build ==="
kubectl apply -f "/tmp/${APP_NAME}-kaniko-pod.yaml"

# Step 6: Wait for Pod Initialization
echo "Waiting for Kaniko pod to start..."
kubectl wait --for=condition=Initialized pod/${APP_NAME}-kaniko-builder --timeout=60s | cat || \
{ echo "❌ Kaniko pod failed to initialize! Fetching events..."; kubectl describe pod/${APP_NAME}-kaniko-builder; exit 1; }

# Step 7: Stream Logs in Real-Time
echo "Build started. Streaming logs..."
kubectl logs -f "${APP_NAME}-kaniko-builder"

# Step 8: Check if Pod Already Completed
POD_STATUS=$(kubectl get pod ${APP_NAME}-kaniko-builder -o jsonpath='{.status.phase}')
if [ "$POD_STATUS" == "Succeeded" ]; then
  echo "✅ Kaniko build completed successfully!"
else
  echo "Waiting for Kaniko pod to complete..."
  kubectl wait --for=condition=complete pod/${APP_NAME}-kaniko-builder --timeout=600s || \
  { echo "❌ Kaniko build failed! Fetching last 50 log lines..."; kubectl logs "${APP_NAME}-kaniko-builder" | tail -n 50; exit 1; }
fi

echo "✅ Image pushed successfully: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${APP_NAME}:${IMAGE_TAG}"

# Step 9: Cleanup
if [ "$CLEANUP_AFTER_BUILD" = "true" ]; then
  echo "=== Step 9: Cleaning up resources ==="
  kubectl delete pod "${APP_NAME}-kaniko-builder" --force --grace-period=0 | cat || true
  rm -rf "/tmp/${APP_NAME}.tar.gz" "/tmp/${APP_NAME}-kaniko-pod.yaml"
fi

echo ""
echo "====================== BUILD COMPLETE ======================"
echo "You can now deploy your application using the image:"
echo "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${APP_NAME}:${IMAGE_TAG}"
echo "==========================================================="

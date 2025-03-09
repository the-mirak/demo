#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Default values
DOCKERFILE_PATH="Dockerfile"
IMAGE_TAG="latest"
ENABLE_CACHE="true"
CLEANUP_AFTER_BUILD="true"
USE_IRSA="true"

# Display usage information
function show_usage {
  echo "Usage: $0 -a APP_NAME -s S3_BUCKET [-d DOCKERFILE_PATH] [-t IMAGE_TAG] [-c ENABLE_CACHE] [-p APP_PATH] [-i]"
  echo ""
  echo "Required arguments:"
  echo "  -a APP_NAME    Name of the application (used for ECR repository name)"
  echo "  -s S3_BUCKET   S3 bucket name for storing build context"
  echo ""
  echo "Optional arguments:"
  echo "  -d DOCKERFILE_PATH  Path to Dockerfile (default: Dockerfile)"
  echo "  -t IMAGE_TAG        Tag for the built image (default: latest)"
  echo "  -c ENABLE_CACHE     Enable build caching (default: true)"
  echo "  -p APP_PATH         Path to the application files (default: current directory)"
  echo "  -i                  Use IRSA (IAM Roles for Service Accounts) instead of AWS credentials secret"
  echo "  -n                  Do not cleanup temporary files after build"
  echo "  -h                  Show this help message"
  exit 1
}

# Parse command line arguments
while getopts ":a:s:d:t:c:p:inh" opt; do
  case ${opt} in
    a)
      APP_NAME=$OPTARG
      ;;
    s)
      S3_BUCKET=$OPTARG
      ;;
    d)
      DOCKERFILE_PATH=$OPTARG
      ;;
    t)
      IMAGE_TAG=$OPTARG
      ;;
    c)
      ENABLE_CACHE=$OPTARG
      ;;
    p)
      APP_PATH=$OPTARG
      ;;
    i)
      USE_IRSA="true"
      ;;
    n)
      CLEANUP_AFTER_BUILD="false"
      ;;
    h)
      show_usage
      ;;
    \?)
      echo "Invalid option: -$OPTARG" 1>&2
      show_usage
      ;;
    :)
      echo "Option -$OPTARG requires an argument." 1>&2
      show_usage
      ;;
  esac
done

# Check required arguments
if [ -z "$APP_NAME" ] || [ -z "$S3_BUCKET" ]; then
  echo "Error: APP_NAME and S3_BUCKET are required arguments"
  show_usage
fi

# Set default APP_PATH if not provided
if [ -z "$APP_PATH" ]; then
  APP_PATH="."
fi

# Get AWS account ID and region
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=$(aws configure get region)

echo "=== Building $APP_NAME with Kaniko ==="
echo "APP_NAME: $APP_NAME"
echo "S3_BUCKET: $S3_BUCKET"
echo "DOCKERFILE_PATH: $DOCKERFILE_PATH"
echo "IMAGE_TAG: $IMAGE_TAG"
echo "ENABLE_CACHE: $ENABLE_CACHE"
echo "USE_IRSA: $USE_IRSA"
echo "AWS_ACCOUNT_ID: $AWS_ACCOUNT_ID"
echo "AWS_REGION: $AWS_REGION"
echo ""

# Create ECR repository if it doesn't exist - using a non-blocking approach
echo "=== Step 1: Creating ECR repository (if it doesn't exist) ==="
# Check if repository exists
REPO_EXISTS=$(aws ecr describe-repositories --repository-names "$APP_NAME" --query "repositories[0].repositoryName" --output text 2>/dev/null || echo "false")

if [ "$REPO_EXISTS" == "false" ] || [ "$REPO_EXISTS" == "None" ]; then
  echo "Creating ECR repository: $APP_NAME"
  aws ecr create-repository --repository-name "$APP_NAME" --output text > /dev/null
else
  echo "ECR repository $APP_NAME already exists"
fi

# Create Kaniko cache repository if caching is enabled - using a non-blocking approach
if [ "$ENABLE_CACHE" = "true" ]; then
  echo "=== Step 2: Creating Kaniko cache repository (if it doesn't exist) ==="
  # Check if cache repository exists
  CACHE_REPO_EXISTS=$(aws ecr describe-repositories --repository-names kaniko-cache --query "repositories[0].repositoryName" --output text 2>/dev/null || echo "false")
  
  if [ "$CACHE_REPO_EXISTS" == "false" ] || [ "$CACHE_REPO_EXISTS" == "None" ]; then
    echo "Creating ECR repository: kaniko-cache"
    aws ecr create-repository --repository-name kaniko-cache --output text > /dev/null
  else
    echo "ECR repository kaniko-cache already exists"
  fi
fi

# Package application and upload to S3
echo "=== Step 3: Packaging application and uploading to S3 ==="
# Create a temporary directory for packaging
TMP_DIR=$(mktemp -d)
cp -r "$APP_PATH"/* "$TMP_DIR"

# Create a tar.gz archive
cd "$TMP_DIR"
tar -czf "/tmp/${APP_NAME}.tar.gz" .
cd - > /dev/null

# Upload to S3
aws s3 cp "/tmp/${APP_NAME}.tar.gz" "s3://${S3_BUCKET}/${APP_NAME}.tar.gz"

echo "=== Step 4: Creating Kaniko pod manifest ==="
# Create Kaniko pod manifest
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
    - "--cache-repo=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/kaniko-cache"
    - "--cleanup"
    env:
    - name: AWS_SDK_LOAD_CONFIG
      value: "true"
EOF

# Add AWS credentials volume only if not using IRSA
if [ "$USE_IRSA" != "true" ]; then
  cat >> "/tmp/${APP_NAME}-kaniko-pod.yaml" << EOF
    volumeMounts:
    - name: aws-credentials
      mountPath: /kaniko/.aws
  volumes:
  - name: aws-credentials
    secret:
      secretName: aws-credentials
      items:
      - key: credentials
        path: credentials
EOF
fi

echo "=== Step 5: Running Kaniko build ==="
# Apply the Kaniko pod manifest
kubectl apply -f "/tmp/${APP_NAME}-kaniko-pod.yaml" | cat

# Wait for Kaniko pod to become initialized
echo "Waiting for Kaniko build to initialize..."
kubectl wait --for=condition=initialized "pod/${APP_NAME}-kaniko-builder" --timeout=60s | cat

# Follow the Kaniko logs
echo "Build started, following build logs..."
# Use timeout to prevent hanging indefinitely
timeout 600 kubectl logs -f "${APP_NAME}-kaniko-builder" || echo "Log streaming timed out after 10 minutes"

# Wait for the pod to complete
echo "Waiting for build to complete..."
# Use timeout to prevent hanging indefinitely
kubectl wait --for=condition=complete "pod/${APP_NAME}-kaniko-builder" --timeout=180s | cat || true

# Check if build was successful
POD_STATUS=$(kubectl get pod "${APP_NAME}-kaniko-builder" -o jsonpath='{.status.phase}' | cat)
if [ "$POD_STATUS" != "Succeeded" ]; then
  echo "Build failed with status: $POD_STATUS"
  kubectl logs "${APP_NAME}-kaniko-builder" | tail -n 50 | cat
  exit 1
fi

echo "=== Build completed successfully ==="
echo "Image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${APP_NAME}:${IMAGE_TAG}"

# Cleanup
if [ "$CLEANUP_AFTER_BUILD" = "true" ]; then
  echo "=== Cleaning up resources ==="
  kubectl delete pod "${APP_NAME}-kaniko-builder" --force --grace-period=0 | cat || true
  rm -rf "$TMP_DIR" "/tmp/${APP_NAME}.tar.gz" "/tmp/${APP_NAME}-kaniko-pod.yaml"
fi

echo ""
echo "====================== BUILD COMPLETE ======================"
echo "You can now deploy your application using the image:"
echo "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${APP_NAME}:${IMAGE_TAG}"
echo "==========================================================="
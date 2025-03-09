#!/bin/bash

# Pre-deployment preparation script
echo "Starting pre-deployment preparations..."

# Ensure AWS CLI is configured
aws --version

# Check if ECR repository exists, create if not - using a non-blocking approach
ECR_REPO_NAME="streamlit-app"
# Use --output json to avoid pager and redirect stderr to avoid error messages
ECR_REPO_EXISTS=$(aws ecr describe-repositories --repository-names $ECR_REPO_NAME --output json 2>/dev/null || echo "false")

if [ "$ECR_REPO_EXISTS" == "false" ]; then
  echo "Creating ECR repository: $ECR_REPO_NAME"
  aws ecr create-repository --repository-name $ECR_REPO_NAME --output json
else
  echo "ECR repository $ECR_REPO_NAME already exists"
fi

# Check if EKS cluster is accessible - using a non-blocking approach
# Use --output text to avoid pager
EKS_STATUS=$(aws eks describe-cluster --name $EKS_CLUSTER_NAME --query "cluster.status" --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$EKS_STATUS" != "ACTIVE" ]; then
  echo "Error: EKS cluster $EKS_CLUSTER_NAME is not active or not found"
  exit 1
else
  echo "EKS cluster $EKS_CLUSTER_NAME is active"
fi

# Update kubeconfig - using a non-blocking approach
aws eks update-kubeconfig --name $EKS_CLUSTER_NAME --region $AWS_REGION --output text

# Verify kubectl can connect to the cluster - using a non-blocking approach
# Pipe to cat to avoid any pager
KUBECTL_TEST=$(kubectl get nodes 2>/dev/null | cat || echo "FAILED")

if [[ $KUBECTL_TEST == *"FAILED"* ]]; then
  echo "Error: kubectl cannot connect to the EKS cluster"
  exit 1
else
  echo "kubectl successfully connected to the EKS cluster"
fi

echo "Pre-deployment preparations completed successfully!"
exit 0 
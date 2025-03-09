#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Default values
NAMESPACE="default"
ROLE_NAME="kaniko-ecr-push-role"

# Display usage information
function show_usage {
  echo "Usage: $0 [-n NAMESPACE] [-r ROLE_NAME] [-c CLUSTER_NAME]"
  echo ""
  echo "Optional arguments:"
  echo "  -n NAMESPACE     Kubernetes namespace (default: default)"
  echo "  -r ROLE_NAME     IAM role name for Kaniko (default: kaniko-ecr-push-role)"
  echo "  -c CLUSTER_NAME  EKS cluster name (required for IRSA setup)"
  echo "  -i               Use IRSA (IAM Roles for Service Accounts) instead of AWS credentials secret"
  echo "  -h               Show this help message"
  exit 1
}

# Parse command line arguments
USE_IRSA=false
while getopts ":n:r:c:ih" opt; do
  case ${opt} in
    n) NAMESPACE=$OPTARG ;;
    r) ROLE_NAME=$OPTARG ;;
    c) CLUSTER_NAME=$OPTARG ;;
    i) USE_IRSA=true ;;
    h) show_usage ;;
    \?) echo "Invalid option: -$OPTARG" 1>&2; show_usage ;;
    :) echo "Option -$OPTARG requires an argument." 1>&2; show_usage ;;
  esac
done

# Ensure cluster name is provided if using IRSA
if [ "$USE_IRSA" = true ] && [ -z "$CLUSTER_NAME" ]; then
  echo "❌ Error: When using IRSA, CLUSTER_NAME is required"
  show_usage
fi

# Get AWS account ID and region
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region)

echo "=== Initializing Kaniko Environment ==="
echo "NAMESPACE: $NAMESPACE"
echo "ROLE_NAME: $ROLE_NAME"
echo "CLUSTER_NAME: $CLUSTER_NAME"
echo "Using IRSA for authentication"

# Step 1: Ensure OIDC Provider Exists for EKS
OIDC_PROVIDER_URL=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query "cluster.identity.oidc.issuer" --output text)
OIDC_PROVIDER_ARN="arn:aws:iam::$AWS_ACCOUNT_ID:oidc-provider/${OIDC_PROVIDER_URL#https://}"

echo "OIDC Provider: $OIDC_PROVIDER_ARN"

# Step 2: Create IAM Role for IRSA
echo "=== Step 2: Creating IAM Role for IRSA ==="

cat > "/tmp/kaniko-trust-policy.json" << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "$OIDC_PROVIDER_ARN"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER_URL#https://}:sub": "system:serviceaccount:$NAMESPACE:kaniko-builder"
        }
      }
    }
  ]
}
EOF

ROLE_EXISTS=$(aws iam get-role --role-name "$ROLE_NAME" --query "Role.RoleName" --output text 2>/dev/null || echo "None")

if [ "$ROLE_EXISTS" == "None" ]; then
  echo "Creating IAM role: $ROLE_NAME"
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file:///tmp/kaniko-trust-policy.json \
    --query 'Role.Arn' \
    --output text || { echo "❌ Failed to create IAM role!"; exit 1; }
else
  echo "✅ IAM role $ROLE_NAME already exists"
fi

# Step 3: Annotate Kubernetes Service Account
echo "=== Step 3: Annotating Kubernetes Service Account ==="

kubectl delete serviceaccount kaniko-builder --namespace "$NAMESPACE" --ignore-not-found | cat

kubectl create serviceaccount kaniko-builder --namespace "$NAMESPACE" | cat

kubectl annotate serviceaccount kaniko-builder \
  --namespace "$NAMESPACE" \
  eks.amazonaws.com/role-arn="arn:aws:iam::$AWS_ACCOUNT_ID:role/$ROLE_NAME" \
  --overwrite | cat

echo "✅ Service account correctly annotated!"

# Cleanup
rm -f "/tmp/kaniko-trust-policy.json"

echo "✅ Kaniko IRSA environment setup is complete!"


# Cleanup
rm -f "/tmp/kaniko-ecr-policy.json" "/tmp/kaniko-trust-policy.json"

echo ""
echo "====================== INITIALIZATION COMPLETE ======================"
echo "Kaniko environment has been successfully set up."
echo "You can now use the kaniko-builder service account to build images."
echo "===================================================================="

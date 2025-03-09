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
    n)
      NAMESPACE=$OPTARG
      ;;
    r)
      ROLE_NAME=$OPTARG
      ;;
    c)
      CLUSTER_NAME=$OPTARG
      ;;
    i)
      USE_IRSA=true
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

# Check if IRSA flag is set and CLUSTER_NAME is provided
if [ "$USE_IRSA" = true ] && [ -z "$CLUSTER_NAME" ]; then
  echo "Error: When using IRSA, CLUSTER_NAME is required"
  show_usage
fi

# Get AWS account ID and region
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region)

echo "=== Initializing Kaniko Environment ==="
echo "NAMESPACE: $NAMESPACE"
echo "ROLE_NAME: $ROLE_NAME"
if [ "$USE_IRSA" = true ]; then
  echo "CLUSTER_NAME: $CLUSTER_NAME"
  echo "Using IRSA for authentication"
else
  echo "Using AWS credentials secret for authentication"
fi
echo ""

# Create ECR policy document
echo "=== Step 1: Creating IAM policy for ECR access ==="
cat > "/tmp/kaniko-ecr-policy.json" << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion"
      ],
      "Resource": "arn:aws:s3:::*/*"
    }
  ]
}
EOF

# Create IAM policy - using a non-blocking approach
# First check if policy already exists
EXISTING_POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='kaniko-ecr-policy'].Arn" --output text)

if [ -z "$EXISTING_POLICY_ARN" ] || [ "$EXISTING_POLICY_ARN" == "None" ]; then
  echo "Creating IAM policy: kaniko-ecr-policy"
  POLICY_ARN=$(aws iam create-policy \
    --policy-name kaniko-ecr-policy \
    --policy-document file:///tmp/kaniko-ecr-policy.json \
    --query 'Policy.Arn' \
    --output text)
else
  echo "IAM policy kaniko-ecr-policy already exists"
  POLICY_ARN=$EXISTING_POLICY_ARN
fi

echo "Policy ARN: $POLICY_ARN"

if [ "$USE_IRSA" = true ]; then
  # Setup IRSA
  echo "=== Step 2: Setting up IRSA for Kaniko ==="
  
  # Check if eksctl is installed
  if ! command -v eksctl &> /dev/null; then
    echo "Error: eksctl is required for IRSA setup but not found"
    exit 1
  fi
  
  # Create service account with IRSA - use --output json to avoid pager
  eksctl create iamserviceaccount \
    --name kaniko-builder \
    --namespace $NAMESPACE \
    --cluster $CLUSTER_NAME \
    --attach-policy-arn $POLICY_ARN \
    --approve \
    --override-existing-serviceaccounts | cat
else
  # Create IAM role
  echo "=== Step 2: Creating IAM role for Kaniko ==="
  
  # Create trust policy for the EKS cluster
  cat > "/tmp/kaniko-trust-policy.json" << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  # Check if role already exists
  ROLE_EXISTS=$(aws iam get-role --role-name $ROLE_NAME --query "Role.RoleName" --output text 2>/dev/null || echo "false")
  
  if [ "$ROLE_EXISTS" == "false" ] || [ "$ROLE_EXISTS" == "None" ]; then
    echo "Creating IAM role: $ROLE_NAME"
    # Create IAM role - use --output text to avoid pager
    aws iam create-role \
      --role-name $ROLE_NAME \
      --assume-role-policy-document file:///tmp/kaniko-trust-policy.json \
      --output text > /dev/null
  else
    echo "IAM role $ROLE_NAME already exists"
  fi
  
  # Attach policy to role
  echo "Attaching policy to role"
  aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn $POLICY_ARN

  # Create AWS credentials
  echo "=== Step 3: Creating AWS credentials secret ==="
  
  # Create AWS credentials file
  cat > "/tmp/aws-credentials" << EOF
[default]
aws_access_key_id=$(aws configure get aws_access_key_id)
aws_secret_access_key=$(aws configure get aws_secret_access_key)
aws_session_token=$(aws configure get aws_session_token)
EOF

  # Create Kubernetes secret
  kubectl create secret generic aws-credentials \
    --from-file=credentials=/tmp/aws-credentials \
    --namespace $NAMESPACE \
    -o yaml --dry-run=client | kubectl apply -f - | cat
  
  # Clean up temporary file
  rm -f "/tmp/aws-credentials"
fi

# Create service account and RBAC
echo "=== Step 4: Creating Kaniko service account and RBAC ==="

# Create service account manifest
cat > "/tmp/kaniko-service-account.yaml" << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kaniko-builder
  namespace: $NAMESPACE
EOF

if [ "$USE_IRSA" = false ]; then
  # Add role ARN annotation if not using IRSA
  cat >> "/tmp/kaniko-service-account.yaml" << EOF
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::$AWS_ACCOUNT_ID:role/$ROLE_NAME
EOF
fi

# Add RBAC configs
cat >> "/tmp/kaniko-service-account.yaml" << EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kaniko-builder-role
  namespace: $NAMESPACE
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kaniko-builder-binding
  namespace: $NAMESPACE
subjects:
- kind: ServiceAccount
  name: kaniko-builder
  namespace: $NAMESPACE
roleRef:
  kind: Role
  name: kaniko-builder-role
  apiGroup: rbac.authorization.k8s.io
EOF

# Apply service account and RBAC
kubectl apply -f "/tmp/kaniko-service-account.yaml" | cat

# Clean up
rm -f "/tmp/kaniko-ecr-policy.json" "/tmp/kaniko-trust-policy.json" "/tmp/kaniko-service-account.yaml"

echo ""
echo "====================== INITIALIZATION COMPLETE ======================"
echo "Kaniko environment has been successfully set up."
echo "You can now use the kaniko-builder service account to build images."
echo "===================================================================="

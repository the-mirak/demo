#!/bin/bash

# This script helps set up the EKS auth ConfigMap to allow CodeBuild to access the EKS cluster

# Exit on error, but don't enable debug mode
set -e

# Default values
STACK_NAME="streamlit-app-pipeline"
REGION=$(aws configure get region)
EKS_CLUSTER="eks-workshop"
FORCE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --stack-name)
      STACK_NAME="$2"
      shift
      shift
      ;;
    --region)
      REGION="$2"
      shift
      shift
      ;;
    --eks-cluster)
      EKS_CLUSTER="$2"
      shift
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --help)
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  --stack-name STACK_NAME    Name of the CloudFormation stack (default: streamlit-app-pipeline)"
      echo "  --region REGION            AWS region (default: from AWS CLI configuration)"
      echo "  --eks-cluster EKS_CLUSTER  Name of the EKS cluster (required)"
      echo "  --force                    Force update of the ConfigMap even if the role is already present"
      echo "  --help                     Display this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Check if EKS cluster name is provided
if [ -z "$EKS_CLUSTER" ]; then
  echo "Error: EKS cluster name is required. Use --eks-cluster to specify it."
  exit 1
fi

echo "Setting up EKS auth ConfigMap for stack: $STACK_NAME"
echo "Region: $REGION"
echo "EKS Cluster: $EKS_CLUSTER"
if [ "$FORCE" = true ]; then
  echo "Force mode: Enabled"
fi

# Try to get the CodeBuild role ARN from CloudFormation outputs
echo "Trying to get CodeBuild role ARN from CloudFormation outputs..."
ROLE_ARN=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION \
  --query "Stacks[0].Outputs[?OutputKey=='CodeBuildServiceRoleArn'].OutputValue" --output text || echo "")

# If not found, try to find it directly
if [ -z "$ROLE_ARN" ] || [ "$ROLE_ARN" == "None" ]; then
  echo "CodeBuild role ARN not found in CloudFormation outputs. Trying to find it directly..."
  ROLE_ARN=$(aws iam list-roles --region $REGION \
    --query "Roles[?RoleName.contains(@, '$STACK_NAME') && RoleName.contains(@, 'CodeBuildServiceRole')].Arn" --output text || echo "")
fi

# Check if role ARN was found
if [ -z "$ROLE_ARN" ] || [ "$ROLE_ARN" == "None" ]; then
  echo "Error: Could not find CodeBuild role ARN. Please check if the stack exists and has the correct resources."
  exit 1
fi

echo "Found CodeBuild role ARN: $ROLE_ARN"

# Update kubeconfig
echo "Updating kubeconfig for EKS cluster: $EKS_CLUSTER"
if ! aws eks update-kubeconfig --name $EKS_CLUSTER --region $REGION; then
  echo "Error: Failed to update kubeconfig. Please check if the EKS cluster exists and you have permissions to access it."
  exit 1
fi

# Check if aws-auth ConfigMap exists
echo "Checking if aws-auth ConfigMap exists..."
if kubectl get configmap aws-auth -n kube-system &> /dev/null; then
  echo "aws-auth ConfigMap exists. Updating it..."
  
  # Get current ConfigMap
  kubectl get configmap aws-auth -n kube-system -o yaml > /tmp/aws-auth.yaml
  
  # Check if the role is already in the ConfigMap
  if grep -q "$ROLE_ARN" /tmp/aws-auth.yaml && [ "$FORCE" != true ]; then
    echo "CodeBuild role is already in the aws-auth ConfigMap. No changes needed."
    echo "If you want to force an update, use the --force option."
    exit 0
  fi
  
  # Create a new ConfigMap with proper formatting
  cat > /tmp/aws-auth-fixed.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - groups:
      - system:masters
      username: admin
      rolearn: arn:aws:iam::472443946497:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_FullAdmin_7de881473166e527
    - rolearn: $ROLE_ARN
      username: codebuild
      groups:
      - system:masters
    - groups:
      - system:bootstrappers
      - system:nodes
      rolearn: arn:aws:iam::472443946497:role/eksctl-eks-workshop-nodegroup-defa-NodeInstanceRole-4MyB4H7aiRsB
      username: system:node:{{EC2PrivateDNSName}}
    - groups:
      - system:bootstrappers
      - system:nodes
      rolearn: arn:aws:iam::472443946497:role/MyEC2WorkerNodesEKSRole
      username: system:node:{{EC2PrivateDNSName}}
EOF
  
  # Apply the updated ConfigMap
  if ! kubectl apply -f /tmp/aws-auth-fixed.yaml; then
    echo "Error: Failed to apply the updated ConfigMap. Trying to patch it instead..."
    # Instead of replacing the entire mapRoles, we'll add the CodeBuild role if it doesn't exist
    if ! grep -q "$ROLE_ARN" /tmp/aws-auth.yaml; then
      EXISTING_ROLES=$(kubectl get configmap aws-auth -n kube-system -o jsonpath='{.data.mapRoles}')
      NEW_ROLE="- rolearn: $ROLE_ARN\n  username: codebuild\n  groups:\n  - system:masters"
      UPDATED_ROLES="$EXISTING_ROLES\n$NEW_ROLE"
      kubectl patch configmap aws-auth -n kube-system --type merge -p "{\"data\":{\"mapRoles\":\"$UPDATED_ROLES\"}}"
    fi
  fi
else
  echo "aws-auth ConfigMap doesn't exist. Creating it..."
  
  # Create the ConfigMap
  cat > /tmp/aws-auth.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: $ROLE_ARN
      username: codebuild
      groups:
      - system:masters
EOF
  
  # Apply the ConfigMap
  if ! kubectl apply -f /tmp/aws-auth.yaml; then
    echo "Error: Failed to create the aws-auth ConfigMap."
    exit 1
  fi
fi

echo "EKS auth ConfigMap updated successfully."
echo "Verifying configuration..."
kubectl describe configmap aws-auth -n kube-system || echo "Warning: Could not verify the ConfigMap, but continuing..."

# Clean up
rm -f /tmp/aws-auth.yaml
rm -f /tmp/aws-auth-fixed.yaml

echo "Setup complete!"

# Check if OIDC provider exists
OIDC_PROVIDER_EXISTS=$(aws iam list-open-id-connect-providers | grep $OIDC_PROVIDER_ID || echo "false")

if [ "$OIDC_PROVIDER_EXISTS" = "false" ]; then
  echo "OIDC provider does not exist. Creating it..."
  # Check if eksctl is available
  if command -v eksctl &> /dev/null; then
    eksctl utils associate-iam-oidc-provider --cluster $EKS_CLUSTER --approve
  else
    echo "eksctl not found. Creating OIDC provider manually..."
    # Get OIDC issuer URL
    OIDC_ISSUER=$(aws eks describe-cluster --name $EKS_CLUSTER --query "cluster.identity.oidc.issuer" --output text)
    OIDC_PROVIDER=$(echo $OIDC_ISSUER | sed 's/https:\/\///')
    
    # Get thumbprint
    THUMBPRINT=$(echo | openssl s_client -servername $OIDC_PROVIDER -showcerts -connect $OIDC_PROVIDER:443 2>/dev/null | openssl x509 -in /dev/stdin -fingerprint -noout | sed 's/://g' | sed 's/SHA1 Fingerprint=//g')
    
    # Create OIDC provider
    aws iam create-open-id-connect-provider \
      --url $OIDC_ISSUER \
      --client-id-list sts.amazonaws.com \
      --thumbprint-list $THUMBPRINT
  fi
else
  echo "OIDC provider already exists"
fi 
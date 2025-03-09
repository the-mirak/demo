#!/bin/bash

# This script helps set up the EKS auth ConfigMap to allow CodeBuild to access the EKS cluster

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
  --query "Stacks[0].Outputs[?OutputKey=='CodeBuildServiceRoleArn'].OutputValue" --output text)

# If not found, try to find it directly
if [ -z "$ROLE_ARN" ] || [ "$ROLE_ARN" == "None" ]; then
  echo "CodeBuild role ARN not found in CloudFormation outputs. Trying to find it directly..."
  ROLE_ARN=$(aws iam list-roles --region $REGION \
    --query "Roles[?RoleName.contains(@, '$STACK_NAME') && RoleName.contains(@, 'CodeBuildServiceRole')].Arn" --output text)
fi

# Check if role ARN was found
if [ -z "$ROLE_ARN" ] || [ "$ROLE_ARN" == "None" ]; then
  echo "Error: Could not find CodeBuild role ARN. Please check if the stack exists and has the correct resources."
  exit 1
fi

echo "Found CodeBuild role ARN: $ROLE_ARN"

# Update kubeconfig
echo "Updating kubeconfig for EKS cluster: $EKS_CLUSTER"
aws eks update-kubeconfig --name $EKS_CLUSTER --region $REGION

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
  kubectl apply -f /tmp/aws-auth-fixed.yaml
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
  kubectl apply -f /tmp/aws-auth.yaml
fi

echo "EKS auth ConfigMap updated successfully."
echo "Verifying configuration..."
kubectl describe configmap aws-auth -n kube-system

# Clean up
rm -f /tmp/aws-auth.yaml
rm -f /tmp/aws-auth-fixed.yaml

echo "Setup complete!" 
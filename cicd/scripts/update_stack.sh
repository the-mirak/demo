#!/bin/bash

# This script updates an existing CloudFormation stack to handle the ECR repository that already exists

set -e

# Default values
STACK_NAME="streamlit-app-pipeline"
REGION=$(aws configure get region)
CREATE_ECR="false"

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
    --create-ecr)
      CREATE_ECR="$2"
      shift
      shift
      ;;
    --help)
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  --stack-name STACK_NAME    Name of the CloudFormation stack (default: streamlit-app-pipeline)"
      echo "  --region REGION            AWS region (default: from AWS CLI configuration)"
      echo "  --create-ecr true|false    Whether to create the ECR repository (default: false)"
      echo "  --help                     Display this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "Updating CloudFormation stack: $STACK_NAME"
echo "Region: $REGION"
echo "Create ECR Repository: $CREATE_ECR"

# Get current parameter values
echo "Retrieving current parameter values..."
PARAMS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query "Stacks[0].Parameters" --output json)

# Extract parameter values
GITHUB_OWNER=$(echo $PARAMS | jq -r '.[] | select(.ParameterKey=="GitHubOwner") | .ParameterValue')
GITHUB_REPO=$(echo $PARAMS | jq -r '.[] | select(.ParameterKey=="GitHubRepo") | .ParameterValue')
GITHUB_BRANCH=$(echo $PARAMS | jq -r '.[] | select(.ParameterKey=="GitHubBranch") | .ParameterValue')
GITHUB_TOKEN=$(echo $PARAMS | jq -r '.[] | select(.ParameterKey=="GitHubToken") | .ParameterValue')
EKS_CLUSTER_NAME=$(echo $PARAMS | jq -r '.[] | select(.ParameterKey=="EksClusterName") | .ParameterValue')
AWS_REGION=$(echo $PARAMS | jq -r '.[] | select(.ParameterKey=="AWSRegion") | .ParameterValue')

# If any values are null or empty, prompt for them
if [ -z "$GITHUB_OWNER" ]; then
  read -p "GitHub Owner: " GITHUB_OWNER
fi

if [ -z "$GITHUB_REPO" ]; then
  read -p "GitHub Repository: " GITHUB_REPO
fi

if [ -z "$GITHUB_BRANCH" ]; then
  GITHUB_BRANCH="main"
  read -p "GitHub Branch [$GITHUB_BRANCH]: " input
  GITHUB_BRANCH=${input:-$GITHUB_BRANCH}
fi

if [ -z "$GITHUB_TOKEN" ]; then
  read -p "GitHub Token: " GITHUB_TOKEN
fi

if [ -z "$EKS_CLUSTER_NAME" ]; then
  read -p "EKS Cluster Name: " EKS_CLUSTER_NAME
fi

if [ -z "$AWS_REGION" ]; then
  AWS_REGION=$REGION
fi

# Update the stack
echo "Updating CloudFormation stack..."
aws cloudformation update-stack \
  --stack-name $STACK_NAME \
  --template-body file://cicd/cloudformation/pipeline.yml \
  --parameters \
    ParameterKey=GitHubOwner,ParameterValue=$GITHUB_OWNER \
    ParameterKey=GitHubRepo,ParameterValue=$GITHUB_REPO \
    ParameterKey=GitHubBranch,ParameterValue=$GITHUB_BRANCH \
    ParameterKey=GitHubToken,ParameterValue=$GITHUB_TOKEN \
    ParameterKey=EksClusterName,ParameterValue=$EKS_CLUSTER_NAME \
    ParameterKey=AWSRegion,ParameterValue=$AWS_REGION \
    ParameterKey=CreateECRRepository,ParameterValue=$CREATE_ECR \
  --capabilities CAPABILITY_IAM \
  --region $REGION

echo "Stack update initiated. You can monitor the progress in the AWS CloudFormation console."
echo "Once the update is complete, your pipeline will use the existing ECR repository." 
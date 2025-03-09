#!/bin/bash

# Script to deploy the CI/CD pipeline CloudFormation stack

# Default values
STACK_NAME="streamlit-app-pipeline"
REGION=$(aws configure get region)
GITHUB_BRANCH="main"

# Display help
function show_help {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  -o, --github-owner     GitHub repository owner (required)"
  echo "  -r, --github-repo      GitHub repository name (required)"
  echo "  -t, --github-token     GitHub personal access token (required)"
  echo "  -c, --eks-cluster      EKS cluster name (required)"
  echo "  -b, --github-branch    GitHub branch name (default: main)"
  echo "  -n, --stack-name       CloudFormation stack name (default: streamlit-app-pipeline)"
  echo "  -g, --region           AWS region (default: from AWS CLI config)"
  echo "  -h, --help             Display this help message"
  exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -o|--github-owner)
      GITHUB_OWNER="$2"
      shift
      shift
      ;;
    -r|--github-repo)
      GITHUB_REPO="$2"
      shift
      shift
      ;;
    -t|--github-token)
      GITHUB_TOKEN="$2"
      shift
      shift
      ;;
    -c|--eks-cluster)
      EKS_CLUSTER="$2"
      shift
      shift
      ;;
    -b|--github-branch)
      GITHUB_BRANCH="$2"
      shift
      shift
      ;;
    -n|--stack-name)
      STACK_NAME="$2"
      shift
      shift
      ;;
    -g|--region)
      REGION="$2"
      shift
      shift
      ;;
    -h|--help)
      show_help
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      ;;
  esac
done

# Check required parameters
if [ -z "$GITHUB_OWNER" ] || [ -z "$GITHUB_REPO" ] || [ -z "$GITHUB_TOKEN" ] || [ -z "$EKS_CLUSTER" ]; then
  echo "Error: Missing required parameters."
  show_help
fi

# Check if the stack already exists - use --output json to avoid pager
STACK_EXISTS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --output json 2>/dev/null || echo "false")

if [ "$STACK_EXISTS" != "false" ]; then
  echo "Stack $STACK_NAME already exists. Updating..."
  UPDATE_OR_CREATE="update-stack"
else
  echo "Stack $STACK_NAME does not exist. Creating..."
  UPDATE_OR_CREATE="create-stack"
fi

# Deploy the CloudFormation stack - use --output json to avoid pager
echo "Deploying CI/CD pipeline CloudFormation stack..."
aws cloudformation $UPDATE_OR_CREATE \
  --stack-name $STACK_NAME \
  --template-body file://$(pwd)/cicd/cloudformation/pipeline.yml \
  --parameters \
    ParameterKey=GitHubOwner,ParameterValue=$GITHUB_OWNER \
    ParameterKey=GitHubRepo,ParameterValue=$GITHUB_REPO \
    ParameterKey=GitHubBranch,ParameterValue=$GITHUB_BRANCH \
    ParameterKey=GitHubToken,ParameterValue=$GITHUB_TOKEN \
    ParameterKey=EksClusterName,ParameterValue=$EKS_CLUSTER \
    ParameterKey=AWSRegion,ParameterValue=$REGION \
  --capabilities CAPABILITY_IAM \
  --output json

if [ $? -eq 0 ]; then
  echo "Deployment initiated successfully!"
  echo "You can monitor the stack creation in the AWS CloudFormation console."
  echo "Once the stack is created, you need to configure EKS permissions as described in the README."
else
  echo "Deployment failed. Please check the error message above."
fi 
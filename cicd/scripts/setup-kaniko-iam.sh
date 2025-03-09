#!/bin/bash

# This script creates the necessary IAM role and policies for Kaniko to push to ECR
# It should be run once before setting up the CI/CD pipeline

set -e

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "AWS CLI is required but not installed. Please install it first."
    exit 1
fi

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region)

if [ -z "$AWS_ACCOUNT_ID" ] || [ -z "$AWS_REGION" ]; then
    echo "Could not determine AWS account ID or region. Please configure AWS CLI."
    exit 1
fi

echo "Creating IAM role for Kaniko..."

# Create trust policy document
cat > /tmp/kaniko-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/OIDC_PROVIDER_ID"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.${AWS_REGION}.amazonaws.com/id/OIDC_PROVIDER_ID:sub": "system:serviceaccount:default:kaniko-builder"
        }
      }
    }
  ]
}
EOF

# Create ECR policy document
cat > /tmp/kaniko-ecr-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:GetAuthorizationToken",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::kaniko-context-${AWS_ACCOUNT_ID}-${AWS_REGION}",
        "arn:aws:s3:::kaniko-context-${AWS_ACCOUNT_ID}-${AWS_REGION}/*"
      ]
    }
  ]
}
EOF

# Create IAM role
aws iam create-role \
    --role-name kaniko-ecr-push-role \
    --assume-role-policy-document file:///tmp/kaniko-trust-policy.json

# Create IAM policy
aws iam create-policy \
    --policy-name kaniko-ecr-push-policy \
    --policy-document file:///tmp/kaniko-ecr-policy.json

# Attach policy to role
aws iam attach-role-policy \
    --role-name kaniko-ecr-push-role \
    --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/kaniko-ecr-push-policy

echo "IAM role and policy created successfully."
echo "Note: You need to replace OIDC_PROVIDER_ID in the trust policy with your EKS cluster's OIDC provider ID."
echo "You can get it by running: aws eks describe-cluster --name YOUR_CLUSTER_NAME --query \"cluster.identity.oidc.issuer\" --output text"

# Clean up
rm /tmp/kaniko-trust-policy.json /tmp/kaniko-ecr-policy.json

echo "Setup complete!" 
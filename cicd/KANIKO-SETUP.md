# Setting Up Kaniko for Container Image Building

This guide explains how to set up Kaniko for building container images in your CI/CD pipeline without using Docker.

## What is Kaniko?

Kaniko is a tool to build container images from a Dockerfile, inside a container or Kubernetes cluster, without requiring a Docker daemon. This makes it ideal for building container images in environments where Docker is not available or where you want to avoid privileged containers.

## Prerequisites

Before setting up Kaniko, ensure you have:

1. An AWS account with appropriate permissions
2. An Amazon EKS cluster
3. AWS CLI installed and configured
4. kubectl installed and configured to access your EKS cluster

## Setup Steps

### 1. Set Up OIDC Provider for EKS

If you haven't already set up an OIDC provider for your EKS cluster, you'll need to do so:

```bash
# Get your EKS cluster's OIDC provider URL
OIDC_PROVIDER=$(aws eks describe-cluster --name YOUR_CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed 's/https:\/\///')

# Create the OIDC provider in IAM
aws iam create-open-id-connect-provider \
    --url https://$OIDC_PROVIDER \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list $(echo | openssl s_client -servername $OIDC_PROVIDER -showcerts -connect $OIDC_PROVIDER:443 2>/dev/null | openssl x509 -in /dev/stdin -fingerprint -noout | sed 's/://g' | sed 's/SHA1 Fingerprint=//g')
```

### 2. Create IAM Role for Kaniko

Run the provided setup script to create the necessary IAM role and policies:

```bash
# Update the OIDC_PROVIDER_ID in the script first
# You can get it from the OIDC provider URL (the part after /id/)
./cicd/scripts/setup-kaniko-iam.sh
```

### 3. Create ECR Repositories

Create the ECR repositories for your application and the Kaniko cache:

```bash
aws ecr create-repository --repository-name streamlit-app
aws ecr create-repository --repository-name kaniko-cache
```

### 4. Update Service Account Annotation

Make sure the Kaniko service account in `kubernetes/kaniko-service-account.yaml` has the correct IAM role ARN:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kaniko-builder
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::YOUR_AWS_ACCOUNT_ID:role/kaniko-ecr-push-role
```

### 5. Create AWS Credentials Secret (Alternative to IRSA)

If you're not using IAM Roles for Service Accounts (IRSA), you can create a Kubernetes secret with AWS credentials:

```bash
# Create AWS credentials file
cat > /tmp/credentials << EOF
[default]
aws_access_key_id=YOUR_ACCESS_KEY
aws_secret_access_key=YOUR_SECRET_KEY
EOF

# Create Kubernetes secret
kubectl create secret generic aws-credentials \
    --from-file=credentials=/tmp/credentials

# Clean up
rm /tmp/credentials
```

## How It Works

The CI/CD pipeline now uses Kaniko instead of Docker:

1. The application code is compressed and uploaded to an S3 bucket
2. A Kaniko pod is created in the EKS cluster
3. Kaniko builds the container image and pushes it directly to ECR
4. The Kubernetes deployment is updated with the new image

## Troubleshooting

If you encounter issues with Kaniko:

1. Check the Kaniko pod logs:

   ```bash
   kubectl logs -f streamlit-app-kaniko-builder
   ```

2. Verify the IAM role has the correct permissions:

   ```bash
   aws iam get-role --role-name kaniko-ecr-push-role
   aws iam list-attached-role-policies --role-name kaniko-ecr-push-role
   ```

3. Ensure the S3 bucket exists and is accessible:

   ```bash
   aws s3 ls s3://kaniko-context-YOUR_AWS_ACCOUNT_ID-YOUR_AWS_REGION
   ```

4. Check if the ECR repositories exist:

   ```bash
   aws ecr describe-repositories --repository-names streamlit-app kaniko-cache
   ```

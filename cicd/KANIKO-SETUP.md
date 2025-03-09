# Kaniko Setup Guide for AWS EKS

This guide explains how to set up Kaniko for building container images in your EKS cluster using IAM Roles for Service Accounts (IRSA).

## Prerequisites

Before setting up the CI/CD pipeline, you need to set up the Kaniko environment:

1. An AWS account with appropriate permissions
2. An existing Amazon EKS cluster
3. AWS CLI installed and configured locally
4. kubectl installed and configured to access your EKS cluster

## One-Time Setup Steps

Before running the CI/CD pipeline, you need to set up the Kaniko environment once. This includes creating the IAM role and service account.

### Option 1: Using the Setup Script (Recommended)

We've provided a convenient script to set up the Kaniko environment:

```bash
./scripts/init-kaniko-environment.sh -c <your-eks-cluster-name> -i
```

This script will:
1. Set up the OIDC provider for your EKS cluster
2. Create the IAM role with the necessary permissions
3. Create the Kubernetes service account with IRSA

### Option 2: Manual Setup

If you prefer to set up the environment manually, follow these steps:

#### 1. Set Up OIDC Provider for EKS

```bash
# Get your EKS cluster's OIDC provider URL
OIDC_PROVIDER=$(aws eks describe-cluster --name <your-eks-cluster-name> --query "cluster.identity.oidc.issuer" --output text | sed 's/https:\/\///')

# Create the OIDC provider in IAM
aws iam create-open-id-connect-provider \
    --url https://$OIDC_PROVIDER \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list $(echo | openssl s_client -servername $OIDC_PROVIDER -showcerts -connect $OIDC_PROVIDER:443 2>/dev/null | openssl x509 -in /dev/stdin -fingerprint -noout | sed 's/://g' | sed 's/SHA1 Fingerprint=//g')
```

#### 2. Create IAM Role for Kaniko

```bash
# Create a trust policy file
cat > trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<your-account-id>:oidc-provider/oidc.eks.<your-region>.amazonaws.com/id/<oidc-id>"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.<your-region>.amazonaws.com/id/<oidc-id>:sub": "system:serviceaccount:default:kaniko-builder"
        }
      }
    }
  ]
}
EOF

# Create the IAM role
aws iam create-role --role-name kaniko-ecr-push-role --assume-role-policy-document file://trust-policy.json

# Attach policies for ECR and S3 access
aws iam attach-role-policy --role-name kaniko-ecr-push-role --policy-arn arn:aws:iam::aws:policy/AmazonECR-FullAccess
aws iam attach-role-policy --role-name kaniko-ecr-push-role --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
```

#### 3. Create Kubernetes Service Account

```bash
cat > kaniko-service-account.yaml << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kaniko-builder
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<your-account-id>:role/kaniko-ecr-push-role
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kaniko-builder-role
  namespace: default
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kaniko-builder-binding
  namespace: default
subjects:
- kind: ServiceAccount
  name: kaniko-builder
  namespace: default
roleRef:
  kind: Role
  name: kaniko-builder-role
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl apply -f kaniko-service-account.yaml
```

## Testing the Setup

You can test the Kaniko setup using the provided script:

```bash
./scripts/build-with-kaniko.sh -a streamlit-app -s <your-s3-bucket> -p app
```

This script will:
1. Package your application and upload it to S3
2. Create a Kaniko pod to build the container image
3. Push the image to ECR

## Troubleshooting

If you encounter issues with the Kaniko setup:

1. Check the IAM role trust policy:
   ```bash
   aws iam get-role --role-name kaniko-ecr-push-role --query 'Role.AssumeRolePolicyDocument'
   ```

2. Verify the service account annotation:
   ```bash
   kubectl get serviceaccount kaniko-builder -o yaml
   ```

3. Check the pod logs:
   ```bash
   kubectl logs streamlit-app-kaniko-builder
   ```

4. Verify the pod status:
   ```bash
   kubectl describe pod streamlit-app-kaniko-builder
   ```

## CI/CD Pipeline Integration

The CI/CD pipeline is configured to use the pre-existing Kaniko environment. It will:
1. Create the necessary ECR repositories if they don't exist
2. Apply the Kaniko service account configuration
3. Create a Kaniko pod to build the container image
4. Deploy the application to the EKS cluster

No additional setup is required for the CI/CD pipeline once the Kaniko environment is set up.

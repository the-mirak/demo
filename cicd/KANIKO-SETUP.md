# Setting Up Kaniko with IRSA for Container Image Building

This guide explains how to set up Kaniko for building container images in your CI/CD pipeline using IAM Roles for Service Accounts (IRSA) for secure authentication with AWS services.

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
OIDC_PROVIDER=$(aws eks describe-cluster --name eks-workshop --query "cluster.identity.oidc.issuer" --output text | sed 's/https:\/\///')

# Create the OIDC provider in IAM
aws iam create-open-id-connect-provider \
    --url https://$OIDC_PROVIDER \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list $(echo | openssl s_client -servername $OIDC_PROVIDER -showcerts -connect $OIDC_PROVIDER:443 2>/dev/null | openssl x509 -in /dev/stdin -fingerprint -noout | sed 's/://g' | sed 's/SHA1 Fingerprint=//g')
```

### 2. Create IAM Role for Kaniko

Create the IAM role that Kaniko will assume:

```bash
# Create a trust policy file
cat > trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::YOUR_AWS_ACCOUNT_ID:oidc-provider/oidc.eks.YOUR_REGION.amazonaws.com/id/YOUR_OIDC_ID"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.YOUR_REGION.amazonaws.com/id/YOUR_OIDC_ID:sub": "system:serviceaccount:default:kaniko-builder"
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

### 3. Create ECR Repositories

Create the ECR repositories for your application and the Kaniko cache:

```bash
aws ecr create-repository --repository-name streamlit-app
aws ecr create-repository --repository-name kaniko-cache
```

### 4. Create Kubernetes Service Account with IRSA

Create a Kubernetes service account annotated with the IAM role ARN:

```bash
cat > kaniko-service-account.yaml << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kaniko-builder
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::YOUR_AWS_ACCOUNT_ID:role/kaniko-ecr-push-role
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

### 5. Configure Kaniko Pod to Use IRSA

Create a Kaniko pod configuration that uses the service account with IRSA:

```bash
cat > kaniko-pod.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: kaniko-builder
  namespace: default
spec:
  serviceAccountName: kaniko-builder
  restartPolicy: Never
  containers:
  - name: kaniko
    image: gcr.io/kaniko-project/executor:latest
    args:
    - "--dockerfile=Dockerfile"
    - "--context=s3://YOUR_S3_BUCKET/app.tar.gz"
    - "--destination=YOUR_AWS_ACCOUNT_ID.dkr.ecr.YOUR_REGION.amazonaws.com/streamlit-app:latest"
    - "--cache=true"
    - "--cache-repo=YOUR_AWS_ACCOUNT_ID.dkr.ecr.YOUR_REGION.amazonaws.com/kaniko-cache"
    - "--cleanup"
    env:
    - name: AWS_SDK_LOAD_CONFIG
      value: "true"
    - name: AWS_REGION
      value: "YOUR_REGION"
    volumeMounts:
    - name: aws-iam-token
      mountPath: /var/run/secrets/eks.amazonaws.com/serviceaccount
      readOnly: true
  volumes:
  - name: aws-iam-token
    projected:
      sources:
      - serviceAccountToken:
          path: token
          expirationSeconds: 86400
EOF

kubectl apply -f kaniko-pod.yaml
```

When using IRSA, the AWS SDK automatically detects and uses the credentials provided by the service account token. You only need to include the `AWS_SDK_LOAD_CONFIG` and `AWS_REGION` environment variables.

## How It Works

The CI/CD pipeline uses Kaniko with IRSA for secure authentication:

1. The application code is compressed and uploaded to an S3 bucket
2. A Kaniko pod is created in the EKS cluster with the kaniko-builder service account
3. The service account uses IRSA to assume the IAM role
4. Kaniko builds the container image and pushes it directly to ECR
5. The Kubernetes deployment is updated with the new image

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

3. Check the service account annotation:

   ```bash
   kubectl get serviceaccount kaniko-builder -o yaml
   ```

4. Ensure the OIDC provider is correctly set up:

   ```bash
   aws iam list-open-id-connect-providers
   ```

5. Verify the pod is using the correct service account:

   ```bash
   kubectl describe pod streamlit-app-kaniko-builder
   ```

6. Check if the ECR repositories exist:

   ```bash
   aws ecr describe-repositories --repository-names streamlit-app kaniko-cache
   ```

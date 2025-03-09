# Building & Deploying Applications on EKS with Kaniko

This project demonstrates how to containerize applications, build the images using Kaniko inside a Kubernetes pod on Amazon EKS, push the images to Amazon ECR, and deploy the applications to EKS.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Step-by-Step Guide](#step-by-step-guide)
  - [Step 1: Clone the Repository](#step-1-clone-the-repository)
  - [Step 2: Prepare Your EKS Environment](#step-2-prepare-your-eks-environment)
  - [Step 3: Create an S3 Bucket](#step-3-create-an-s3-bucket)
  - [Step 4: Initialize the Kaniko Environment](#step-4-initialize-the-kaniko-environment)
  - [Step 5: Build the Application with Kaniko](#step-5-build-the-application-with-kaniko)
  - [Step 6: Deploy the Application to EKS](#step-6-deploy-the-application-to-eks)
  - [Step 7: Test the Deployment](#step-7-test-the-deployment)
- [Using IRSA (IAM Roles for Service Accounts)](#using-irsa-iam-roles-for-service-accounts)
- [Building & Deploying Custom Applications](#building--deploying-custom-applications)
- [Troubleshooting](#troubleshooting)
- [Cleanup](#cleanup)
- [Security Considerations](#security-considerations)

## Prerequisites

Before you begin, ensure you have the following:

- An Amazon EKS cluster up and running
- `kubectl` installed and configured to communicate with your EKS cluster
- AWS CLI installed and configured with appropriate permissions
- An S3 bucket for storing build contexts
- (For IRSA) EKS OIDC provider configured
- (For IRSA) `eksctl` installed

## Project Structure

```
.
├── app/                              # Sample Streamlit application
│   ├── app.py                        # Main application code
│   ├── requirements.txt              # Python dependencies
│   └── Dockerfile                    # Container definition
├── kubernetes/                       # Kubernetes manifests
│   ├── kaniko-service-account.yaml   # Service account for Kaniko
│   ├── kaniko-pod.yaml               # Pod template for Kaniko builds
│   └── streamlit-deployment.yaml     # Deployment for the application
├── scripts/                          # Utility scripts
│   ├── init-kaniko-environment.sh    # Initialize the Kaniko environment
│   ├── build-with-kaniko.sh          # Build images with Kaniko
│   ├── deploy-app.sh                 # Deploy applications to EKS
│   ├── create-aws-credentials-secret.sh  # Create AWS credentials secret
│   ├── package-app.sh                # Package application for S3
│   └── test-deployment.sh            # Test the deployment
└── README.md                         # This file
```

## Step-by-Step Guide

### Step 1: Clone the Repository

```bash
git clone https://github.com/yourusername/eks-kaniko-builder.git
cd eks-kaniko-builder
chmod +x scripts/*.sh
```

### Step 2: Prepare Your EKS Environment

Ensure your EKS cluster is up and running and that `kubectl` is configured to communicate with it:

```bash
# Verify that kubectl can connect to your cluster
kubectl get nodes

# Verify AWS CLI configuration
aws sts get-caller-identity
```

### Step 3: Create an S3 Bucket

Create an S3 bucket to store your application build contexts:

```bash
#export S3_BUCKET=streamlitappdemo
export S3_BUCKET=your-unique-bucket-name
aws s3 mb s3://$S3_BUCKET
```

### Step 4: Initialize the Kaniko Environment

This step sets up the necessary IAM permissions, service accounts, and secrets for Kaniko:

```bash
# Using AWS credentials (easier for testing)
./scripts/init-kaniko-environment.sh

# OR using IRSA (recommended for production)
./scripts/init-kaniko-environment.sh -i -c your-cluster-name
```

This script will:
1. Create an IAM policy for ECR access
2. Create an IAM role with the necessary permissions
3. Create a Kubernetes service account for Kaniko
4. Set up RBAC rules for the service account
5. (If not using IRSA) Create a Kubernetes secret with AWS credentials

### Step 5: Build the Application with Kaniko

Now, build the Streamlit application using Kaniko:

```bash
# Using AWS credentials
./scripts/build-with-kaniko.sh -a streamlit-app -s $S3_BUCKET -p app/

# OR using IRSA
./scripts/build-with-kaniko.sh -a streamlit-app -s $S3_BUCKET -p app/ -i
```

This script will:
1. Create an ECR repository if it doesn't exist
2. Package the application and upload it to S3
3. Create and run a Kaniko pod to build the image and push it to ECR
4. Monitor the build logs
5. Clean up temporary resources

You can monitor the build process in real-time as the script follows the Kaniko pod logs.

### Step 6: Deploy the Application to EKS

Deploy the built application to your EKS cluster:

```bash
./scripts/deploy-app.sh -a streamlit-app -p 8501
```

This script will:
1. Create a Kubernetes deployment for your application
2. Create a Kubernetes service to expose your application
3. Wait for the deployment to be ready
4. Display the external URL for accessing your application

### Step 7: Test the Deployment

Verify that your application is running correctly:

```bash
./scripts/test-deployment.sh -a streamlit-app
```

This script will:
1. Retrieve the external URL of your application
2. Check the status of your deployment
3. Test if the application is accessible via HTTP
4. Display useful commands for debugging

You can now access your application using the external URL provided.

## Using IRSA (IAM Roles for Service Accounts)

IRSA provides a more secure way for Kaniko to authenticate with AWS services without using AWS credentials stored in Kubernetes secrets.

To use IRSA:

1. Ensure your EKS cluster has an OIDC provider configured:
   ```bash
   eksctl utils associate-iam-oidc-provider --region=us-wests-2 --cluster=eks-workshop --approve
   ```

2. Initialize the Kaniko environment with IRSA:
   ```bash
   ./scripts/init-kaniko-environment.sh -i -c your-cluster-name
   ```

3. Build with IRSA:
   ```bash
   ./scripts/build-with-kaniko.sh -a your-app-name -s your-s3-bucket -i
   ```

For more information on IRSA, see the [AWS documentation](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html).

## Building & Deploying Custom Applications

You can use this framework to build and deploy your own applications:

1. Create your application directory with a Dockerfile
2. Build the application:
   ```bash
   ./scripts/build-with-kaniko.sh -a your-app-name -s your-s3-bucket -p path/to/your/app/
   ```

3. Deploy the application:
   ```bash
   ./scripts/deploy-app.sh -a your-app-name -p your-container-port
   ```

The scripts support various options for customization. Use the `-h` flag to see available options:
```bash
./scripts/build-with-kaniko.sh -h
./scripts/deploy-app.sh -h
```

## Troubleshooting

### Common Issues and Solutions

#### Kaniko fails to push to ECR

- Check that the service account has the necessary permissions to push to ECR
- Verify that the ECR repository exists
- Check network connectivity from your EKS cluster to ECR

```bash
# Check the logs of the Kaniko pod
kubectl logs $(kubectl get pod -l app=kaniko-builder -o jsonpath='{.items[0].metadata.name}')
```

#### S3 Access Issues

- Verify that the service account has permissions to access the S3 bucket
- Check that the S3 bucket exists and is in the correct region

```bash
# Test S3 access
aws s3 ls s3://your-bucket-name/
```

#### Deployment Issues

```bash
# Check the status of the deployment
kubectl describe deployment your-app-name

# Check the logs of the pods
kubectl logs -l app=your-app-name
```

## Cleanup

To clean up all resources:

```bash
# Delete the application deployment
kubectl delete deployment streamlit-app
kubectl delete service streamlit-app

# Delete Kaniko resources
kubectl delete serviceaccount kaniko-builder
kubectl delete role kaniko-builder-role
kubectl delete rolebinding kaniko-builder-binding
kubectl delete secret aws-credentials  # If using AWS credentials

# Delete ECR repositories (optional)
aws ecr delete-repository --repository-name streamlit-app --force
aws ecr delete-repository --repository-name kaniko-cache --force

# Delete S3 bucket (optional)
aws s3 rb s3://your-bucket-name --force
```

## Security Considerations

- Always follow the principle of least privilege when configuring IAM roles
- Use IRSA in production environments instead of AWS credentials secrets
- Regularly rotate credentials if using the AWS credentials secret approach
- Consider implementing network policies to restrict pod-to-pod communication
- Use private ECR repositories when possible
- Implement image scanning in your ECR repositories
- Consider using OPA Gatekeeper or other policy enforcement tools for your EKS cluster

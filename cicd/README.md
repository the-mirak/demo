# Streamlit App CI/CD Pipeline for AWS EKS

This directory contains all the necessary configuration files to set up a complete CI/CD pipeline for deploying the Streamlit application to Amazon EKS using AWS CodeBuild, CodePipeline, and GitHub.

## Architecture Overview

The CI/CD pipeline follows this workflow:

1. Code changes are pushed to the GitHub repository
2. AWS CodePipeline detects the changes and triggers the pipeline
3. CodePipeline pulls the source code from GitHub
4. CodeBuild builds a Docker image from the source code
5. The Docker image is pushed to Amazon ECR
6. The Kubernetes deployment is updated with the new image
7. The application is deployed to the EKS cluster

## Prerequisites

Before setting up the CI/CD pipeline, ensure you have:

1. An AWS account with appropriate permissions
2. A GitHub repository containing your Streamlit application code
3. A GitHub personal access token with `repo` scope
4. An existing Amazon EKS cluster
5. AWS CLI installed and configured locally
6. kubectl installed and configured locally

## Directory Structure

```sh
cicd/
├── buildspec/
│   └── buildspec.yml         # AWS CodeBuild buildspec file
├── cloudformation/
│   └── pipeline.yml          # CloudFormation template for the CI/CD pipeline
├── scripts/
│   ├── pre_deploy.sh         # Pre-deployment script
│   ├── post_deploy.sh        # Post-deployment verification script
│   └── deploy_pipeline.sh    # Script to deploy the CloudFormation stack
└── README.md                 # This file
```

## Step-by-Step Setup Guide

### 1. Prepare Your GitHub Repository

1. Push your Streamlit application code to a GitHub repository
2. Ensure your repository has the following structure:

 ```sh
   repo-root/
   ├── app/
   │   ├── Dockerfile
   │   ├── app.py
   │   └── requirements.txt
   ├── kubernetes/
   │   └── streamlit-deployment.yaml
   ├── cicd/
   │   └── ... (the contents of this directory)
   └── appspec.yml
```

3. Generate a GitHub personal access token:
   - Go to GitHub Settings > Developer settings > Personal access tokens
   - Click "Generate new token"
   - Select the `repo` scope
   - Copy the generated token for later use

### 2. Deploy the CloudFormation Stack

#### Option 1: Using the Deployment Script

We've provided a convenient script to deploy the CloudFormation stack:

```bash
./cicd/scripts/deploy_pipeline.sh \
  --github-owner  the-mirak \
  --github-repo demo \
  --github-token <token> \
  --eks-cluster eks-workshop \
  --region us-west-2
```

Run `./cicd/scripts/deploy_pipeline.sh --help` for more options.

#### Option 2: Using the AWS Console

1. Open the AWS CloudFormation console
2. Click "Create stack" > "With new resources (standard)"
3. Upload the `cicd/cloudformation/pipeline.yml` template
4. Fill in the parameters:
   - Stack name: `streamlit-app-pipeline`
   - GitHubOwner: Your GitHub username
   - GitHubRepo: Your repository name
   - GitHubBranch: The branch to deploy (default: main)
   - GitHubToken: The personal access token you generated
   - EksClusterName: The name of your EKS cluster
   - AWSRegion: The AWS region where your EKS cluster is located
5. Click "Next" through the remaining steps and "Create stack"

### 3. Make the Scripts Executable

If you're deploying from a Unix-like system, make the scripts executable:

```bash
chmod +x cicd/scripts/pre_deploy.sh
chmod +x cicd/scripts/post_deploy.sh
chmod +x cicd/scripts/deploy_pipeline.sh
```

### 4. Configure EKS Permissions

Ensure that CodeBuild has the necessary permissions to deploy to your EKS cluster:

#### Option 1: Using the Setup Script (Recommended)

We've provided a convenient script to set up the EKS auth ConfigMap:

```bash
./cicd/scripts/setup-eks-auth.sh --eks-cluster <your-eks-cluster-name>
```

This script will:
1. Find the CodeBuild role ARN automatically
2. Update the EKS auth ConfigMap to grant the role access
3. Verify the configuration

Run `./cicd/scripts/setup-eks-auth.sh --help` for more options.

If you encounter authentication issues even after running the script, you can use the `--force` option to completely rebuild the aws-auth ConfigMap with proper formatting:

```bash
./cicd/scripts/setup-eks-auth.sh --eks-cluster <your-eks-cluster-name> --force
```

#### Option 2: Manual Setup

1. Get the ARN of the CodeBuild service role using one of these methods:

   **Method A: Using CloudFormation outputs** (if you've deployed with the updated template):
   ```bash
   aws cloudformation describe-stacks --stack-name streamlit-app-pipeline \
     --query "Stacks[0].Outputs[?OutputKey=='CodeBuildServiceRoleArn'].OutputValue" \
     --output text
   ```

   **Method B: Using AWS CLI to find the role directly**:
   ```bash
   aws iam list-roles --query "Roles[?RoleName.contains(@, 'streamlit-app-pipeline') && RoleName.contains(@, 'CodeBuildServiceRole')].Arn" --output text
   ```

   **Method C: Using the AWS Management Console**:
   - Go to the CloudFormation console
   - Select your stack
   - Go to the Resources tab
   - Find the CodeBuildServiceRole resource and click on its Physical ID
   - Copy the Role ARN from the IAM console

2. Add the role to your EKS cluster's auth config:

   ```bash
   kubectl edit configmap aws-auth -n kube-system
   ```

3. Add the following entry to the `mapRoles` section:

   ```yaml
   - rolearn: <CodeBuild-Service-Role-ARN>
     username: codebuild
     groups:
       - system:masters
   ```

   If the `mapRoles` section doesn't exist, create it:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: aws-auth
     namespace: kube-system
   data:
     mapRoles: |
       - rolearn: <CodeBuild-Service-Role-ARN>
         username: codebuild
         groups:
           - system:masters
     # Keep any existing mapUsers or mapAccounts sections
   ```

4. Verify the configuration:
   ```bash
   kubectl describe configmap aws-auth -n kube-system
   ```

### 5. Trigger the Pipeline

1. Make a change to your repository and push it to GitHub
2. The pipeline will automatically trigger
3. Monitor the pipeline progress in the AWS CodePipeline console

## Monitoring and Troubleshooting

### Monitoring the Pipeline

1. Open the AWS CodePipeline console
2. Select the `streamlit-app-pipeline` pipeline
3. View the current status and history of pipeline executions

### Viewing Build Logs

1. Open the AWS CodeBuild console
2. Select the `streamlit-app-pipeline-build` project
3. Click on a build run to view detailed logs

### Checking Deployment Status

1. Use kubectl to check the deployment status:

   ```bash
   kubectl get deployments
   kubectl get pods
   kubectl get services
   ```

2. To view the logs of the running pods:

   ```bash
   kubectl logs -l app=streamlit-app
   ```

## Customization

### Modifying the Build Process

Edit the `cicd/buildspec/buildspec.yml` file to customize the build process.

### Using Kaniko Instead of Docker

This project now supports using Kaniko for building container images without requiring Docker. Kaniko is a tool that builds container images from a Dockerfile inside a container or Kubernetes cluster, without requiring a Docker daemon.

For detailed setup instructions, see the [Kaniko Setup Guide](KANIKO-SETUP.md).

To use Kaniko:
1. Follow the setup instructions in the Kaniko Setup Guide
2. The buildspec.yml file has been updated to use Kaniko instead of Docker

### Changing Deployment Configuration

Edit the `kubernetes/streamlit-deployment.yaml` file to modify the Kubernetes deployment configuration.

### Adding Custom Validation Steps

Edit the `cicd/scripts/post_deploy.sh` file to add custom validation steps after deployment.

## Cleanup

To delete the CI/CD pipeline and associated resources:

1. Open the AWS CloudFormation console
2. Select the `streamlit-app-pipeline` stack
3. Click "Delete" and confirm

Note: This will not delete your EKS cluster or deployed application. To remove those, use kubectl:

```bash
kubectl delete -f kubernetes/streamlit-deployment.yaml
```

## Security Considerations

- The GitHub token is stored securely in AWS Systems Manager Parameter Store
- IAM roles follow the principle of least privilege
- All communication between services is encrypted in transit
- ECR images are scanned for vulnerabilities

## Support

For issues or questions, please open an issue in the GitHub repository.

## Troubleshooting

### ECR Repository Management

The CloudFormation template now uses a custom resource to intelligently handle ECR repositories:

- **Automatic Detection**: The template automatically checks if the ECR repository exists
- **Smart Creation**: If the repository doesn't exist, it creates it; if it exists, it uses the existing one
- **Lifecycle Management**: It applies the lifecycle policy to manage image retention
- **Safe Deletion**: When the stack is deleted, the ECR repository is preserved

This approach eliminates the "Resource already exists" error that previously occurred when the ECR repository was created outside of CloudFormation or by a previous deployment.

### Other Common Issues

If you encounter other issues with the deployment:

1. Check the CloudFormation events for detailed error messages
2. Review the CodeBuild logs for build and deployment errors
3. Verify that the IAM roles have the necessary permissions
4. Ensure your GitHub token has the required scopes and hasn't expired

### IAM Policy Names

If you encounter errors like:
```
Resource handler returned message: "Policy arn:aws:iam::aws:policy/AmazonECR-FullAccess does not exist or is not attachable."
```
or
```
Resource handler returned message: "Policy arn:aws:iam::aws:policy/AmazonECRFullAccess does not exist or is not attachable."
```

This is because AWS occasionally updates, renames, or deprecates their managed policies. The template has been updated to use inline policies instead of managed policies for ECR access, which provides several benefits:

1. **Independence from AWS Policy Changes**: The template is no longer affected by AWS renaming or deprecating managed policies
2. **Precise Permissions**: Only the exact permissions needed are granted
3. **Better Security**: Following the principle of least privilege by specifying exact permissions

If you encounter similar errors with other managed policies:

1. Replace the managed policy reference with an inline policy that includes the necessary permissions
2. Check the [AWS Documentation](https://docs.aws.amazon.com/service-authorization/latest/reference/reference_policies_actions-resources-contextkeys.html) for the specific actions needed
3. Re-deploy the stack

### GitHub Token Length Limitation

If you encounter an error like:
```
Resource handler returned message: "The OAuth token used for the GitHub source action Source exceeds the maximum allowed length of 100 characters."
```

This is because AWS CodePipeline has a 100-character limit for GitHub OAuth tokens. The template has been updated to handle this limitation by:

1. Storing the full token in AWS Secrets Manager
2. Using a Lambda function to retrieve the token and truncate it to 100 characters for CodePipeline
3. Passing the truncated token to the GitHub source action

This approach allows you to use GitHub tokens of any length while still maintaining compatibility with CodePipeline.

### CodeBuild Environment Issues

If you encounter an error like:
```
[Container] Phase context status code: COMMAND_EXECUTION_ERROR Message: Error while executing command: apt-get update && apt-get install -y jq. Reason: exit status 127
```

This is because the CodeBuild environment is using Amazon Linux, which uses `yum` instead of `apt-get` for package management. The template and buildspec have been updated to:

1. Use the latest Amazon Linux 2 image (`aws/codebuild/amazonlinux2-x86_64-standard:4.0`)
2. Use `yum` instead of `apt-get` for package installation
3. Include all necessary packages like `jq` and `gettext` (for `envsubst`)

If you encounter similar errors with other commands, make sure they're compatible with the Amazon Linux environment.

### Shell Script Syntax Issues

If you encounter an error like:
```
/codebuild/output/tmp/script.sh: line 4: unexpected EOF while looking for matching `''
```

This is typically caused by syntax errors in the buildspec.yml file, such as:

1. **Unmatched Quotes**: Missing closing quotes in echo statements or commands
2. **Backtick Issues**: Problems with backtick (`) characters in commands
3. **Special Character Escaping**: Improper escaping of special characters

The buildspec has been updated to:
1. Use double quotes consistently for all echo statements
2. Replace backticks with `$(command)` syntax for command substitution
3. Ensure proper escaping of special characters

If you encounter similar syntax errors, check your buildspec.yml for these common issues.

### EKS Authentication Issues

If you encounter an error like:
```
error: You must be logged in to the server (the server has asked for the client to provide credentials)
```

This indicates that CodeBuild cannot authenticate with your EKS cluster. This can be caused by:

1. **Missing IAM Permissions**: The CodeBuild role doesn't have the necessary permissions to access EKS
2. **Kubeconfig Issues**: The kubeconfig file wasn't properly generated or is missing authentication information
3. **EKS Auth ConfigMap**: The CodeBuild role isn't properly mapped in the EKS auth ConfigMap

The solution includes:

1. **Enhanced IAM Permissions**: Added `eks:AccessKubernetesApi` and other necessary permissions to the CodeBuild role
2. **Improved Kubeconfig Setup**: Updated the kubeconfig generation command and added verification steps
3. **EKS Auth ConfigMap Setup**: Ensured the CodeBuild role is properly mapped in the EKS auth ConfigMap

Make sure you've completed step 4 in the setup guide to add the CodeBuild role to your EKS cluster's auth ConfigMap.

For additional help, please open an issue in the GitHub repository.

### Kaniko Pod Issues

If you encounter an error like:
```
Error from server (BadRequest): container "kaniko" in pod "streamlit-app-kaniko-builder" is waiting to start: ContainerCreating
```

This indicates that the Kaniko pod is having trouble starting. Common causes include:

1. **Missing Secret**: The pod might be trying to mount a Secret that doesn't exist
2. **IAM Role Issues**: The IAM role for the service account might not exist or have incorrect permissions
3. **OIDC Provider Issues**: The OIDC provider for your EKS cluster might not be set up correctly

The solution includes:

1. **Using IRSA Properly**: Ensure the Kaniko pod is configured to use IAM Roles for Service Accounts (IRSA) correctly
2. **Automatic Role Creation**: The pipeline now automatically creates the necessary IAM role if it doesn't exist
3. **Proper Volume Mounts**: The pod should have the correct volume mounts for the service account token

To fix issues with Kaniko and IRSA:

1. **Check the service account annotation**:
   ```bash
   kubectl get serviceaccount kaniko-builder -o yaml
   ```
   Ensure it has the annotation `eks.amazonaws.com/role-arn` with the correct IAM role ARN.

2. **Verify the OIDC provider**:
   ```bash
   aws iam list-open-id-connect-providers
   ```
   Make sure an OIDC provider exists for your EKS cluster.

3. **Check the IAM role trust relationship**:
   ```bash
   aws iam get-role --role-name kaniko-ecr-push-role --query "Role.AssumeRolePolicyDocument" --output text
   ```
   Ensure it allows the service account to assume the role.

4. **Verify the pod configuration**:
   ```bash
   kubectl get pod streamlit-app-kaniko-builder -o yaml
   ```
   Check that it's using the correct service account and has the necessary environment variables and volume mounts for IRSA.

If you're still having issues, you can check the pod events for more details:
```bash
kubectl describe pod streamlit-app-kaniko-builder
```

For additional help, please open an issue in the GitHub repository. 
# Streamlit on AWS EKS Demo

This repository contains a Streamlit application deployed on Amazon EKS (Elastic Kubernetes Service) with a complete CI/CD pipeline using AWS CodeBuild and CodePipeline.

## Project Structure

```
.
├── app/                      # Streamlit application code
│   ├── Dockerfile            # Docker image definition
│   ├── app.py                # Main Streamlit application
│   ├── requirements.txt      # Python dependencies
│   └── run.py                # Application entry point
├── kubernetes/               # Kubernetes deployment files
│   └── streamlit-deployment.yaml  # Deployment and service definition
├── cicd/                     # CI/CD pipeline configuration
│   ├── buildspec/            # AWS CodeBuild configuration
│   ├── cloudformation/       # AWS CloudFormation templates
│   ├── scripts/              # Deployment scripts
│   └── README.md             # CI/CD setup instructions
└── README.md                 # This file
```

## Application Overview

This is a demo Streamlit application that showcases:

- Deployment on Amazon EKS
- CI/CD pipeline with AWS CodeBuild and CodePipeline
- Integration with Amazon ECR for container image storage
- Automatic deployment to Kubernetes

The application itself is a simple data visualization dashboard that generates and displays random data.

## Quick Start

### Local Development

To run the application locally:

1. Install dependencies:
   ```bash
   cd app
   pip install -r requirements.txt
   ```

2. Run the application:
   ```bash
   streamlit run app.py
   ```

### Docker Deployment

To build and run the Docker container:

1. Build the image:
   ```bash
   cd app
   docker build -t streamlit-app .
   ```

2. Run the container:
   ```bash
   docker run -p 8501:8501 streamlit-app
   ```

3. Access the application at http://localhost:8501

### Kubernetes Deployment

To deploy to Kubernetes:

1. Apply the Kubernetes configuration:
   ```bash
   kubectl apply -f kubernetes/streamlit-deployment.yaml
   ```

2. Get the service URL:
   ```bash
   kubectl get svc streamlit-app
   ```

## CI/CD Pipeline

This project includes a complete CI/CD pipeline for automated deployment to AWS EKS. The pipeline:

1. Detects changes in the GitHub repository
2. Builds a Docker image
3. Pushes the image to Amazon ECR
4. Deploys the application to Amazon EKS

For detailed setup instructions, see the [CI/CD README](cicd/README.md).

## AWS Infrastructure

The application is designed to run on:

- Amazon EKS for Kubernetes orchestration
- Amazon ECR for container image storage
- AWS Network Load Balancer for traffic routing

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details. 
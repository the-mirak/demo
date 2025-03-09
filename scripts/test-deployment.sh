#!/bin/bash

# Display usage information
function show_usage {
  echo "Usage: $0 -a APP_NAME"
  echo ""
  echo "Required arguments:"
  echo "  -a APP_NAME    Name of the application"
  echo ""
  echo "Optional arguments:"
  echo "  -h             Show this help message"
  exit 1
}

# Parse command line arguments
while getopts ":a:h" opt; do
  case ${opt} in
    a)
      APP_NAME=$OPTARG
      ;;
    h)
      show_usage
      ;;
    \?)
      echo "Invalid option: -$OPTARG" 1>&2
      show_usage
      ;;
    :)
      echo "Option -$OPTARG requires an argument." 1>&2
      show_usage
      ;;
  esac
done

# Check required arguments
if [ -z "$APP_NAME" ]; then
  echo "Error: APP_NAME is a required argument"
  show_usage
fi

# Get service URL - pipe to cat to avoid pager
EXTERNAL_IP=$(kubectl get service "${APP_NAME}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' | cat)

if [ -z "$EXTERNAL_IP" ]; then
  echo "Error: Could not get external IP for service ${APP_NAME}"
  echo "Checking if service exists..."
  kubectl get service "${APP_NAME}" | cat || exit 1
  
  echo "Service exists but may not be a LoadBalancer type or not ready."
  echo "Service details:"
  kubectl get service "${APP_NAME}" -o yaml | cat
  exit 1
fi

# Display deployment info
echo "=== ${APP_NAME} Deployment Info ==="
echo "External URL: http://${EXTERNAL_IP}"
echo ""

echo "=== Pod Status ==="
kubectl get pods -l app="${APP_NAME}" -o wide | cat
echo ""

echo "=== Service Status ==="
kubectl get service "${APP_NAME}" | cat
echo ""

echo "=== Testing application health ==="
if command -v curl &> /dev/null; then
  echo "Checking if application is responding..."
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "http://${EXTERNAL_IP}")
  
  if [ "$HTTP_STATUS" -eq 200 ]; then
    echo "✅ Application is running correctly (HTTP 200 OK)"
  else
    echo "❌ Application returned HTTP status $HTTP_STATUS"
  fi
else
  echo "curl command not found. Please manually verify the application at:"
  echo "http://${EXTERNAL_IP}"
fi

echo ""
echo "To view application logs, run:"
echo "kubectl logs -l app=${APP_NAME} --tail=100"
echo ""
echo "To port-forward to the application, run:"
echo "kubectl port-forward service/${APP_NAME} 8080:80"

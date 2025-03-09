#!/bin/bash

# Post-deployment verification script
echo "Starting post-deployment verification..."

# Wait for the deployment to stabilize - use --timeout to avoid hanging indefinitely
kubectl rollout status deployment/streamlit-app -n default --timeout=300s

# Check if the service is available - pipe to cat to avoid pager
SERVICE_URL=$(kubectl get svc streamlit-app -n default -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' | cat)

if [ -z "$SERVICE_URL" ]; then
  echo "Error: LoadBalancer URL not found. Deployment may have failed."
  exit 1
fi

echo "Service is available at: http://$SERVICE_URL"

# Wait for the load balancer to be fully provisioned
echo "Waiting for load balancer to be fully provisioned..."
sleep 60

# Check if the service is responding
echo "Checking if the service is responding..."
ATTEMPTS=0
MAX_ATTEMPTS=10

while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
  # Use --max-time to avoid hanging on connection issues
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 http://$SERVICE_URL || echo "000")
  
  if [ "$HTTP_STATUS" == "200" ]; then
    echo "Service is responding with HTTP 200 OK"
    echo "Deployment verification completed successfully!"
    exit 0
  else
    echo "Attempt $((ATTEMPTS+1))/$MAX_ATTEMPTS: Service returned HTTP $HTTP_STATUS, waiting 30 seconds..."
    ATTEMPTS=$((ATTEMPTS+1))
    sleep 30
  fi
done

echo "Error: Service is not responding properly after $MAX_ATTEMPTS attempts."
exit 1 
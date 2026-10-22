#!/bin/bash

# ECR Push Script for Web App
# Builds and pushes your web app Docker image to AWS ECR

set -e  # Exit on any error

# Configuration
REPOSITORY_NAME="spbc-web-app"
# An immutable tag per build, so a previous image stays addressable for rollback.
# Override with IMAGE_TAG=... ; "latest" would overwrite the only copy of the old image.
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || date -u +%Y%m%d%H%M%S)}"
AWS_REGION="${AWS_REGION:-eu-central-1}"

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
FULL_IMAGE_NAME="${ECR_URI}/${REPOSITORY_NAME}:${IMAGE_TAG}"

echo "Starting deployment process..."
echo "Repository: ${REPOSITORY_NAME}"
echo "Region: ${AWS_REGION}"
echo "Account ID: ${AWS_ACCOUNT_ID}"
echo "Full image name: ${FULL_IMAGE_NAME}"

# Ensure ECR repository exists
echo ""
echo "Ensuring ECR repository exists..."
aws ecr describe-repositories --repository-names ${REPOSITORY_NAME} --region ${AWS_REGION} >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name ${REPOSITORY_NAME} --region ${AWS_REGION}

# Build the Docker image
echo ""
echo "Building Docker image..."
docker build -t ${REPOSITORY_NAME}:${IMAGE_TAG} .
echo "Docker image built successfully."

# Authenticate Docker to ECR
echo ""
echo "Authenticating Docker to ECR..."
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_URI}
echo "ECR authentication successful."

# Tag the image for ECR
echo ""
echo "Tagging image for ECR..."
docker tag ${REPOSITORY_NAME}:${IMAGE_TAG} ${FULL_IMAGE_NAME}

# Push the image to ECR
echo ""
echo "Pushing image to ECR..."
docker push ${FULL_IMAGE_NAME}

echo ""
echo "✅ Image successfully pushed to ECR!"
echo "Image URI: ${FULL_IMAGE_NAME}"
echo ""
echo "You can now use this image in your EKS deployment with:"
echo "  image: ${FULL_IMAGE_NAME}"

echo ""
echo "Deployment complete! 🚀"

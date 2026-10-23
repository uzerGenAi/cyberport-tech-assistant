# Static web app for the EKS hosting path (the Amplify path serves the same files directly).
# The k8s manifests and their probes expect port 80, so this uses the standard nginx image:
# its master process starts as root and drops the workers to the unprivileged nginx user.
FROM public.ecr.aws/nginx/nginx:1.27-alpine

# ECR Public rather than Docker Hub, to avoid anonymous pull rate limits in CI.

COPY index.html login.html observability.html /usr/share/nginx/html/
COPY style.css enhanced-styles.css /usr/share/nginx/html/
COPY script-enhanced.js cognito-enhanced.js agentcore-client-fixed.js /usr/share/nginx/html/
COPY image.jpg /usr/share/nginx/html/

# Written by post_deploy.sh (setup_cognito_auth.sh and configure_runtime.py) before the build.
# The browser fetches them at runtime, so they have to be in the image; they hold IDs and ARNs,
# not secrets. Both are gitignored, so a build from a clean checkout needs post-deploy to run first.
COPY cognito-config.json agentcore-config.json observability-config.json /usr/share/nginx/html/

# Readiness and liveness probes hit / on 80
EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
    CMD wget -q -O /dev/null http://127.0.0.1/ || exit 1

SHELL := /bin/bash

.PHONY: ci backend-setup provision deploy post-deploy post-deploy-force amplify smoke rollback help \
        backends-plan backends seed-stores backends-check backends-env knowledge-bases

help:
	@echo "Specialty Bakeries & Pastry Cafés — deployment targets:"
	@echo ""
	@echo "  make backend-setup   Create S3 state bucket, DynamoDB lock, and write terraform.tfvars"
	@echo "                       with your current IP as eks_public_access_cidrs  (run FIRST)"
	@echo "                       Unattended: EKS_PUBLIC_ACCESS_CIDRS=1.2.3.4/32 make backend-setup"
	@echo "  make knowledge-bases Bootstrap the vector store, then create/sync all five KBs"
	@echo "  make post-deploy-force  post-deploy that always redeploys the agent code"
	@echo "  make ci              Run local validation checks (Python compile + Terraform validate/test)"
	@echo "  make provision       Provision AWS infrastructure with Terraform (eu-central-1)"
	@echo "  make deploy          Build, push, and deploy the agent backend to EKS (blue/green)"
	@echo "  make post-deploy     Configure Cognito + AgentCore, then re-deploy Amplify frontend"
	@echo "  make amplify         Deploy (or re-deploy) the web frontend to AWS Amplify only"
	@echo "  make smoke           Run the smoke test against SMOKE_TEST_URL"
	@echo "  make rollback        Roll back the current production deployment"
	@echo ""
	@echo "  AgentCore backends (stores database + promotions API, 6_deploy/infra/agentcore-backends):"
	@echo "  make backends-plan   Show what Terraform would change"
	@echo "  make backends        Plan, confirm, and apply exactly that plan"
	@echo "  make seed-stores     Create the stores table, load the data, create the read-only user"
	@echo "  make backends-check  Live smoke test: reader query, unsigned 403, signed GET /promotions"
	@echo "  make backends-env    Print export lines for the runtime env vars"
	@echo ""
	@echo "  Typical first-time flow:"
	@echo "    make backend-setup  →  make ci  →  make provision  →  make deploy  →  make post-deploy"
	@echo "  AgentCore runtime flow:"
	@echo "    make backend-setup  →  make backends  →  make seed-stores  →  make backends-check"
	@echo "    →  ./deploy_agentcore.sh deploy-all"

backend-setup:
	bash 6_deploy/scripts/terraform_backend_setup.sh

ci:
	bash 6_deploy/scripts/ci_checks.sh

provision:
	bash 6_deploy/scripts/end_to_end.sh --infra-only

deploy:
	bash 6_deploy/scripts/end_to_end.sh --deploy-only

post-deploy:
	bash 6_deploy/scripts/post_deploy.sh

# Always ships the current agent code; the plain target skips the launch when a runtime exists
post-deploy-force:
	bash 6_deploy/scripts/post_deploy.sh --force

knowledge-bases:
	bash 3_proof_of_concept/knowledge_bases/bootstrap_vector_store.sh
	bash 3_proof_of_concept/knowledge_bases/setup_knowledge_bases.sh

amplify:
	bash 6_deploy/scripts/amplify-deploy.sh

smoke:
	bash 6_deploy/scripts/smoke_test.sh

rollback:
	bash 6_deploy/scripts/rollback.sh

backends-plan:
	bash 6_deploy/scripts/agentcore_backends.sh plan

backends:
	bash 6_deploy/scripts/agentcore_backends.sh apply

seed-stores:
	bash 6_deploy/scripts/agentcore_backends.sh seed

backends-check:
	bash 6_deploy/scripts/agentcore_backends.sh check

backends-env:
	@bash 6_deploy/scripts/agentcore_backends.sh env

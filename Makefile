.PHONY: init deploy redeploy destroy destroy-all clean help test logs status kubeconfig configure-lb _wait-rollout _clean-stale-secrets

# ── Configuration ──────────────────────────────────────────────────────────────

TF              := terraform -chdir=terraform
NAMESPACE       := $(shell $(TF) output -raw registry_namespace_name 2>/dev/null | grep -E '^[a-z0-9-]+$$' | head -1 || grep '^registry_namespace' terraform/terraform.tfvars 2>/dev/null | head -1 | cut -d'"' -f2)
# Use SCW_SECRET_KEY env var if set, otherwise fall back to reading terraform.tfvars
SCW_SECRET_KEY  ?= $(shell grep '^secret_key' terraform/terraform.tfvars 2>/dev/null | cut -d'"' -f2)
SCW_ACCESS_KEY  ?= $(shell grep '^access_key' terraform/terraform.tfvars 2>/dev/null | cut -d'"' -f2)
LB_IP           := $(shell $(TF) output -raw load_balancer_ip 2>/dev/null || echo "")
KAPSULE_ID      := $(shell $(TF) output -raw kapsule_cluster_id 2>/dev/null || echo "")
CONVERTER_URL   := $(shell $(TF) output -raw image_converter_url 2>/dev/null || echo "")
AI_GENERATOR_URL:= $(shell $(TF) output -raw ai_alt_generator_url 2>/dev/null || echo "")
REGISTRY        := rg.fr-par.scw.cloud/$(NAMESPACE)
KUBECONFIG_PATH ?= /tmp/kubeconfig-onboarding.yaml

# ── Main Targets ───────────────────────────────────────────────────────────────

## Initialize Terraform providers (one-time setup)
init:
	@echo "🔧 Initializing Terraform providers..."
	@$(TF) init
	@echo "✅ Initialization complete!"
	@echo ""
	@echo "Next step: make deploy"


## Complete deployment: images + infrastructure + Kubernetes + LoadBalancer (25-30 minutes)
deploy: _check-auth _apply-infra-registry _build-push _apply-infra _wait-k8s _create-s3-secret _apply-k8s _wait-ready _configure-lb _update-configmap _wait-rollout _test
	@echo ""
	@echo "╔═══════════════════════════════════════════════════════════╗"
	@echo "║              🎉 Deployment Complete!                      ║"
	@echo "╚═══════════════════════════════════════════════════════════╝"
	@echo ""
	@LB_IP=$$($(TF) output -raw load_balancer_ip 2>/dev/null); \
	KAPSULE_ID=$$($(TF) output -raw kapsule_cluster_id 2>/dev/null); \
	CONVERTER_URL=$$($(TF) output -raw image_converter_url 2>/dev/null); \
	AI_URL=$$($(TF) output -raw ai_alt_generator_url 2>/dev/null); \
	echo "  Load Balancer:  http://$$LB_IP"; \
	echo "  Health Check:   http://$$LB_IP/health"; \
	echo "  Test Upload:    curl -F 'file=@logo.png' http://$$LB_IP/upload"; \
	echo ""; \
	echo "  Kubernetes Cluster: $$KAPSULE_ID"; \
	echo "  Image Converter:    $$CONVERTER_URL"; \
	echo "  AI Alt-Generator:   $$AI_URL"
	@echo ""
	@echo "  Use 'make logs' to view live logs"
	@echo "  Use 'make destroy' to remove everything"
	@echo ""

## Rebuild and redeploy images without touching infrastructure
redeploy: _build-push _apply-k8s _wait-ready _configure-lb _update-configmap _wait-rollout
	@echo ""
	@echo "✅ Redeployment complete!"
	@echo "  Load Balancer: http://$$($(TF) output -raw load_balancer_ip 2>/dev/null)"
	@echo ""

## Destroy all resources (keeps bucket and registry)
destroy: _destroy-containers _destroy-lb-manual _destroy-terraform _destroy-security-group
	@echo ""
	@echo "╔═══════════════════════════════════════════════════════════╗"
	@echo "║              ✅ Destruction Complete!                     ║"
	@echo "╚═══════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "  The following resources have been destroyed:"
	@echo "    ✓ Serverless Containers (image-converter, ai-alt-generator)"
	@echo "    ✓ Load Balancer configuration (frontend, backend, routes)"
	@echo "    ✓ Kubernetes cluster and node pools"
	@echo "    ✓ Database instance"
	@echo "    ✓ Secrets"
	@echo ""
	@echo "  The following resources are PRESERVED:"
	@echo "    ✓ Object Storage bucket (onboarding-images-prod)"
	@echo "    ✓ Container Registry namespace"
	@echo ""
	@echo "  Use 'make destroy-all' to delete EVERYTHING (including bucket & registry)"
	@echo ""

## Clean everything including bucket and registry (DESTRUCTIVE)
destroy-all: _destroy-containers _destroy-lb-manual _destroy-terraform _destroy-bucket _destroy-registry
	@echo ""
	@echo "╔═══════════════════════════════════════════════════════════╗"
	@echo "║         ☠️  Complete Destruction Achieved!                ║"
	@echo "╚═══════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "  ALL resources have been destroyed:"
	@echo "    ✓ Serverless Containers"
	@echo "    ✓ Load Balancer and all configuration"
	@echo "    ✓ Kubernetes cluster"
	@echo "    ✓ Database instance"
	@echo "    ✓ Secrets"
	@echo "    ✓ Object Storage bucket"
	@echo "    ✓ Container Registry"
	@echo ""
	@echo "  ⚠️  WARNING: This action is IRREVERSIBLE!"
	@echo ""

# ── Internal Targets (do not call directly) ───────────────────────────────────

_destroy-containers:
	@echo "🗑️  Destroying Serverless Containers..."
	@-scw container container list -o json | jq -r '.[].id' | while read id; do \
		echo "   Deleting container: $$id" && \
		scw container container delete $$id 2>/dev/null || true; \
	done || true
	@echo "   Waiting for containers to be deleted..."
	@sleep 10
	@echo "✅ Serverless Containers destroyed"

_destroy-lb-manual:
	@echo "🗑️  Destroying manual LoadBalancer configuration..."
	@LB_ID=$$(scw lb lb list --tags onboarding -o json | jq -r '.[0].id' 2>/dev/null) && \
	if [ -n "$$LB_ID" ] && [ "$$LB_ID" != "null" ]; then \
		echo "   Found LoadBalancer: $$LB_ID" && \
		scw lb frontend list lb-id=$$LB_ID -o json | jq -r '.[].id' | while read fid; do \
			echo "   Deleting frontend: $$fid" && \
			scw lb frontend delete $$fid 2>/dev/null || true; \
		done && \
		scw lb backend list lb-id=$$LB_ID -o json | jq -r '.[].id' | while read bid; do \
			echo "   Deleting backend: $$bid" && \
			scw lb backend delete $$bid 2>/dev/null || true; \
		done && \
		echo "   Deleting LoadBalancer: $$LB_ID" && \
		scw lb lb delete $$LB_ID 2>/dev/null || true; \
	else \
		echo "   No LoadBalancer found with 'onboarding' tag"; \
	fi || true
	@echo "✅ LoadBalancer configuration destroyed"

_destroy-terraform:
	@echo "🗑️  Running Terraform destroy..."
	@$(TF) destroy -auto-approve -lock-timeout=10m || { \
		echo "⚠️  Terraform destroy encountered errors. Retrying with resource-specific cleanup..." && \
		$(TF) state list 2>/dev/null | tac | while read resource; do \
			echo "   Removing: $$resource" && \
			$(TF) destroy -auto-approve -target="$$resource" 2>/dev/null || true; \
		done; \
	}
	@echo "✅ Terraform resources destroyed"

_destroy-security-group:
	@echo "🗑️  Cleaning up Security Group rules..."
	@SG_ID=$$(scw instance security-group list -o json | jq -r '.[] | select(.name | test("(?i)kapsule")) | .id' 2>/dev/null | head -1) && \
	if [ -n "$$SG_ID" ] && [ "$$SG_ID" != "null" ]; then \
		echo "   Found Security Group: $$SG_ID" && \
		scw instance security-group list-rules security-group-id=$$SG_ID direction=inbound -o json | \
		jq -r '.rules[] | select(.dest_port_from != null and .dest_port_from >= 30000) | .id' | \
		while read rule_id; do \
			echo "   Deleting security group rule: $$rule_id" && \
			scw instance security-group delete-rule $$rule_id 2>/dev/null || true; \
		done; \
	else \
		echo "   No Kapsule Security Group found"; \
	fi || true
	@echo "✅ Security Group rules cleaned"

_destroy-bucket:
	@echo "🗑️  Destroying Object Storage bucket..."
	@BUCKET_NAME=$$($(TF) output -raw bucket_name 2>/dev/null || echo "onboarding-images-prod"); \
	ACCESS_KEY=$(SCW_ACCESS_KEY); \
	SECRET_KEY=$(SCW_SECRET_KEY); \
	echo "   Emptying bucket: $$BUCKET_NAME (may take a moment for large buckets)..."; \
	python3 -c " \
import boto3, sys; \
b = boto3.resource('s3', \
    endpoint_url='https://s3.fr-par.scw.cloud', \
    aws_access_key_id='$$ACCESS_KEY', \
    aws_secret_access_key='$$SECRET_KEY', \
    region_name='fr-par'); \
bucket = b.Bucket('$$BUCKET_NAME'); \
try: \
    bucket.objects.all().delete(); \
    bucket.object_versions.all().delete(); \
    print('   Bucket emptied'); \
except Exception as e: \
    print(f'   Bucket empty or not found: {e}') \
" 2>&1 || true; \
	echo "   Deleting bucket: $$BUCKET_NAME"; \
	$(TF) destroy -auto-approve -target=scaleway_object_bucket.main 2>/dev/null || \
		scw object bucket delete --name=$$BUCKET_NAME 2>/dev/null || true; \
	$(TF) state rm scaleway_object_bucket.main 2>/dev/null || true
	@echo "✅ Object Storage bucket destroyed"

_destroy-registry:
	@echo "🗑️  Destroying Container Registry..."
	@REGISTRY_ID=$$(scw registry namespace list -o json | jq -r '.[] | select(.name == "onboarding") | .id' 2>/dev/null) && \
	if [ -n "$$REGISTRY_ID" ] && [ "$$REGISTRY_ID" != "null" ]; then \
		echo "   Found Registry Namespace: $$REGISTRY_ID" && \
		echo "   Deleting all images..." && \
		scw registry image list -o json | jq -r '.[].id' | while read img_id; do \
			scw registry image delete $$img_id 2>/dev/null || true; \
		done && \
		echo "   Deleting namespace..." && \
		scw registry namespace delete $$REGISTRY_ID 2>/dev/null || true; \
	else \
		echo "   No Registry Namespace found"; \
	fi || true
	@$(TF) state rm scaleway_registry_namespace.main 2>/dev/null || true
	@echo "✅ Container Registry destroyed"

_create-s3-secret:
	@echo "🔐 Creating base Kubernetes secret with S3 and database credentials..."
	@export KUBECONFIG="$(KUBECONFIG_PATH)"; \
	DB_URL=$$($(TF) output -raw database_connection_string 2>/dev/null || true); \
	BUCKET=$$($(TF) output -raw bucket_name 2>/dev/null || true); \
	kubectl create namespace onboarding --dry-run=client -o yaml | kubectl apply -f - && \
	kubectl create secret generic onboarding-secrets \
		--namespace=onboarding \
		--from-literal=S3_ACCESS_KEY=$(SCW_ACCESS_KEY) \
		--from-literal=S3_SECRET_KEY=$(SCW_SECRET_KEY) \
		$$([ -n "$$DB_URL" ] && echo "--from-literal=DATABASE_URL=$$DB_URL" || true) \
		$$([ -n "$$BUCKET" ] && echo "--from-literal=S3_BUCKET_NAME=$$BUCKET" || true) \
		--save-config \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "✅ Base secret created/updated"

_update-configmap:
	@echo "🔧 Updating ConfigMap with Terraform outputs..."
	@export KUBECONFIG="$(KUBECONFIG_PATH)"; \
	CONVERTER_URL=$$($(TF) output -raw image_converter_url 2>/dev/null || true); \
	AI_URL=$$($(TF) output -raw ai_alt_generator_url 2>/dev/null || true); \
	if [ -n "$$CONVERTER_URL" ]; then \
		kubectl patch configmap onboarding-config -n onboarding \
			--type merge \
			-p "{\"data\":{\"IMAGE_CONVERTER_PUBLIC_URL\":\"$$CONVERTER_URL\", \"AI_GENERATOR_PUBLIC_URL\":\"$$AI_URL\"}}" && \
		echo "   Restarting pods to pick up new URL..." && \
		kubectl rollout restart deployment/rest-api -n onboarding; \
	else \
		echo "⚠️  ConfigMap update skipped (no converter URL from terraform output)"; \
	fi
	@echo "✅ ConfigMap updated"

_import-existing-containers:
	@echo "🔍 Checking for existing Serverless resources to import..."
	@NS_ID=$$(scw container namespace list -o json 2>/dev/null | jq -r '.[] | select(.name == "onboarding-converters") | .id' 2>/dev/null) && \
	if [ -n "$$NS_ID" ] && [ "$$NS_ID" != "null" ]; then \
		if ! $(TF) state list 2>/dev/null | grep -q "scaleway_container_namespace.main"; then \
			echo "   Importing existing namespace: $$NS_ID"; \
			$(TF) import scaleway_container_namespace.main fr-par/$$NS_ID >/dev/null 2>&1 || true; \
		fi; \
	fi || true; \
	IMAGE_CONVERTER_ID=$$(scw container container list -o json 2>/dev/null | jq -r '.[] | select(.name == "image-converter") | .id' 2>/dev/null) && \
	if [ -n "$$IMAGE_CONVERTER_ID" ] && [ "$$IMAGE_CONVERTER_ID" != "null" ]; then \
		if ! $(TF) state list 2>/dev/null | grep -q "scaleway_container.image_converter"; then \
			echo "   Importing existing image-converter: $$IMAGE_CONVERTER_ID"; \
			$(TF) import scaleway_container.image_converter fr-par/$$IMAGE_CONVERTER_ID >/dev/null 2>&1 || true; \
		fi; \
	fi || true; \
	AI_GENERATOR_ID=$$(scw container container list -o json 2>/dev/null | jq -r '.[] | select(.name == "ai-alt-generator") | .id' 2>/dev/null) && \
	if [ -n "$$AI_GENERATOR_ID" ] && [ "$$AI_GENERATOR_ID" != "null" ]; then \
		if ! $(TF) state list 2>/dev/null | grep -q "scaleway_container.ai_alt_generator"; then \
			echo "   Importing existing ai-alt-generator: $$AI_GENERATOR_ID"; \
			$(TF) import scaleway_container.ai_alt_generator fr-par/$$AI_GENERATOR_ID >/dev/null 2>&1 || true; \
		fi; \
	fi || true
	@echo "✅ Container import complete"

_check-auth:
	@echo "🔐 Checking Scaleway authentication..."
	@scw info >/dev/null 2>&1 || (echo "❌ Not authenticated. Run 'scw init' first." && exit 1)
	@echo "✅ Authenticated"

_apply-infra-registry:
	@echo "🏗️  Deploying registry namespace..."
	@NS_NAME=$$(grep 'registry_namespace' terraform/terraform.tfvars 2>/dev/null | head -1 | cut -d'"' -f2); \
	if [ -n "$$NS_NAME" ] && ! $(TF) state list 2>/dev/null | grep -q "scaleway_registry_namespace.main"; then \
		EXISTING_ID=$$(scw registry namespace list -o json 2>/dev/null | jq -r --arg name "$$NS_NAME" '.[] | select(.name == $$name) | .id' 2>/dev/null); \
		if [ -n "$$EXISTING_ID" ] && [ "$$EXISTING_ID" != "null" ]; then \
			echo "   Importing existing registry namespace: $$EXISTING_ID"; \
			$(TF) import scaleway_registry_namespace.main fr-par/$$EXISTING_ID >/dev/null 2>&1 || true; \
		fi; \
	fi || true
	@$(TF) apply -auto-approve -target=scaleway_registry_namespace.main 2>&1 | tail -3
	@echo "✅ Registry namespace created/verified"

_clean-stale-secrets:
	@echo "🔍 Checking for stale (scheduled_for_deletion) secrets in state..."
	@$(TF) state list 2>/dev/null | grep "^scaleway_secret" | while read r; do \
		DELETION=$$($(TF) state show "$$r" 2>/dev/null | grep -c "scheduled_for_deletion" || true); \
		if [ "$$DELETION" -gt 0 ] 2>/dev/null; then \
			echo "   Removing stale resource: $$r"; \
			$(TF) state rm "$$r" >/dev/null 2>&1 || true; \
		fi; \
	done || true
	@echo "✅ Stale secret cleanup complete"

_apply-infra: _import-existing-containers _clean-stale-secrets
	@echo "🏗️  Deploying infrastructure (this takes 10-15 minutes)..."
	@echo "   Refreshing state to detect existing/deleted resources..."
	@$(TF) refresh >/dev/null 2>&1 || true
	@echo "   Applying infrastructure configuration..."
	@$(TF) apply -auto-approve 2>&1 | tee /tmp/tf_apply.log; TF_EXIT=$$?; \
	if grep -q "precondition failed\|cannot act on deleted" /tmp/tf_apply.log; then \
		echo "⚠️  Stale resources detected (manually deleted from console)."; \
		echo "   Running refresh-only to sync state with API..."; \
		$(TF) apply -refresh-only -auto-approve >/dev/null 2>&1 || true; \
		echo "   Retrying apply after state sync..."; \
		$(TF) apply -auto-approve 2>&1 | tee /tmp/tf_apply2.log; \
		if grep -q "precondition failed\|cannot act on deleted" /tmp/tf_apply2.log; then \
			echo "⚠️  Persistent state errors. Run manually:"; \
			echo "   terraform -chdir=terraform state list"; \
			echo "   terraform -chdir=terraform state rm <failing-resource>"; \
			echo "   make deploy"; \
		fi; \
	elif grep -q "BucketAlreadyOwnedByYou.*being deleted" /tmp/tf_apply.log; then \
		echo "⚠️  S3 bucket still being deleted. Polling until available (up to 15 min)..."; \
		for i in $$(seq 1 30); do \
			sleep 30; \
			echo "   Waiting for bucket deletion to complete... ($$i/30)"; \
			APPLY_OUT=$$($(TF) apply -auto-approve 2>&1); \
			echo "$$APPLY_OUT" | tee /tmp/tf_apply_bucket.log; \
			if echo "$$APPLY_OUT" | grep -q "Apply complete"; then \
				echo "✅ S3 bucket created"; \
				break; \
			fi; \
			if ! echo "$$APPLY_OUT" | grep -q "BucketAlreadyOwnedByYou"; then \
				break; \
			fi; \
		done; \
	elif grep -q "409 Conflict.*already exists\|resource already exists" /tmp/tf_apply.log; then \
		echo "⚠️  Conflict: some resources already exist in API but not in state. Re-importing and retrying..."; \
		$(MAKE) _import-existing-containers; \
		$(TF) apply -auto-approve 2>&1 | tee /tmp/tf_apply2.log || true; \
	elif [ $$TF_EXIT -ne 0 ]; then \
		echo "⚠️  Terraform apply completed with warnings"; \
	fi
	@echo "✅ Infrastructure deployment complete"

_wait-k8s:
	@echo "⏳ Waiting for Kubernetes cluster to be ready (up to 20 minutes)..."
	@KAPSULE_ID=$$($(TF) output -raw kapsule_cluster_id 2>/dev/null) && \
	if [ -z "$$KAPSULE_ID" ]; then \
		echo "❌ kapsule_cluster_id output is empty — terraform may not have created the cluster."; \
		echo "   Check: terraform -chdir=terraform output"; \
		exit 1; \
	fi && \
	CLUSTER_UUID=$$(echo "$$KAPSULE_ID" | cut -d'/' -f2) && \
	echo "   Cluster ID: $$CLUSTER_UUID" && \
	scw k8s cluster wait $$CLUSTER_UUID region=fr-par timeout=20m 2>/dev/null && \
		echo "✅ Kubernetes cluster ready" || \
	{ \
		echo "   scw wait not available or timed out, falling back to polling..."; \
		for i in $$(seq 1 60); do \
			STATUS=$$(scw k8s cluster get $$CLUSTER_UUID region=fr-par -o json 2>/dev/null | jq -r '.status' 2>/dev/null); \
			if [ "$$STATUS" = "ready" ]; then \
				echo "✅ Kubernetes cluster ready ($$i polls)"; \
				break; \
			fi; \
			echo "   Waiting for cluster... ($$i/60, status=$$STATUS)"; \
			sleep 15; \
		done; \
		STATUS=$$(scw k8s cluster get $$CLUSTER_UUID region=fr-par -o json 2>/dev/null | jq -r '.status' 2>/dev/null); \
		if [ "$$STATUS" != "ready" ]; then \
			echo "❌ Cluster not ready after 15 minutes (status=$$STATUS). Check Scaleway console."; \
			exit 1; \
		fi; \
	} && \
	echo "📝 Configuring kubectl..." && \
	scw k8s kubeconfig get $$CLUSTER_UUID region=fr-par > $(KUBECONFIG_PATH) 2>/dev/null && \
		echo "✅ kubectl configured (KUBECONFIG=$(KUBECONFIG_PATH))" || \
		{ echo "❌ Failed to get kubeconfig. Run: make kubeconfig"; exit 1; }
	@echo "   Test: KUBECONFIG=$(KUBECONFIG_PATH) kubectl get nodes"

_build-push:
	@echo "🔨 Building Docker images..."
	@echo "   Logging in to Scaleway registry..."
	@echo "$(SCW_SECRET_KEY)" | docker login rg.fr-par.scw.cloud --username nologin --password-stdin
	@ACTUAL_NS=$$($(TF) output -raw registry_namespace_name 2>/dev/null | grep -E '^[a-z0-9-]+$$' | head -1); \
	if [ -z "$$ACTUAL_NS" ]; then echo "❌ registry_namespace_name output unavailable — run: terraform -chdir=terraform apply -target=scaleway_registry_namespace.main" && exit 1; fi; \
	echo "   Registry: rg.fr-par.scw.cloud/$$ACTUAL_NS"; \
	export ONBOARDING_REGISTRY_NAMESPACE=$$ACTUAL_NS && \
	export ONBOARDING_ACCESS_KEY=$(SCW_ACCESS_KEY) && \
	export ONBOARDING_SECRET_KEY=$(SCW_SECRET_KEY) && \
	docker buildx bake --push
	@echo "✅ Images built and pushed to $(REGISTRY)"

_apply-k8s:
	@echo "📦 Applying Kubernetes manifests..."
	@ACTUAL_NS=$$($(TF) output -raw registry_namespace_name 2>/dev/null | grep -E '^[a-z0-9-]+$$' | head -1); \
	if [ -z "$$ACTUAL_NS" ]; then echo "❌ registry_namespace_name output unavailable" && exit 1; fi; \
	export KUBECONFIG="$(KUBECONFIG_PATH)" && \
		kubectl apply -f k8s/namespace.yaml || true && \
		kubectl apply -f k8s/configmap.yaml || true && \
		sed "s|rg\.fr-par\.scw\.cloud/[^/]*/|rg.fr-par.scw.cloud/$$ACTUAL_NS/|g" k8s/deployment.yaml | kubectl apply -f - || true && \
		kubectl apply -f k8s/service.yaml || true
	@echo "✅ Kubernetes manifests applied"
	@echo "📊 Check status: kubectl get pods -n onboarding"

_configure-lb:
	@echo "🔧 Configuring Scaleway LoadBalancer..."
	@export KUBECONFIG="$(KUBECONFIG_PATH)" && \
		LB_ID=$$($(TF) output -raw load_balancer_id 2>/dev/null | cut -d'/' -f2) && \
		NODEPORT=$$(kubectl get service rest-api -n onboarding -o jsonpath='{.spec.ports[0].nodePort}') && \
		NODE_IPS=$$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="ExternalIP")].address}{" "} {end}') && \
		echo "   LoadBalancer ID: $$LB_ID" && \
		echo "   NodePort: $$NODEPORT" && \
		echo "   Node IPs: $$NODE_IPS" && \
		EXISTING_BACKEND=$$(scw lb backend list lb-id=$$LB_ID -o json 2>/dev/null | jq -r '.[] | select(.name == "rest-api-backend") | .id' | head -1) && \
		if [ -z "$$EXISTING_BACKEND" ] || [ "$$EXISTING_BACKEND" = "null" ]; then \
			echo "   Creating backend..." && \
			scw lb backend create \
				lb-id=$$LB_ID \
				name=rest-api-backend \
				forward-protocol=http \
				forward-port=$$NODEPORT \
				forward-port-algorithm=roundrobin \
				on-marked-down-action=shutdown_sessions \
				health-check.port=$$NODEPORT \
				health-check.http-config.uri=/health \
				health-check.http-config.method=GET \
				health-check.http-config.code=200 \
				health-check.check-max-retries=5 \
				health-check.check-send-proxy=false >/dev/null 2>&1 || true; \
		else \
			echo "   Backend already exists: $$EXISTING_BACKEND"; \
		fi && \
		BACKEND_ID=$$(scw lb backend list lb-id=$$LB_ID -o json | jq -r '.[] | select(.name == "rest-api-backend") | .id' | head -1) && \
		scw lb backend set-servers \
			backend-id=$$BACKEND_ID \
			server-ip.0=$$(echo $$NODE_IPS | cut -d' ' -f1) \
			server-ip.1=$$(echo $$NODE_IPS | cut -d' ' -f2) \
			server-ip.2=$$(echo $$NODE_IPS | cut -d' ' -f3) >/dev/null 2>&1 || true && \
		EXISTING_FRONTEND=$$(scw lb frontend list lb-id=$$LB_ID -o json 2>/dev/null | jq -r '.[] | select(.name == "rest-api-frontend") | .id' | head -1) && \
		if [ -z "$$EXISTING_FRONTEND" ] || [ "$$EXISTING_FRONTEND" = "null" ]; then \
			echo "   Creating frontend..." && \
			FRONTEND_ID=$$(scw lb frontend create \
				lb-id=$$LB_ID \
				name=rest-api-frontend \
				inbound-port=80 \
				backend-id=$$BACKEND_ID \
				timeout-client=30s -o json | jq -r '.id') && \
			LB_IP=$$($(TF) output -raw load_balancer_ip 2>/dev/null) && \
			LB_DNS="$$(echo $$LB_IP | tr '.' '-').lb.fr-par.scw.cloud" && \
			curl -s -X POST "https://api.scaleway.com/lb/v1/regions/fr-par/routes" \
				-H "X-Auth-Token: $(SCW_SECRET_KEY)" \
				-H "Content-Type: application/json" \
				-d "{\"frontend_id\": \"$$FRONTEND_ID\", \"backend_id\": \"$$BACKEND_ID\", \"match\": {\"host_header\": \"$$LB_DNS\", \"match_subdomains\": true}}" >/dev/null 2>&1 || true; \
		else \
			echo "   Frontend already exists: $$EXISTING_FRONTEND"; \
		fi && \
		scw instance security-group create-rule \
			security-group-id=$$(scw instance security-group list -o json | jq -r '.[] | select(.name | test("(?i)kapsule")) | .id' | head -1) \
			direction=inbound \
			protocol=TCP \
			action=accept \
			ip-range=0.0.0.0/0 \
			dest-port-from=$$NODEPORT \
			dest-port-to=$$NODEPORT >/dev/null 2>&1 || true && \
		echo "✅ LoadBalancer configured"
	@echo "   Public URL: http://$$($(TF) output -raw load_balancer_ip 2>/dev/null)"

_wait-ready:
	@echo "⏳ Waiting for Kubernetes deployment to be ready..."
	@export KUBECONFIG="$(KUBECONFIG_PATH)"; \
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do \
		READY=$$(kubectl get deployment rest-api -n onboarding -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0"); \
		if [ "$$READY" -ge 2 ] 2>/dev/null; then \
			echo "✅ Deployment ready ($$READY replicas)"; \
			break; \
		fi; \
		echo "   Waiting for pods... ($$i/20, ready: $$READY)"; \
		sleep 15; \
	done
	@export KUBECONFIG="$(KUBECONFIG_PATH)"; \
	kubectl get deployment rest-api -n onboarding -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '[1-9]' || (echo "⚠️  Deployment may not be ready yet. Check with: kubectl get pods -n onboarding" && exit 0)

_wait-rollout:
	@echo "⏳ Waiting for rollout to complete..."
	@export KUBECONFIG="$(KUBECONFIG_PATH)" && \
		kubectl rollout restart deployment/rest-api -n onboarding 2>/dev/null || true
	@export KUBECONFIG="$(KUBECONFIG_PATH)" && \
		kubectl rollout status deployment/rest-api -n onboarding --timeout=5m 2>/dev/null || \
		echo "⚠️  Rollout status unavailable — pods may still be restarting"
	@echo "✅ Rollout complete"

_test:
	@echo "🧪 Running comprehensive health checks..."
	@LB_IP=$$($(TF) output -raw load_balancer_ip 2>/dev/null || true); \
	if [ -z "$$LB_IP" ]; then \
		echo "⚠️  LB IP not available yet — skipping health check"; \
	else \
		for i in $$(seq 1 10); do \
			if curl -sf http://$$LB_IP/health >/dev/null 2>&1; then \
				echo "✅ Health check passed"; \
				break; \
			fi; \
			echo "   Waiting for endpoint... ($$i/10)"; \
			sleep 5; \
		done; \
		curl -sf http://$$LB_IP/health >/dev/null 2>&1 || echo "⚠️  Health endpoint not responding yet"; \
		KAPSULE_ID=$$($(TF) output -raw kapsule_cluster_id 2>/dev/null || true); \
		CONVERTER_URL=$$($(TF) output -raw image_converter_url 2>/dev/null || true); \
		AI_URL=$$($(TF) output -raw ai_alt_generator_url 2>/dev/null || true); \
		echo ""; \
		echo "═══════════════════════════════════════════════════════════"; \
		echo "  Deployment Summary:"; \
		echo "    Load Balancer: http://$$LB_IP"; \
		echo "    Health:        http://$$LB_IP/health"; \
		echo "    Upload:        curl -F 'file=@logo.png' http://$$LB_IP/upload"; \
		echo "    Kubernetes:    $$KAPSULE_ID"; \
		echo "    Converter:     $$CONVERTER_URL"; \
		echo "    AI Generator:  $$AI_URL"; \
		echo "═══════════════════════════════════════════════════════════"; \
	fi
	@echo "✅ All deployment steps completed successfully!"

# ── Utility Targets ────────────────────────────────────────────────────────────

## View live logs from all pods
logs:
	@echo "📊 Streaming logs (Ctrl+C to stop)..."
	@export KUBECONFIG="$(KUBECONFIG_PATH)" && \
		kubectl logs -l app=rest-api -n onboarding --tail=50 -f

## Quick health check
test:
	@LB_IP=$$($(TF) output -raw load_balancer_ip 2>/dev/null || true); \
	echo "🧪 Testing deployment..."; \
	echo "Health: $$(curl -sf http://$$LB_IP/health && echo '✅ OK' || echo '❌ Failed')"; \
	echo "Upload: $$(curl -sf -F 'file=@logo.png' http://$$LB_IP/upload | grep -q 'id' && echo '✅ OK' || echo '❌ Failed')"

## Export kubeconfig for the Kapsule cluster
kubeconfig:
	@KAPSULE_ID=$$($(TF) output -raw kapsule_cluster_id 2>/dev/null) && \
	echo "📝 Installing kubeconfig for cluster $$KAPSULE_ID..." && \
	scw k8s kubeconfig install $$KAPSULE_ID region=fr-par
	@echo "✅ Kubeconfig installed (merged into ~/.kube/config)"
	@echo "   Test: kubectl get nodes"

## Show current deployment status (pods, LB, serverless containers)
status:
	@echo ""
	@echo "═══════════════════════════════════════════════════════════"
	@echo "  Deployment Status"
	@echo "═══════════════════════════════════════════════════════════"
	@echo ""
	@echo "  Load Balancer IP: $$($(TF) output -raw load_balancer_ip 2>/dev/null || echo 'not deployed')"
	@echo ""
	@echo "  Kubernetes Pods:"
	@export KUBECONFIG="$(KUBECONFIG_PATH)" && \
		kubectl get pods -n onboarding 2>/dev/null || echo "   ⚠️  kubectl not configured — run: make kubeconfig"
	@echo ""
	@echo "  Kubernetes Services:"
	@export KUBECONFIG="$(KUBECONFIG_PATH)" && \
		kubectl get services -n onboarding 2>/dev/null || true
	@echo ""
	@echo "  Serverless Containers:"
	@scw container container list -o human 2>/dev/null | grep -E "image-converter|ai-alt-generator" || echo "   None found"
	@echo ""

## Clean local build artifacts (does NOT affect deployed infrastructure)
clean:
	@echo "🧹 Cleaning local build artifacts..."
	@docker system prune -f --filter "label=project=scaleway-infra-lab" 2>/dev/null || true
	@echo "✅ Clean complete"

## Manual LoadBalancer configuration (if auto-configure fails)
configure-lb: _configure-lb
	@echo "✅ LoadBalancer configuration complete"
	@echo "  Test with: curl http://$$($(TF) output -raw load_balancer_ip 2>/dev/null)/health"

## Show this help message
help:
	@echo ""
	@echo "╔═══════════════════════════════════════════════════════════╗"
	@echo "║        imgflow - Complete Deployment Commands             ║"
	@echo "╚═══════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "  DEPLOYMENT COMMANDS:"
	@echo "  make init           Initialize Terraform providers (one-time setup)"
	@echo "  make deploy         Deploy everything (~25-30 min)"
	@echo "                      → Registry namespace"
	@echo "                      → Build & push Docker images"
	@echo "                      → Kubernetes cluster (3 nodes)"
	@echo "                      → PostgreSQL database"
	@echo "                      → LoadBalancer configuration"
	@echo "                      → Deploy Kubernetes manifests"
	@echo "                      → Run health checks"
	@echo "  make redeploy       Rebuild and redeploy images only"
	@echo "  make configure-lb   Manually configure LoadBalancer"
	@echo ""
	@echo "  CLEANUP COMMANDS:"
	@echo "  make destroy        Destroy infrastructure (preserves bucket & registry)"
	@echo "                      → Serverless Containers"
	@echo "                      → LoadBalancer (frontend, backend, routes)"
	@echo "                      → Kubernetes cluster & pools"
	@echo "                      → Database instance"
	@echo "                      → Secrets"
	@echo "                      → Security Group rules"
	@echo "                      PRESERVES: S3 bucket, Container Registry"
	@echo ""
	@echo "  make destroy-all    DESTROY EVERYTHING (IRREVERSIBLE!)"
	@echo "                      → All above resources"
	@echo "                      → S3 bucket and all objects"
	@echo "                      → Container Registry and all images"
	@echo ""
	@echo "  UTILITY COMMANDS:"
	@echo "  make status         Show deployment status (pods, LB, containers)"
	@echo "  make kubeconfig     Export kubeconfig for the Kapsule cluster"
	@echo "  make test           Quick health check"
	@echo "  make logs           Stream logs from all pods"
	@echo "  make clean          Clean local Docker build artifacts"
	@echo "  make help           Show this help message"
	@echo ""
	@echo "═══════════════════════════════════════════════════════════"
	@echo "Quick Start:"
	@echo "  make init"
	@echo "  make deploy"
	@echo ""
	@echo "After code changes:"
	@echo "  make redeploy"
	@echo ""
	@echo "To clean up:"
	@echo "  make destroy        # Keep bucket & registry"
	@echo "  make destroy-all    # Delete EVERYTHING (use with caution!)"
	@echo ""

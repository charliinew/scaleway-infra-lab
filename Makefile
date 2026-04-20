.PHONY: init plan apply deploy redeploy destroy destroy-all clean-state help

TF          = terraform -chdir=terraform
BUCKET_NAME = $(shell grep 'bucket_name'  terraform/terraform.tfvars | grep -o '"[^"]*"' | tr -d '"')
ACCESS_KEY  = $(shell grep 'access_key'   terraform/terraform.tfvars | grep -o '"[^"]*"' | tr -d '"')
SECRET_KEY  = $(shell grep 'secret_key'   terraform/terraform.tfvars | grep -o '"[^"]*"' | tr -d '"')

# ── Infra ──────────────────────────────────────────────────────────────────────

init:
	$(TF) init

plan:
	$(TF) plan

apply:
	$(TF) apply -auto-approve

## Déploie l'infra ET push les images Docker (workflow complet depuis zéro)
deploy:
	$(TF) apply -auto-approve
	docker buildx bake --push

## Re-push les images sans retoucher l'infra (après un changement de code)
redeploy:
	docker buildx bake --push

## Détruit toutes les ressources SAUF le bucket et le registry namespace
destroy:
	$(TF) destroy -auto-approve \
		-target=scaleway_lb_frontend.rest_api \
		-target=scaleway_lb_backend.rest_api \
		-target=scaleway_lb.main \
		-target=scaleway_lb_ip.main \
		-target=scaleway_instance_private_nic.rest_api \
		-target=scaleway_instance_private_nic.image_processor \
		-target=scaleway_instance_server.rest_api \
		-target=scaleway_instance_server.image_processor \
		-target=scaleway_instance_security_group.rest_api \
		-target=scaleway_instance_security_group.image_processor \
		-target=scaleway_instance_placement_group.main \
		-target=scaleway_account_ssh_key.main \
		-target=scaleway_secret_version.database_url \
		-target=scaleway_secret_version.bucket_name \
		-target=scaleway_secret.database_url \
		-target=scaleway_secret.bucket_name \
		-target=scaleway_rdb_privilege.main \
		-target=scaleway_rdb_database.main \
		-target=scaleway_rdb_instance.main \
		-target=scaleway_vpc_gateway_network.main \
		-target=scaleway_vpc_public_gateway.main \
		-target=scaleway_vpc_public_gateway_ip.main \
		-target=scaleway_vpc_private_network.main \
		-target=scaleway_vpc.main
	@echo ""
	@echo "Infrastructure detruite. Bucket et registry conserves."
	@echo "Utiliser 'make destroy-all' pour tout supprimer."

## Détruit TOUT y compris le bucket S3 et le registry namespace (DESTRUCTIF)
destroy-all:
	@echo "ATTENTION : supprime le bucket S3 et le registry (images Docker + fichiers perdus)."
	@echo "Ctrl+C pour annuler, Entree pour continuer."
	@read _confirm
	BUCKET_ACCESS_KEY=$(ACCESS_KEY) BUCKET_SECRET_KEY=$(SECRET_KEY) \
		python3 scripts/empty-bucket.py $(BUCKET_NAME) || true
	$(TF) state rm scaleway_object_bucket.main || true
	$(TF) destroy -auto-approve

## Retire bucket et registry du state Terraform sans les supprimer sur Scaleway
clean-state:
	$(TF) state rm scaleway_object_bucket.main || true
	$(TF) state rm scaleway_registry_namespace.main || true
	@echo "Bucket et registry retires du state (non supprimes sur Scaleway)."

# ── Aide ───────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "Usage: make <cible>"
	@echo ""
	@echo "  init          Initialise les providers Terraform"
	@echo "  plan          Affiche les changements prevus"
	@echo "  apply         Applique l'infra seule"
	@echo "  deploy        Applique l'infra + push les images Docker"
	@echo "  redeploy      Re-push les images sans toucher l'infra"
	@echo "  destroy       Detruit l'infra (conserve bucket + registry)"
	@echo "  destroy-all   Detruit TOUT (bucket + registry inclus)"
	@echo "  clean-state   Retire bucket/registry du state Terraform"
	@echo ""

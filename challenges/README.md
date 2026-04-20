# Onboarding Challenges — Journal de bord

Ce dossier documente en détail chaque challenge d'onboarding réalisé, les décisions prises, les erreurs rencontrées et comment elles ont été résolues.

## Architecture générale

L'application est un convertisseur PNG → JPEG déployé sur Scaleway, composé de deux services :

- **rest-api** (Python/FastAPI) : reçoit les uploads PNG, délègue au processor, stocke en Object Storage et enregistre en base
- **image-processor** (Rust/actix-web) : convertit PNG → JPEG

```
Internet
   │
   ▼
Load Balancer (LB-S)  :80
   │
   ▼ HTTP :8080
rest-api (DEV1-S)
   │                        ┌─────────────────────────┐
   ├─── HTTP :9090 ────────▶│ image-processor (DEV1-S)│
   │                        └─────────────────────────┘
   ├─── S3 API ────────────▶ Object Storage (bucket)
   ├─── PostgreSQL :5432 ──▶ Managed DB (DB-DEV-S)
   └─── HTTPS ─────────────▶ Secret Manager (API)

Réseau privé (VPC + Private Network)
   └── Public Gateway (SSH bastion :61000)
```

## Challenges réalisés

| # | Challenge | Fichier |
|---|-----------|---------|
| 1 | Infrastructure as Code avec Terraform | [01-terraform.md](./01-terraform.md) |
| 2 | Secrets Manager | [02-secret-manager.md](./02-secret-manager.md) |

## Ressources déployées (22 au total)

| Ressource Terraform | Type Scaleway | Rôle |
|---------------------|---------------|------|
| `scaleway_vpc.main` | VPC | Réseau isolé |
| `scaleway_vpc_private_network.main` | Private Network | LAN privé des instances |
| `scaleway_vpc_public_gateway_ip.main` | IP publique | IP fixe du gateway |
| `scaleway_vpc_public_gateway.main` | VPC-GW-S | NAT + bastion SSH |
| `scaleway_vpc_gateway_network.main` | Gateway Network | Attache gateway ↔ réseau privé |
| `scaleway_account_ssh_key.main` | SSH Key | Accès SSH aux instances |
| `scaleway_instance_placement_group.main` | Placement Group | Low-latency entre instances |
| `scaleway_instance_security_group.image_processor` | Security Group | Firewall image-processor |
| `scaleway_instance_security_group.rest_api` | Security Group | Firewall rest-api |
| `scaleway_instance_server.image_processor` | DEV1-S | VM image-processor |
| `scaleway_instance_private_nic.image_processor` | Private NIC | NIC réseau privé |
| `scaleway_instance_server.rest_api` | DEV1-S | VM rest-api |
| `scaleway_instance_private_nic.rest_api` | Private NIC | NIC réseau privé |
| `scaleway_rdb_instance.main` | DB-DEV-S | PostgreSQL 15 managé |
| `scaleway_rdb_database.main` | Database | Base `onboarding` |
| `scaleway_rdb_privilege.main` | Privilege | Droits `ALL` sur la base |
| `scaleway_registry_namespace.main` | Registry | Namespace Docker privé |
| `scaleway_object_bucket.main` | Bucket | Stockage images JPEG |
| `scaleway_lb_ip.main` | IP publique | IP fixe du LB |
| `scaleway_lb.main` | LB-S | Load Balancer HTTP |
| `scaleway_lb_backend.rest_api` | LB Backend | Cible rest-api :8080 |
| `scaleway_lb_frontend.rest_api` | LB Frontend | Point d'entrée :80 |
| `scaleway_secret.database_url` | Secret | Conteneur secret DB URL |
| `scaleway_secret_version.database_url` | Secret Version | Valeur DB URL |
| `scaleway_secret.bucket_name` | Secret | Conteneur secret bucket |
| `scaleway_secret_version.bucket_name` | Secret Version | Valeur bucket name |

## Commandes (depuis la racine du projet)

```bash
make init         # Initialise les providers Terraform
make plan         # Prévisualise les changements
make apply        # Applique l'infra seule
make deploy       # Applique l'infra + push les images Docker
make redeploy     # Re-push les images sans toucher l'infra
make destroy      # Détruit l'infra (conserve bucket + registry)
make destroy-all  # Détruit TOUT (bucket + registry inclus — DESTRUCTIF)
make clean-state  # Retire bucket/registry du state sans les supprimer sur Scaleway
```

## Séquences de commandes selon le cas

| Cas | Séquence |
|-----|----------|
| **Premier déploiement** | `make init` → `make deploy` |
| **Redéploiement complet** (reset de l'infra) | `make destroy-all` → `make deploy` |
| **Reset infra, garder bucket + registry** | `make destroy` → `make deploy` |
| **Changement de code uniquement** (app.py, Rust…) | `make redeploy` |
| **Changement d'infra uniquement** (terraform) | `make apply` |
| **Fin de journée / pause** (éviter surcoûts) | `make destroy` |
| **Reprise après `make destroy`** | `make deploy` |
| **Importer bucket/registry existants dans le state** | `make init` → `terraform -chdir=terraform import …` → `make deploy` |

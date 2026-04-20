# Challenge 1 — Infrastructure as Code avec Terraform

## Objectif

Décrire **toute l'infrastructure** de l'application en Terraform au lieu de la créer manuellement via la console Scaleway. Une seule commande (`terraform apply`) doit suffire à provisionner l'environnement complet.

Les sous-points couverts :
- Security Groups (firewalls par instance)
- Placement Groups (latence réduite entre instances)
- cloud-init (configuration automatique des VMs au démarrage)

---

## Structure des fichiers

```
terraform/
├── main.tf           # Provider Scaleway + version Terraform
├── variables.tf      # Déclaration de toutes les variables
├── terraform.tfvars  # Valeurs réelles (gitignored)
├── locals.tf         # Calculs locaux (extraction IP privée IPv4)
├── network.tf        # VPC, Private Network, Public Gateway
├── compute.tf        # Security Groups, Placement Group, Instances
├── database.tf       # PostgreSQL managé
├── registry.tf       # Container Registry (namespace Docker)
├── storage.tf        # Object Storage (bucket S3)
├── loadbalancer.tf   # Load Balancer, Backend, Frontend
├── secrets.tf        # Secret Manager
├── outputs.tf        # Outputs (IPs, commandes SSH, etc.)
└── cloud-init/
    ├── image-processor.yaml.tpl
    └── rest-api.yaml.tpl
```

---

## main.tf — Provider

```hcl
terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.49"
    }
  }
  required_version = ">= 1.0"
}

provider "scaleway" {
  access_key      = var.access_key
  secret_key      = var.secret_key
  organization_id = var.organization_id
  project_id      = var.project_id
  region          = "fr-par"
  zone            = "fr-par-1"
}
```

Les credentials viennent de `terraform.tfvars` (jamais commité) via les variables déclarées dans `variables.tf`.

---

## network.tf — VPC & Private Network

```hcl
resource "scaleway_vpc" "main" {
  name = "onboarding-vpc"
}

resource "scaleway_vpc_private_network" "main" {
  name   = "onboarding-pn"
  vpc_id = scaleway_vpc.main.id
}

resource "scaleway_vpc_public_gateway_ip" "main" {}

resource "scaleway_vpc_public_gateway" "main" {
  name            = "onboarding-pgw"
  type            = "VPC-GW-S"
  ip_id           = scaleway_vpc_public_gateway_ip.main.id
  bastion_enabled = true
}

resource "scaleway_vpc_gateway_network" "main" {
  gateway_id         = scaleway_vpc_public_gateway.main.id
  private_network_id = scaleway_vpc_private_network.main.id
  enable_masquerade  = true

  ipam_config {
    push_default_route = true
  }
}
```

### Pourquoi le Public Gateway ?

Les instances sont sur un réseau **100% privé** (pas d'IP publique). Le Public Gateway joue deux rôles :

1. **NAT masquerade** : permet aux instances d'accéder à internet (pour `apt`, `docker pull`, etc.) sans avoir d'IP publique.
2. **SSH Bastion** (`bastion_enabled = true`) : expose un accès SSH sur le port `61000` de l'IP publique du gateway. On s'y connecte avec `-J bastion@<gateway-ip>:61000`.

### Erreur rencontrée : `push_default_route`

**Symptôme** : les instances démarraient mais ne pouvaient pas accéder à internet (timeout sur `apt-get`, `docker pull`). Le cloud-init échouait silencieusement.

**Cause** : sans `push_default_route = true`, le gateway ne pousse pas de route par défaut aux instances via DHCP. Elles n'ont donc pas de gateway configuré (`ip route` ne montrait pas de route `default`).

**Fix** : ajouter le bloc `ipam_config { push_default_route = true }` dans `scaleway_vpc_gateway_network`. Ce bloc est **à l'intérieur** de `ipam_config {}`, pas à la racine de la ressource.

**Erreur annexe** : la ressource `scaleway_vpc_public_gateway_dhcp` est **dépréciée** dans les versions récentes du provider. Il ne faut pas la créer ni référencer `dhcp_id` dans `gateway_network`.

---

## compute.tf — Instances, Security Groups, Placement Group

### Security Groups

```hcl
resource "scaleway_instance_security_group" "image_processor" {
  name                    = "sg-image-processor"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  inbound_rule {
    action = "accept"
    port   = 22
    protocol = "TCP"
  }
  inbound_rule {
    action = "accept"
    port   = 9090
    protocol = "TCP"
  }
}

resource "scaleway_instance_security_group" "rest_api" {
  name                    = "sg-rest-api"
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"

  inbound_rule {
    action = "accept"
    port   = 22
    protocol = "TCP"
  }
  inbound_rule {
    action = "accept"
    port   = 8080
    protocol = "TCP"
  }
}
```

Politique : **drop par défaut** en entrée, seuls les ports nécessaires sont ouverts. Le trafic sortant est libre (pour les appels API Scaleway, les pulls Docker, etc.).

### Placement Group

```hcl
resource "scaleway_instance_placement_group" "main" {
  name        = "onboarding-pg"
  policy_type = "low_latency"
  policy_mode = "optional"
}
```

- `policy_type = "low_latency"` : Scaleway place les instances sur des hôtes physiques proches pour minimiser la latence réseau entre rest-api et image-processor.
- `policy_mode = "optional"` : si Scaleway ne peut pas satisfaire la contrainte (capacité insuffisante), les instances sont quand même créées. En `"enforced"`, elles échoueraient.

### Instances

```hcl
resource "scaleway_instance_server" "rest_api" {
  name               = "onboarding-rest-api"
  type               = var.instance_type   # DEV1-S
  image              = "ubuntu_jammy"
  security_group_id  = scaleway_instance_security_group.rest_api.id
  placement_group_id = scaleway_instance_placement_group.main.id

  root_volume {
    size_in_gb = 20
  }

  user_data = {
    "cloud-init" = templatefile("${path.module}/cloud-init/rest-api.yaml.tpl", {
      registry_namespace = var.registry_namespace
      secret_key         = var.secret_key
      access_key         = var.access_key
      project_id         = var.project_id
      image_processor_ip = local.image_processor_ipv4
    })
  }

  depends_on = [scaleway_rdb_instance.main]
}
```

Le `depends_on` sur `scaleway_rdb_instance.main` garantit que la base de données est prête avant que l'instance rest-api ne démarre (et tente de s'y connecter).

### NICs réseau privé

Les instances sont créées **sans IP publique**. Pour les attacher au réseau privé, on crée des NICs séparés :

```hcl
resource "scaleway_instance_private_nic" "rest_api" {
  server_id          = scaleway_instance_server.rest_api.id
  private_network_id = scaleway_vpc_private_network.main.id
}
```

Le DHCP interne au réseau privé leur attribue automatiquement une IP.

### Erreur rencontrée : extraction de l'IP privée IPv4

**Problème** : `scaleway_instance_private_nic.rest_api.private_ips` retourne une liste contenant **à la fois une IPv4 et une IPv6** (dual-stack). Passer une IPv6 comme `server_ips` au load balancer ou comme `image_processor_ip` dans cloud-init provoque des erreurs.

**Fix** dans `locals.tf` : filtrer par l'absence du caractère `:` (présent uniquement dans les adresses IPv6) :

```hcl
locals {
  image_processor_ipv4 = [
    for ip in scaleway_instance_private_nic.image_processor.private_ips : ip.address
    if !can(regex(":", ip.address))
  ][0]

  rest_api_ipv4 = [
    for ip in scaleway_instance_private_nic.rest_api.private_ips : ip.address
    if !can(regex(":", ip.address))
  ][0]
}
```

---

## cloud-init — Configuration automatique des VMs

Le cloud-init est le mécanisme standard pour exécuter des scripts au **premier démarrage** d'une VM. Terraform l'injecte via `user_data`.

### cloud-init/image-processor.yaml.tpl

```yaml
#cloud-config

runcmd:
  - |
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
    until ip route | grep -q default; do sleep 5; done
    curl -fsSL https://get.docker.com | sh
    echo "${secret_key}" | docker login rg.fr-par.scw.cloud/${registry_namespace} -u nologin --password-stdin
    docker run -d --restart unless-stopped -p 9090:9090 --name image-processor \
      --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
      rg.fr-par.scw.cloud/${registry_namespace}/image-processor:latest
```

### cloud-init/rest-api.yaml.tpl

```yaml
#cloud-config

runcmd:
  - |
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
    until ip route | grep -q default; do sleep 5; done
    curl -fsSL https://get.docker.com | sh
    echo "${secret_key}" | docker login rg.fr-par.scw.cloud/${registry_namespace} -u nologin --password-stdin
    docker run -d --restart unless-stopped -p 8080:8080 --name rest-api \
      --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
      -e ONBOARDING_IMAGE_PROCESSOR_URL="http://${image_processor_ip}:9090" \
      -e ONBOARDING_ACCESS_KEY="${access_key}" \
      -e ONBOARDING_SECRET_KEY="${secret_key}" \
      -e ONBOARDING_PROJECT_ID="${project_id}" \
      rg.fr-par.scw.cloud/${registry_namespace}/rest-api:latest
```

### Erreurs rencontrées dans cloud-init

**1. Pas de route par défaut au démarrage**

Le NIC réseau privé est attaché **après** la création de l'instance. Au moment où cloud-init s'exécute, le gateway n'a pas encore poussé la route par défaut. Résultat : `curl`, `apt-get` et `docker pull` échouent par timeout.

**Fix** : boucle d'attente avant toute opération réseau :
```bash
until ip route | grep -q default; do sleep 5; done
```

**2. `apt-get` timeout sur IPv6**

Ubuntu Jammy essaie d'abord IPv6 pour contacter les miroirs apt. Le réseau privé est dual-stack mais la connectivité IPv6 externe n'est pas assurée par le gateway NAT.

**Fix** : forcer apt en IPv4 :
```bash
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
```

**3. `docker login` avec here-string `<<<`**

La syntaxe bash `<<<` (here-string) n'est pas supportée dans tous les contextes d'exécution cloud-init.

**Fix** : utiliser un pipe explicite :
```bash
echo "${secret_key}" | docker login ... --password-stdin
```

---

## database.tf — PostgreSQL Managé

```hcl
resource "scaleway_rdb_instance" "main" {
  name           = "onboarding-db"
  node_type      = "DB-DEV-S"
  engine         = "PostgreSQL-15"
  is_ha_cluster  = false
  disable_backup = true
  user_name      = var.db_user
  password       = var.db_password

  private_network {
    pn_id       = scaleway_vpc_private_network.main.id
    enable_ipam = true
  }

  depends_on = [scaleway_vpc_gateway_network.main]
}

resource "scaleway_rdb_database" "main" {
  instance_id = scaleway_rdb_instance.main.id
  name        = var.db_name
}

resource "scaleway_rdb_privilege" "main" {
  instance_id   = scaleway_rdb_instance.main.id
  user_name     = var.db_user
  database_name = scaleway_rdb_database.main.name
  permission    = "all"
}
```

La base est attachée au réseau privé uniquement (`enable_ipam = true`). Elle n'est pas accessible depuis internet.

### Erreur rencontrée : `permission denied for database`

**Symptôme** : la rest-api démarrait, se connectait à PostgreSQL, mais SQLAlchemy échouait avec `permission denied for database onboarding` au moment de créer les tables (`Base.metadata.create_all`).

**Cause** : Scaleway crée le user `onboarding` avec l'instance RDB, mais ne lui donne pas automatiquement les droits sur la base de données créée séparément via `scaleway_rdb_database`.

**Fix** : ajouter `scaleway_rdb_privilege` avec `permission = "all"`.

---

## loadbalancer.tf — Load Balancer

```hcl
resource "scaleway_lb_ip" "main" {}

resource "scaleway_lb" "main" {
  name   = "onboarding-lb"
  ip_ids = [scaleway_lb_ip.main.id]
  type   = "LB-S"

  private_network {
    private_network_id = scaleway_vpc_private_network.main.id
  }
}

resource "scaleway_lb_backend" "rest_api" {
  lb_id            = scaleway_lb.main.id
  name             = "backend-rest-api"
  forward_protocol = "http"
  forward_port     = 8080
  server_ips       = [local.rest_api_ipv4]

  health_check_http {
    uri = "/health"
  }
}

resource "scaleway_lb_frontend" "rest_api" {
  lb_id        = scaleway_lb.main.id
  backend_id   = scaleway_lb_backend.rest_api.id
  name         = "frontend-http"
  inbound_port = 80
}
```

### Erreurs rencontrées

**1. `ip_id` déprécié**

Le provider récent utilise `ip_ids` (liste) au lieu de `ip_id` (scalaire).

**Fix** : `ip_ids = [scaleway_lb_ip.main.id]`

**2. `dhcp_config` dans `private_network`**

L'ancienne doc mentionnait un bloc `dhcp_config {}` dans `private_network`. Ce bloc n'est plus configurable dans les versions récentes du provider et provoque une erreur.

**Fix** : supprimer le bloc `dhcp_config`, laisser uniquement `private_network_id`.

---

## registry.tf & storage.tf — Ressources existantes importées

Le bucket Object Storage et le namespace Container Registry existaient déjà avant la mise en place de Terraform. Plutôt que de les recréer (ce qui détruirait les données), ils ont été **importés** dans le state Terraform :

```bash
# Importer le namespace registry
terraform import scaleway_registry_namespace.main fr-par/<namespace-id>

# Importer le bucket
terraform import scaleway_object_bucket.main fr-par/<bucket-name>
```

Les IDs se récupèrent avec la CLI :
```bash
scw registry namespace list
scw object bucket list
```

---

## outputs.tf — Sorties utiles

```hcl
output "load_balancer_ip" { ... }
output "gateway_ip" { ... }
output "image_processor_private_ip" { ... }
output "rest_api_private_ip" { ... }
output "ssh_bastion_command_image_processor" { ... }
output "ssh_bastion_command_rest_api" { ... }
output "test_upload_command" { ... }
```

Après `terraform apply`, ces outputs donnent directement :
- L'IP du load balancer (point d'entrée de l'app)
- Les commandes SSH complètes pour accéder aux instances via le bastion
- La commande `curl` pour tester l'upload

---

## Build et push des images Docker

Les images sont buildées pour linux/amd64 (architecture des instances Scaleway) et poussées dans le registry privé :

```bash
docker buildx bake --push
```

La configuration de build (registry URL, tags, plateformes) est dans `docker-compose.yml` à la racine du projet, utilisé comme fichier de définition pour `buildx bake`.

---

## Commande finale

```bash
terraform init
terraform apply
```

Résultat : 22+ ressources créées, application accessible en HTTP sur l'IP publique du Load Balancer.

```bash
curl -F 'file=@logo.png' http://<lb-ip>/upload
# {"id":"...","url":"https://engineeringonboarding.s3.fr-par.scw.cloud/....jpeg"}
```

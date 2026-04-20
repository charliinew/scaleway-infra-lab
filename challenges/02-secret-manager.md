# Challenge 2 — Secret Manager

## Objectif

Remplacer les variables d'environnement sensibles (`DATABASE_URL`, `BUCKET_NAME`) passées directement au conteneur par une récupération dynamique depuis le **Scaleway Secret Manager** au démarrage de l'application.

**Avant** : les valeurs sensibles étaient injectées en clair dans le cloud-init et les env vars Docker.

**Après** : seuls `ACCESS_KEY`, `SECRET_KEY`, `PROJECT_ID` et `IMAGE_PROCESSOR_URL` sont passés en env var. Tout le reste est récupéré depuis Secret Manager à l'initialisation de l'app.

---

## Étape 1 — Créer les secrets avec Terraform

### secrets.tf

```hcl
resource "scaleway_secret" "database_url" {
  name = "onboarding-database-url"
}

resource "scaleway_secret_version" "database_url" {
  secret_id = scaleway_secret.database_url.id
  data      = "postgresql://${var.db_user}:${var.db_password}@${scaleway_rdb_instance.main.private_network[0].ip}:${scaleway_rdb_instance.main.private_network[0].port}/${var.db_name}"
}

resource "scaleway_secret" "bucket_name" {
  name = "onboarding-bucket-name"
}

resource "scaleway_secret_version" "bucket_name" {
  secret_id = scaleway_secret.bucket_name.id
  data      = var.bucket_name
}
```

**Points clés** :
- `scaleway_secret` : le conteneur (métadonnées, nom, région). Plusieurs versions peuvent coexister.
- `scaleway_secret_version` : la valeur réelle du secret. Scaleway versionne les secrets — on accède toujours à `latest`.
- La DB URL est construite dynamiquement depuis les outputs de `scaleway_rdb_instance` (IP et port privés IPAM).
- Le champ `data` attend une **chaîne brute** (pas de `base64encode()`). Le provider stocke la valeur telle quelle ; l'API REST ajoute son propre encodage base64 à la récupération.

### Erreur rencontrée : double encodage base64

**Symptôme** : après le premier `terraform apply`, la valeur récupérée depuis l'API était une chaîne base64 au lieu de la vraie valeur. En décodant une fois : on obtenait encore du base64. En décodant deux fois : on obtenait la vraie valeur.

**Cause** : le code initial utilisait `base64encode(...)` dans `secrets.tf`. Mais le provider Scaleway **ne décode pas** la valeur avant de la stocker — il la stocke telle quelle. Résultat : la chaîne `base64(valeur)` était stockée, puis l'API ajoutait son propre encodage base64 au moment de la récupération → double encodage.

**Diagnostic** :
```bash
# L'API retournait (une fois décodée) :
# cG9zdGdyZXNxbDovL29uYm9hcmRpbmc6...  ← encore du base64 !

# Deux décodages successifs donnaient :
# postgresql://onboarding:<db-password>@<db-private-ip>:5432/onboarding  ✓
```

**Fix** :
1. Supprimer `base64encode()` de `secrets.tf`
2. Créer manuellement une nouvelle version (revision 2) avec la valeur brute, car Terraform considère les `secret_version` comme **immutables** et ne détecte pas le changement de contenu :

```bash
scw secret version create \
  secret-id=<database-url-secret-id> \
  data="postgresql://onboarding:<db-password>@<db-private-ip>:5432/onboarding"

scw secret version create \
  secret-id=<bucket-name-secret-id> \
  data="<bucket-name>"
```

> **Leçon** : les ressources `scaleway_secret_version` sont immuables dans le provider Terraform. Toute mise à jour du contenu doit passer par la création d'une nouvelle version (via CLI ou en forçant `terraform taint`).

---

## Étape 2 — Modifier app.py pour récupérer les secrets

### Stratégie

La fonction `resolve()` implémente une logique de **fallback** :
1. Si la variable d'environnement est définie → on l'utilise directement (pratique pour le dev local)
2. Sinon → on appelle Secret Manager

Cela permet de conserver la compatibilité avec le mode de lancement local (`.env`).

### Code ajouté dans app.py

```python
def fetch_secret(secret_name: str, secret_key: str, project_id: str, region: str = "fr-par") -> str:
    """Fetch a secret version from Scaleway Secret Manager."""
    # Étape 1 : lister les secrets filtrés par nom pour obtenir l'ID
    list_url = (
        f"https://api.scaleway.com/secret-manager/v1beta1/regions/{region}"
        f"/secrets?project_id={project_id}&name={secret_name}"
    )
    req = urllib.request.Request(list_url, headers={"X-Auth-Token": secret_key})
    with urllib.request.urlopen(req) as response:
        data = json.loads(response.read())
    secrets = data.get("secrets", [])
    if not secrets:
        raise ValueError(f"Secret '{secret_name}' not found in project {project_id}")
    secret_id = secrets[0]["id"]

    # Étape 2 : accéder à la dernière version par ID
    access_url = (
        f"https://api.scaleway.com/secret-manager/v1beta1/regions/{region}"
        f"/secrets/{secret_id}/versions/latest/access"
    )
    req = urllib.request.Request(access_url, headers={"X-Auth-Token": secret_key})
    with urllib.request.urlopen(req) as response:
        data = json.loads(response.read())
        return base64.b64decode(data["data"]).decode()


def resolve(env_var: str, secret_name: str | None, secret_key: str, project_id: str) -> str | None:
    """Return env var value if set, otherwise fetch from Secret Manager."""
    value = os.getenv(env_var)
    if value:
        return value
    if not secret_name:
        return None
    try:
        value = fetch_secret(secret_name, secret_key, project_id)
        logger.info(f"Loaded {env_var} from Secret Manager ({secret_name})")
        return value
    except Exception as e:
        logger.warning(f"Could not fetch secret {secret_name}: {e}")
        return None
```

### Utilisation dans l'initialisation de l'app

```python
ACCESS_KEY = os.getenv("ONBOARDING_ACCESS_KEY")      # requis, pas dans SM
SECRET_KEY = os.getenv("ONBOARDING_SECRET_KEY")      # requis, sert à s'auth à SM
PROJECT_ID = os.getenv("ONBOARDING_PROJECT_ID", "")  # requis pour les requêtes SM

DATABASE_URL = resolve("ONBOARDING_DATABASE_URL", "onboarding-database-url", SECRET_KEY, PROJECT_ID)
BUCKET_NAME  = resolve("ONBOARDING_BUCKET_NAME",  "onboarding-bucket-name",  SECRET_KEY, PROJECT_ID)
```

### Erreur rencontrée : endpoint `secrets-by-name` retourne 404

**Symptôme** : la documentation Scaleway mentionne un endpoint `/secrets-by-name/{name}/versions/latest/access`. L'implémentation initiale utilisait cette URL mais recevait systématiquement HTTP 404.

**Diagnostic** :
```bash
# URL initiale (ne fonctionne pas) :
curl -H "X-Auth-Token: ..." \
  "https://api.scaleway.com/secret-manager/v1beta1/regions/fr-par/secrets-by-name/onboarding-database-url/versions/latest/access?project_id=..."
# → {"message":"Not Found"}

# URL alternative par ID (fonctionne) :
curl -H "X-Auth-Token: ..." \
  "https://api.scaleway.com/secret-manager/v1beta1/regions/fr-par/secrets/<uuid>/versions/latest/access"
# → {"secret_id":"...", "revision":1, "data":"<base64>", ...}
```

**Fix** : l'approche `secrets-by-name` n'est pas opérationnelle. On utilise un lookup en deux temps :
1. `GET /secrets?project_id=...&name=<nom>` → récupère la liste et extrait l'UUID
2. `GET /secrets/<uuid>/versions/latest/access` → récupère la valeur encodée en base64

### cloud-init — Suppression des env vars sensibles

Avant, le cloud-init injectait `DATABASE_URL` et `BUCKET_NAME` en clair :

```bash
# Avant (dangereux)
docker run ... \
  -e ONBOARDING_DATABASE_URL="postgresql://..." \
  -e ONBOARDING_BUCKET_NAME="engineeringonboarding" \
  ...
```

Après, seuls les credentials nécessaires à l'authentification Scaleway et à l'accès au Secret Manager sont passés :

```bash
# Après (dans cloud-init/rest-api.yaml.tpl)
docker run ... \
  -e ONBOARDING_IMAGE_PROCESSOR_URL="http://${image_processor_ip}:9090" \
  -e ONBOARDING_ACCESS_KEY="${access_key}" \
  -e ONBOARDING_SECRET_KEY="${secret_key}" \
  -e ONBOARDING_PROJECT_ID="${project_id}" \
  rg.fr-par.scw.cloud/${registry_namespace}/rest-api:latest
```

> **Note** : `ACCESS_KEY` et `SECRET_KEY` restent en env var car ils sont nécessaires pour s'authentifier à Secret Manager lui-même. C'est un compromis acceptable : ces credentials sont stockés dans Terraform state (déjà protégé) et dans le cloud-init (accessible uniquement via l'API Scaleway avec les mêmes credentials).

---

## Étape 3 — Rebuild et redéploiement

```bash
# Rebuild et push de l'image avec app.py modifié
docker buildx bake --push

# Redémarrage du conteneur sur l'instance
ssh -o ProxyCommand="ssh -W %h:%p bastion@<gateway-ip> -p 61000" root@<rest-api-ip> "
  docker pull rg.fr-par.scw.cloud/<namespace>/rest-api:latest
  docker container stop rest-api
  docker container remove rest-api
  docker run -d --restart unless-stopped -p 8080:8080 --name rest-api \
    -e ONBOARDING_IMAGE_PROCESSOR_URL='http://<ip-processor>:9090' \
    -e ONBOARDING_ACCESS_KEY='<access-key>' \
    -e ONBOARDING_SECRET_KEY='<secret-key>' \
    -e ONBOARDING_PROJECT_ID='<project-id>' \
    rg.fr-par.scw.cloud/<namespace>/rest-api:latest
"
```

---

## Validation

Logs du conteneur au démarrage :

```
INFO: Loaded ONBOARDING_DATABASE_URL from Secret Manager (onboarding-database-url)
INFO: Loaded ONBOARDING_BUCKET_NAME from Secret Manager (onboarding-bucket-name)
INFO: ONBOARDING_IMAGE_PROCESSOR_TOKEN environment variable is not set.
INFO: Started server process [1]
INFO: Application startup complete.
INFO: Uvicorn running on http://0.0.0.0:8080
```

Test end-to-end via le Load Balancer :

```bash
curl -F 'file=@logo.png' http://<lb-ip>/upload
# {"id":"eb50f91b-...","url":"https://engineeringonboarding.s3.fr-par.scw.cloud/97e5....jpeg"}
```

---

## Résumé des décisions

| Décision | Raison |
|----------|--------|
| Lookup en deux temps (list → access by ID) | L'endpoint `secrets-by-name` retourne 404 |
| Pas de `base64encode()` dans Terraform | Le provider stocke la valeur brute ; l'API encode elle-même en base64 à la récupération |
| Fallback env var → Secret Manager | Compatibilité avec le développement local via `.env` |
| `ACCESS_KEY` et `SECRET_KEY` restent en env var | Nécessaires pour s'authentifier à Secret Manager, ne peuvent pas eux-mêmes être dans SM |
| Versions créées via CLI (pas Terraform) | Les `scaleway_secret_version` sont immuables dans le provider ; on crée une nouvelle révision via `scw secret version create` |

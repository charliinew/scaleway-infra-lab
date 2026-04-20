#cloud-config

runcmd:
  - |
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
    until ip route | grep -q default; do sleep 5; done
    curl -fsSL https://get.docker.com | sh
    echo "${secret_key}" | docker login rg.fr-par.scw.cloud/${registry_namespace} -u nologin --password-stdin
    until docker pull rg.fr-par.scw.cloud/${registry_namespace}/rest-api:latest; do
      echo "Image not available yet, retrying in 30s..."
      sleep 30
    done
    docker run -d --restart unless-stopped -p 8080:8080 --name rest-api --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 -e ONBOARDING_IMAGE_PROCESSOR_URL="http://${image_processor_ip}:9090" -e ONBOARDING_ACCESS_KEY="${access_key}" -e ONBOARDING_SECRET_KEY="${secret_key}" -e ONBOARDING_PROJECT_ID="${project_id}" rg.fr-par.scw.cloud/${registry_namespace}/rest-api:latest

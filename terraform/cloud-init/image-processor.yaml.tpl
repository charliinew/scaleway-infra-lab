#cloud-config

runcmd:
  - |
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
    until ip route | grep -q default; do sleep 5; done
    curl -fsSL https://get.docker.com | sh
    echo "${secret_key}" | docker login rg.fr-par.scw.cloud/${registry_namespace} -u nologin --password-stdin
    until docker pull rg.fr-par.scw.cloud/${registry_namespace}/image-processor:latest; do
      echo "Image not available yet, retrying in 30s..."
      sleep 30
    done
    docker run -d --restart unless-stopped -p 9090:9090 --name image-processor --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 rg.fr-par.scw.cloud/${registry_namespace}/image-processor:latest

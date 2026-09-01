#!/usr/bin/env bash
# Limpia artefactos Docker auxiliares que MiniStack no incluye en Terraform.
set -euo pipefail

SERVICE_NETWORK="${LOCAL_SERVICE_NETWORK:-congenia-local-services}"
removed=0

for service in frontend api keycloak rabbitmq pdf-worker; do
  while IFS= read -r container_id; do
    [[ -z "$container_id" ]] && continue
    docker rm -f "$container_id" >/dev/null
    removed=$((removed + 1))
  done < <(docker ps -aq \
    --filter 'label=com.amazonaws.ecs.cluster' \
    --filter "label=com.amazonaws.ecs.container-name=${service}")
done

if docker network inspect "$SERVICE_NETWORK" >/dev/null 2>&1; then
  docker network rm "$SERVICE_NETWORK" >/dev/null
fi

echo "Limpieza local completa: ${removed} contenedor(es) residual(es) removido(s)."

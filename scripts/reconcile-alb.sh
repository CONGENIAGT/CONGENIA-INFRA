#!/usr/bin/env bash
# Reconcilia las diferencias conocidas entre ECS/ALB reales y MiniStack:
# registra targets del ALB y crea DNS Docker estable entre las tareas ECS.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TFDIR="${1:-envs/local}"
SERVICE_NETWORK="${LOCAL_SERVICE_NETWORK:-congenia-local-services}"

if [[ "$TFDIR" == *"/aws" || "$TFDIR" == "envs/aws" ]]; then
  echo "La reconciliacion de MiniStack solo aplica a envs/local." >&2
  exit 1
fi

# La red es propiedad de este entorno local. Recrearla evita conservar alias
# de tareas reemplazadas durante un nuevo apply.
if docker network inspect "$SERVICE_NETWORK" >/dev/null 2>&1; then
  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] && docker network disconnect -f "$SERVICE_NETWORK" "$container_id" >/dev/null
  done < <(docker network inspect "$SERVICE_NETWORK" \
    --format '{{range $id, $_ := .Containers}}{{println $id}}{{end}}')
  docker network rm "$SERVICE_NETWORK" >/dev/null
fi
docker network create --label congenia.local=true "$SERVICE_NETWORK" >/dev/null

# Registrar targets antes de agregar la red auxiliar garantiza que se use la
# IP de la red compartida con MiniStack, que es desde donde el ALB hace proxy.
python3 "$HERE/reconcile_alb.py" "$TFDIR"

for service in frontend api keycloak rabbitmq pdf-worker; do
  container_id=$(docker ps -aq \
    --filter "label=com.amazonaws.ecs.container-name=${service}" | sed -n '1p')
  if [[ -z "$container_id" ]]; then
    echo "No se encontro la tarea local de ${service}." >&2
    exit 1
  fi
  docker network connect --alias "$service" "$SERVICE_NETWORK" "$container_id"
done

# El worker falla rapido si RabbitMQ aun no era alcanzable durante su primer
# arranque. Ya conectado al DNS estable, se recupera sin recrear la tarea.
worker_id=$(docker ps -aq \
  --filter 'label=com.amazonaws.ecs.container-name=pdf-worker' | sed -n '1p')
if [[ "$(docker inspect "$worker_id" --format '{{.State.Running}}')" != "true" ]]; then
  docker start "$worker_id" >/dev/null
fi

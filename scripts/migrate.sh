#!/usr/bin/env bash
# =============================================================================
# Ejecuta la tarea de migracion del esquema y espera a que termine.
#
# Terraform declara la task definition (modules/migrate) pero no la corre:
# no existe un recurso nativo para "ejecutar esto una vez". Este script es ese
# paso imperativo, explicito y fuera del estado.
#
# Es idempotente: el entrypoint de la imagen se salta la carga si las tablas
# ya existen.
# =============================================================================
set -euo pipefail

TFDIR="${1:-envs/aws}"

for binario in aws terraform; do
  command -v "$binario" >/dev/null || { echo "Falta $binario en el PATH" >&2; exit 1; }
done

salida() { (cd "$TFDIR" && terraform output -raw "$1"); }

region=$(salida region)
cluster=$(salida ecs_cluster)
taskdef=$(salida migrate_task_definition)
netcfg=$(salida migrate_network_config)
grupo=$(salida migrate_log_group)

echo "Migracion del esquema CONGENIA"
echo "  cluster    ${cluster}"
echo "  definicion ${taskdef##*/}"

arn=$(aws ecs run-task \
  --region "$region" \
  --cluster "$cluster" \
  --task-definition "$taskdef" \
  --launch-type FARGATE \
  --network-configuration "$netcfg" \
  --started-by "make-migrate" \
  --query 'tasks[0].taskArn' --output text)

if [[ -z "$arn" || "$arn" == "None" ]]; then
  echo "La tarea no arranco. Revisa cuota de Fargate y subredes." >&2
  exit 1
fi

echo "  tarea      ${arn##*/}"
echo "Esperando a que termine..."
aws ecs wait tasks-stopped --region "$region" --cluster "$cluster" --tasks "$arn"

codigo=$(aws ecs describe-tasks --region "$region" --cluster "$cluster" --tasks "$arn" \
  --query 'tasks[0].containers[0].exitCode' --output text)
motivo=$(aws ecs describe-tasks --region "$region" --cluster "$cluster" --tasks "$arn" \
  --query 'tasks[0].stoppedReason' --output text)

echo "--- salida de la tarea ---"
aws logs get-log-events \
  --region "$region" \
  --log-group-name "$grupo" \
  --log-stream-name "ecs/migrate/${arn##*/}" \
  --query 'events[].message' --output text 2>/dev/null \
  | tr '\t' '\n' || echo "(sin logs todavia; CloudWatch puede tardar unos segundos)"
echo "--------------------------"

if [[ "$codigo" != "0" ]]; then
  echo "FALLA: la tarea termino con codigo ${codigo} (${motivo})" >&2
  exit 1
fi

echo "Esquema cargado."

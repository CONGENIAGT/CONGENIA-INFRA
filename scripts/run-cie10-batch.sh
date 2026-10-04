#!/usr/bin/env bash
# =============================================================================
# Ejecuta a demanda el batch CIE-10 declarado por Terraform.
#
# EventBridge Scheduler lo corre automaticamente al final de mes. Este helper
# existe para probar el mismo task definition antes del calendario mensual:
# lee snapshots CSV desde S3, genera sugerencias y deja la cola lista para
# revisarse en /dashboard/cie10.
# =============================================================================
set -euo pipefail

TFDIR="${1:-envs/aws}"

for binario in aws terraform; do
  command -v "$binario" >/dev/null || { echo "Falta $binario en el PATH" >&2; exit 1; }
done

salida() { (cd "$TFDIR" && terraform output -raw "$1"); }

region=$(salida region)
cluster=$(salida ecs_cluster)
taskdef=$(salida cie10_task_definition)
netcfg=$(salida migrate_network_config)
grupo=$(salida cie10_log_group)

echo "Batch CIE-10 CONGENIA"
echo "  cluster    ${cluster}"
echo "  definicion ${taskdef##*/}"

arn=$(aws ecs run-task \
  --region "$region" \
  --cluster "$cluster" \
  --task-definition "$taskdef" \
  --launch-type FARGATE \
  --network-configuration "$netcfg" \
  --started-by "make-cie10-batch" \
  --query 'tasks[0].taskArn' --output text)

if [[ -z "$arn" || "$arn" == "None" ]]; then
  echo "La tarea CIE-10 no arranco. Revisa imagen, secreto OpenAI, subredes y cuota de Fargate." >&2
  exit 1
fi

echo "  tarea      ${arn##*/}"
echo "Esperando a que termine..."
aws ecs wait tasks-stopped --region "$region" --cluster "$cluster" --tasks "$arn"

codigo=$(aws ecs describe-tasks --region "$region" --cluster "$cluster" --tasks "$arn" \
  --query 'tasks[0].containers[0].exitCode' --output text)
motivo=$(aws ecs describe-tasks --region "$region" --cluster "$cluster" --tasks "$arn" \
  --query 'tasks[0].stoppedReason' --output text)

echo "--- salida de la tarea CIE-10 ---"
aws logs get-log-events \
  --region "$region" \
  --log-group-name "$grupo" \
  --log-stream-name "ecs/cie10/${arn##*/}" \
  --query 'events[].message' --output text 2>/dev/null \
  | tr '\t' '\n' || echo "(sin logs todavia; CloudWatch puede tardar unos segundos)"
echo "---------------------------------"

if [[ "$codigo" != "0" ]]; then
  echo "FALLA: la tarea CIE-10 termino con codigo ${codigo} (${motivo})" >&2
  exit 1
fi

echo "Batch CIE-10 completado. Las sugerencias generadas se revisan en /dashboard/cie10."

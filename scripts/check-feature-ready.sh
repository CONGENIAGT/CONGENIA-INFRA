#!/usr/bin/env bash
# Solo consulta metadatos: nunca imprime valores de Secrets Manager ni CSV.
set -euo pipefail
export AWS_PAGER=""
TFDIR="${1:-envs/aws}"
FEATURE="${2:?Indica reporting o cie10}"
REGION=$(terraform -chdir="$TFDIR" output -raw region)
secret_ready() {
  local arn versions
  arn=$(terraform -chdir="$TFDIR" output -raw "$1")
  versions=$(aws secretsmanager list-secret-version-ids --region "$REGION" --secret-id "$arn" \
    --query 'Versions[?contains(VersionStages, `AWSCURRENT`)].VersionId' --output json)
  jq -e 'length > 0' <<<"$versions" >/dev/null || {
    echo "Falta cargar el valor de $1 en Secrets Manager." >&2
    return 1
  }
  echo "OK: $1 tiene una version AWSCURRENT"
}
case "$FEATURE" in
  reporting)
    for output in reporting_database_app_url_secret_arn reporting_database_agent_readonly_url_secret_arn reporting_llm_api_key_secret_arn reporting_mcp_token_secret_arn; do
      secret_ready "$output"
    done
    echo "Secretos presentes. Validar conexion, permisos readonly y dataset antes de habilitar reporteria."
    ;;
  cie10)
    secret_ready cie10_openai_secret_arn
    while IFS= read -r uri; do
      [[ "$uri" == s3://*/* ]] || { echo "URI S3 invalida" >&2; exit 1; }
      path=${uri#s3://}
      aws s3api head-object --region "$REGION" --bucket "${path%%/*}" --key "${path#*/}" \
        --query '{size:ContentLength}' --output json
    done < <(terraform -chdir="$TFDIR" output -json cie10_input_uris | jq -r '.[]')
    taskdef=$(terraform -chdir="$TFDIR" output -raw cie10_task_definition)
    image=$(aws ecs describe-task-definition --region "$REGION" --task-definition "$taskdef" \
      --query 'taskDefinition.containerDefinitions[0].image' --output text)
    reference=${image#*/}
    aws ecr describe-images --region "$REGION" --repository-name "${reference%:*}" \
      --image-ids "imageTag=${reference##*:}" --query 'imageDetails[].imageTags' --output json
    ;;
  *) echo "Funcion desconocida: $FEATURE" >&2; exit 1 ;;
esac

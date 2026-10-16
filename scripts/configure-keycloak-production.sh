#!/usr/bin/env bash
set -euo pipefail

readonly aws_profile="${CONGENIA_AWS_PROFILE:-congenia-login}"
readonly aws_region="${CONGENIA_AWS_REGION:-us-east-1}"
readonly expected_account="${EXPECTED_AWS_ACCOUNT:-940213460779}"
readonly keycloak_base_url="${KEYCLOAK_BASE_URL:-https://cogenia.app}"
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for command in aws curl jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "FALTA: '$command' debe estar disponible en PATH." >&2
    exit 1
  fi
done

if ! account="$(aws sts get-caller-identity \
  --profile "$aws_profile" \
  --region "$aws_region" \
  --query Account \
  --output text 2>/dev/null | tr -d '\r')"; then
  echo "FALLO: la sesion AWS del perfil '$aws_profile' no es valida." >&2
  echo "Ejecuta: aws login --profile $aws_profile" >&2
  exit 1
fi

if [[ "$account" != "$expected_account" ]]; then
  echo "FALLO: cuenta AWS actual '$account'; se esperaba '$expected_account'." >&2
  exit 1
fi

secret_value() {
  aws secretsmanager get-secret-value \
    --profile "$aws_profile" \
    --region "$aws_region" \
    --secret-id "$1" \
    --query SecretString \
    --output text | tr -d '\r'
}

export KEYCLOAK_BASE_URL="$keycloak_base_url"
export KEYCLOAK_ADMIN_PASSWORD="$(secret_value 'congenia/prod/keycloak-admin')"
export KEYCLOAK_MEDICO_PASSWORD="$(secret_value 'congenia/prod/keycloak-medico-initial')"
export KEYCLOAK_MEDICO_TENANTS="${KEYCLOAK_MEDICO_TENANTS:-23,254}"
export KEYCLOAK_SUPERADMIN_USERNAME="${KEYCLOAK_SUPERADMIN_USERNAME:-admin-doctor}"
export KEYCLOAK_SADC_TENANT="${KEYCLOAK_SADC_TENANT:-254}"

cleanup() {
  unset KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_MEDICO_PASSWORD
}
trap cleanup EXIT INT TERM

echo "Configurando Keycloak en ${KEYCLOAK_BASE_URL} (AWS ${account}, perfil ${aws_profile})..."
"${script_dir}/configure-keycloak-web.sh"

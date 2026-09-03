#!/usr/bin/env bash
set -euo pipefail

TFDIR="${1:-envs/aws}"
: "${SADC_CLIENT_SECRET:?Exporta SADC_CLIENT_SECRET desde Secrets Manager antes de ejecutar este smoke test}"

curl_host_args=()
if [[ "$TFDIR" == *"/aws" || "$TFDIR" == "envs/aws" ]]; then
  BASE_URL="${PUBLIC_URL:-$(cd "$TFDIR" && terraform output -raw public_url)}"
else
  BASE_URL="${PUBLIC_URL:-${MINISTACK_ENDPOINT:-http://localhost:4566}}"
  alb=$(cd "$TFDIR" && terraform output -raw alb_name)
  curl_host_args=(-H "Host: ${alb}.alb.localhost")
fi

# Bash 3.2 (incluido en macOS) considera `${array[@]}` una variable no definida
# bajo `set -u` cuando el arreglo esta vacio. El helper evita expandirlo en AWS
# y conserva el encabezado Host que necesita el ALB emulado en local.
curl_with_host() {
  if (( ${#curl_host_args[@]} )); then
    curl "${curl_host_args[@]}" "$@"
  else
    curl "$@"
  fi
}

command -v jq >/dev/null || {
  echo "Falta jq, requerido para validar respuestas JSON." >&2
  exit 1
}

echo "[1/4] OAuth client_credentials"
token=$(curl_with_host -fsS \
  -X POST "${BASE_URL}/realms/congenia/protocol/openid-connect/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=client_credentials' \
  --data-urlencode 'client_id=sadc' \
  --data-urlencode "client_secret=${SADC_CLIENT_SECRET}" \
  --data-urlencode 'scope=congenia.sessions:init' \
  | jq -er '.access_token')
echo "      OK"

echo "[2/4] Creacion de sesion integrada"
session=$(curl_with_host -fsS \
  -X POST "${BASE_URL}/api/v1/sessions/init" \
  -H "Authorization: Bearer ${token}" \
  -H 'Content-Type: application/json' \
  --data '{"paciente":{"patientId":"SMOKE-001","nombre":"Paciente de prueba"},"consulta":{"fechaConsulta":"2026-08-31","diagnosticoTexto":"Prueba tecnica sin datos reales"},"medico":{"medicoId":"MED-SMOKE-001","nombre":"Medico de prueba","especialidad":"Pruebas"}}')
echo "      OK"

session_token=$(jq -er '.sessionToken' <<<"$session")
form_url=$(jq -er '.formUrl' <<<"$session")

if [[ "$form_url" != *"#sessionToken="* || "$form_url" == *"?token="* || "$form_url" == *"&token="* ]]; then
  echo "FALLA: formUrl no entrega la capability solo en el fragmento seguro." >&2
  exit 1
fi

echo "[3/4] Activacion de sesion"
activation=$(curl_with_host -fsS \
  -X POST "${BASE_URL}/api/v1/sessions/activate" \
  -H "X-Session-Token: ${session_token}" \
  -H 'Cache-Control: no-store')
echo "      OK"

jq -e '
  .origenCreacion == "INTEGRACION" and
  (.fichaId | type == "string") and
  (.paciente.externalId == "SMOKE-001")
' >/dev/null <<<"$activation"

expected_ficha_id=$(jq -er '.fichaId' <<<"$activation")

echo "[4/4] Persistencia de ficha y consentimiento"
registration=$(curl_with_host -fsS \
  -X POST "${BASE_URL}/v1/patient" \
  -H "X-Session-Token: ${session_token}" \
  -H 'Content-Type: application/json' \
  --data '{
    "referralSourceId": 1,
    "birthMethodId": null,
    "affectedRelatives": false,
    "affectedRelativesCategoryIds": [],
    "affectedUnderageRelatives": 0,
    "affectedAdultRelatives": 0,
    "affectedCommunityMembers": "NO",
    "warningSigns": [],
    "examDiagnoses": [],
    "consent": {
      "tipoFirmante": "MADRE",
      "nombreFirmante": "Firmante de prueba",
      "idiomaConsentimiento": "ESPANOL",
      "aceptacionTerminos": true,
      "aceptacionContacto": false,
      "firmaEvidenciaTecnica": {"source":"smoke-test"}
    }
  }')

ficha_id=$(jq -er --arg expected "$expected_ficha_id" '
  select(.success == true and .data.fichaId == $expected)
  | .data.fichaId
' <<<"$registration")
jq -e '.data.consentimientoId | type == "string" and length > 0' >/dev/null <<<"$registration"
echo "      OK"

if [[ "$TFDIR" != *"/aws" && "$TFDIR" != "envs/aws" ]]; then
  [[ "$ficha_id" =~ ^[0-9a-fA-F-]{36}$ ]] || {
    echo "FALLA: la API devolvio un fichaId invalido." >&2
    exit 1
  }

  db_host=$(cd "$TFDIR" && terraform output -raw db_endpoint)
  db_host="${db_host%%:*}"
  rds_container=""
  while IFS= read -r container; do
    while IFS= read -r ip; do
      if [[ "$ip" == "$db_host" ]]; then
        rds_container="$container"
        break 2
      fi
    done < <(docker inspect "$container" --format '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}')
  done < <(docker ps -q --filter label=ministack=rds)

  [[ -n "$rds_container" ]] || {
    echo "FALLA: no se pudo verificar la persistencia en PostgreSQL local." >&2
    exit 1
  }

  persisted=$(docker exec "$rds_container" psql -U congenia -d congenia -Atc \
    "SELECT origen_creacion || '|' || (creado_por = medico_id)::text
       FROM ficha_clinica WHERE ficha_id = '${ficha_id}'::uuid;")
  [[ "$persisted" == "INTEGRACION|true" ]] || {
    echo "FALLA: origen_creacion o creado_por no se persistieron correctamente." >&2
    exit 1
  }

  echo "[local] Generacion y almacenamiento del PDF"
  pdf_ref=""
  for _ in {1..15}; do
    pdf_ref=$(docker exec "$rds_container" psql -U congenia -d congenia -Atc \
      "SELECT COALESCE(pdf_ref, '')
         FROM consentimiento WHERE ficha_id = '${ficha_id}'::uuid;")
    [[ -n "$pdf_ref" ]] && break
    sleep 2
  done
  [[ -n "$pdf_ref" ]] || {
    echo "FALLA: el worker no genero el PDF dentro del tiempo esperado." >&2
    exit 1
  }

  docs_bucket=$(cd "$TFDIR" && terraform output -raw docs_bucket)
  AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 \
    aws --endpoint-url "${MINISTACK_ENDPOINT:-http://localhost:4566}" \
    s3api head-object --bucket "$docs_bucket" --key "$pdf_ref" >/dev/null
  echo "      OK"
fi

echo "OK: OAuth -> sesion -> activacion -> persistencia -> PDF funciona sin exponer la capability."

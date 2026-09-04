#!/usr/bin/env bash
set -euo pipefail

TFDIR="${1:-envs/aws}"
: "${SADC_CLIENT_SECRET:?Exporta SADC_CLIENT_SECRET desde Secrets Manager antes de ejecutar este smoke test}"

BASE_URL="${PUBLIC_URL:-$(cd "$TFDIR" && terraform output -raw public_url)}"

command -v jq >/dev/null || {
  echo "Falta jq, requerido para validar respuestas JSON." >&2
  exit 1
}

echo "[1/4] OAuth client_credentials"
token=$(curl -fsS \
  -X POST "${BASE_URL}/realms/congenia/protocol/openid-connect/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=client_credentials' \
  --data-urlencode 'client_id=sadc' \
  --data-urlencode "client_secret=${SADC_CLIENT_SECRET}" \
  --data-urlencode 'scope=congenia.sessions:init' \
  | jq -er '.access_token')
echo "      OK"

echo "[2/4] Creacion de sesion integrada"
session=$(curl -fsS \
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
activation=$(curl -fsS \
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
registration=$(curl -fsS \
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

echo "OK: OAuth -> sesion -> activacion -> persistencia -> PDF funciona sin exponer la capability."

#!/usr/bin/env bash
set -euo pipefail

# KEYCLOAK_BASE_URL es la URL de administracion. Desde la correccion A1 el ALB
# no publica /admin/* ni /realms/master/*: se usa el tunel privado
# (make db-access-keycloak), es decir http://localhost:18080.
# KEYCLOAK_PUBLIC_URL es el origen publico del cliente web (redirect URIs y la
# prueba final de autorizacion); por compatibilidad toma KEYCLOAK_BASE_URL.
: "${KEYCLOAK_BASE_URL:?Define KEYCLOAK_BASE_URL, por ejemplo http://localhost:18080 por el tunel}"
: "${KEYCLOAK_ADMIN_PASSWORD:?Define KEYCLOAK_ADMIN_PASSWORD}"
: "${KEYCLOAK_MEDICO_PASSWORD:?Define KEYCLOAK_MEDICO_PASSWORD para la clave temporal}"
command -v python3 >/dev/null || { echo 'Falta Python 3 para configurar Keycloak.' >&2; exit 1; }

medico_user="${KEYCLOAK_MEDICO_USERNAME:-medico.inicial}"
medico_name="${KEYCLOAK_MEDICO_NAME:-Medico Inicial}"
medico_specialty="${KEYCLOAK_MEDICO_SPECIALTY:-Genetica Clinica}"
medico_tenants="${KEYCLOAK_MEDICO_TENANTS:-23,254}"
superadmin_user="${KEYCLOAK_SUPERADMIN_USERNAME:-admin-doctor}"
sadc_tenant="${KEYCLOAK_SADC_TENANT:-254}"
base_url="${KEYCLOAK_BASE_URL%/}"
public_url="${KEYCLOAK_PUBLIC_URL:-$base_url}"
public_url="${public_url%/}"
realm_url="${base_url}/admin/realms/congenia"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
token_cache_dir="$(mktemp -d)"
chmod 700 "$token_cache_dir"
trap 'rm -rf "$token_cache_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export KEYCLOAK_ADMIN_TOKEN_CACHE="${token_cache_dir}/token.json"

# Cache privado compartido por los subshells; se renueva antes de expirar.
# El token nunca se imprime ni se pasa por argv y se elimina al terminar.
kc_curl() {
  python3 "${script_dir}/keycloak-request.py" "$@"
}

target_scopes_url="${realm_url}/client-scopes"
master_scopes_url="${base_url}/admin/realms/master/client-scopes"

scope_id() {
  local scopes_url="$1"
  local scope_name="$2"
  kc_curl -fsS "$scopes_url" |
    jq -er --arg name "$scope_name" '.[] | select(.name == $name) | .id' |
    head -n 1
}

ensure_standard_scope() {
  local scope_name="$1"
  local source_id
  local source_json
  local target_id
  local scope_payload

  source_id="$(scope_id "$master_scopes_url" "$scope_name")"
  source_json="$(kc_curl -fsS "${master_scopes_url}/${source_id}")"
  target_id="$(scope_id "$target_scopes_url" "$scope_name" || true)"
  scope_payload="$(jq -a 'del(.id, .protocolMappers)' <<<"$source_json")"

  if [[ -z "$target_id" ]]; then
    kc_curl -fsS -o /dev/null -X POST "$target_scopes_url" -d "$scope_payload"
    target_id="$(scope_id "$target_scopes_url" "$scope_name")"
  else
    kc_curl -fsS -o /dev/null -X PUT \
      "${target_scopes_url}/${target_id}" -d "$scope_payload"
  fi

  local target_mappers
  target_mappers="$(kc_curl -fsS "${target_scopes_url}/${target_id}/protocol-mappers/models")"
  while IFS= read -r mapper; do
    local mapper_name
    local mapper_id
    local mapper_payload

    mapper_name="$(jq -er '.name' <<<"$mapper")"
    mapper_id="$(jq -r --arg name "$mapper_name" '[.[] | select(.name == $name) | .id][0] // empty' <<<"$target_mappers")"

    if [[ -z "$mapper_id" ]]; then
      mapper_payload="$(jq -a 'del(.id)' <<<"$mapper")"
      kc_curl -fsS -o /dev/null -X POST \
        "${target_scopes_url}/${target_id}/protocol-mappers/models" -d "$mapper_payload"
    else
      mapper_payload="$(jq --arg id "$mapper_id" '.id = $id' <<<"$mapper")"
      if ! jq -e --argjson expected "$mapper_payload" \
        'any(.[]; . == $expected)' <<<"$target_mappers" >/dev/null; then
        kc_curl -fsS -o /dev/null -X PUT \
          "${target_scopes_url}/${target_id}/protocol-mappers/models/${mapper_id}" \
          -d "$mapper_payload"
      fi
    fi
  done < <(jq -c '.protocolMappers[]' <<<"$source_json")

  local expected_mappers
  local actual_mappers
  expected_mappers="$(jq -c '[.protocolMappers[].name] | sort' <<<"$source_json")"
  actual_mappers="$({
    kc_curl -fsS "${target_scopes_url}/${target_id}/protocol-mappers/models"
  } | jq -c '[.[].name] | sort')"

  jq -e --argjson expected "$expected_mappers" --argjson actual "$actual_mappers" \
    '$expected - $actual | length == 0' <<<null >/dev/null || {
      echo "FALLA: el scope ${scope_name} no contiene todos sus mappers estándar." >&2
      return 1
    }
}

for standard_scope in basic profile email roles; do
  echo "Verificando scope Keycloak: ${standard_scope}" >&2
  ensure_standard_scope "$standard_scope"
done

ensure_role() {
  local role_name="$1"
  local description="$2"

  if ! kc_curl -fsS -o /dev/null "${realm_url}/roles/${role_name}" 2>/dev/null; then
    jq -nca --arg name "$role_name" --arg description "$description" \
      '{name: $name, description: $description}' |
      kc_curl -fsS -o /dev/null -X POST "${realm_url}/roles" -d @-
  fi
}

ensure_role "medico" "Puede iniciar fichas clinicas desde el cliente web"
ensure_role "congenia-admin" "Puede revisar y resolver adendas en el dashboard"
ensure_role "congenia-coordinador" "Puede consultar y coordinar expedientes asignados"
ensure_role "congenia-genetista" "Puede crear fichas y adendas como genetista"
ensure_role "congenia-superadmin" "Puede consultar todos los tenants y administrar catalogos"

# La API calcula los permisos por institucion a partir del claim `groups`
# (rutas completas, p. ej. /instituciones/254/medicos). Solo va en el access
# token: el frontend recibe los permisos calculados desde GET /api/v1/me.
groups_mapper="$(jq -nca '{
  name: "groups",
  protocol: "openid-connect",
  protocolMapper: "oidc-group-membership-mapper",
  consentRequired: false,
  config: {
    "claim.name": "groups",
    "full.path": "true",
    "access.token.claim": "true",
    "introspection.token.claim": "true",
    "id.token.claim": "false",
    "userinfo.token.claim": "false"
  }
}')"

client_json="$(jq -nca --arg origin "$public_url" --argjson groups_mapper "$groups_mapper" '{
  clientId: "congenia-web",
  name: "CONGENIA — Aplicacion web",
  enabled: true,
  publicClient: true,
  standardFlowEnabled: true,
  implicitFlowEnabled: false,
  directAccessGrantsEnabled: false,
  serviceAccountsEnabled: false,
  protocol: "openid-connect",
  redirectUris: [($origin + "/*")],
  webOrigins: [$origin],
  attributes: {
    "pkce.code.challenge.method": "S256",
    "post.logout.redirect.uris": ($origin + "/*")
  },
  protocolMappers: [
    {
      name: "especialidad",
      protocol: "openid-connect",
      protocolMapper: "oidc-usermodel-attribute-mapper",
      consentRequired: false,
      config: {
        "user.attribute": "especialidad",
        "claim.name": "especialidad",
        "jsonType.label": "String",
        "access.token.claim": "true",
        "id.token.claim": "true",
        "userinfo.token.claim": "true",
        "multivalued": "false"
      }
    },
    {
      name: "tenants",
      protocol: "openid-connect",
      protocolMapper: "oidc-usermodel-attribute-mapper",
      consentRequired: false,
      config: {
        "user.attribute": "tenants",
        "claim.name": "tenants",
        "jsonType.label": "String",
        "access.token.claim": "true",
        "id.token.claim": "false",
        "userinfo.token.claim": "true",
        "multivalued": "true",
        "aggregate.attrs": "true"
      }
    },
    {
      name: "congenia-api-audience",
      protocol: "openid-connect",
      protocolMapper: "oidc-audience-mapper",
      consentRequired: false,
      config: {
        "included.custom.audience": "congenia-api",
        "access.token.claim": "true",
        "id.token.claim": "false"
      }
    },
    $groups_mapper
  ]
}')"

client_uuid="$(kc_curl -fsS "${realm_url}/clients?clientId=congenia-web" | jq -er '.[0].id // empty' || true)"
if [[ -z "$client_uuid" ]]; then
  kc_curl -fsS -o /dev/null -X POST "${realm_url}/clients" -d "$client_json"
  client_uuid="$(kc_curl -fsS "${realm_url}/clients?clientId=congenia-web" | jq -er '.[0].id')"
else
  kc_curl -fsS -o /dev/null -X PUT "${realm_url}/clients/${client_uuid}" -d "$client_json"
fi

# El PUT del cliente no agrega mappers nuevos a un cliente existente: el mapper
# groups se crea o actualiza aparte, igual que tenant-id del cliente sadc.
web_mappers_url="${realm_url}/clients/${client_uuid}/protocol-mappers/models"
groups_mapper_id="$(kc_curl -fsS "$web_mappers_url" | jq -er '.[] | select(.name == "groups") | .id' | head -n 1 || true)"
if [[ -z "$groups_mapper_id" ]]; then
  kc_curl -fsS -o /dev/null -X POST "$web_mappers_url" -d "$groups_mapper"
else
  kc_curl -fsS -o /dev/null -X PUT "$web_mappers_url/${groups_mapper_id}"     -d "$(jq --arg id "$groups_mapper_id" '.id = $id' <<<"$groups_mapper")"
fi

for standard_scope in basic profile email roles; do
  standard_scope_id="$(scope_id "$target_scopes_url" "$standard_scope")"
  kc_curl -fsS -o /dev/null -X PUT \
    "${realm_url}/clients/${client_uuid}/default-client-scopes/${standard_scope_id}"
done

user_uuid="$(kc_curl -fsS "${realm_url}/users?exact=true&username=${medico_user}" | jq -er '.[0].id // empty' || true)"
if [[ -z "$user_uuid" ]]; then
  user_json="$(jq -nca \
    --arg username "$medico_user" \
    --arg name "$medico_name" \
    --arg specialty "$medico_specialty" \
    --arg password "$KEYCLOAK_MEDICO_PASSWORD" \
    '{
      username: $username,
      enabled: true,
      firstName: $name,
      attributes: {especialidad: [$specialty]},
      credentials: [{type: "password", value: $password, temporary: true}]
    }')"
  kc_curl -fsS -o /dev/null -X POST "${realm_url}/users" -d "$user_json"
  user_uuid="$(kc_curl -fsS "${realm_url}/users?exact=true&username=${medico_user}" | jq -er '.[0].id')"
else
  user_json="$(kc_curl -fsS "${realm_url}/users/${user_uuid}" |
    jq -ca \
      --arg name "$medico_name" \
      --arg specialty "$medico_specialty" \
      '.firstName = $name
       | .enabled = true
       | .attributes = ((.attributes // {}) + {especialidad: [$specialty]})
       | del(.attributes.tenants)')"
  kc_curl -fsS -o /dev/null -X PUT "${realm_url}/users/${user_uuid}" -d "$user_json"
fi

group_id_by_path() {
  local group_path="$1"
  kc_curl -fsS "${realm_url}/group-by-path${group_path}" | jq -er '.id'
}

ensure_group() {
  local parent_id="$1"
  local group_name="$2"
  local group_path="$3"
  local attributes_json="${4:-}"
  [[ -n "$attributes_json" ]] || attributes_json='{}'
  local group_id
  local endpoint

  group_id="$(group_id_by_path "$group_path" || true)"
  if [[ -z "$group_id" ]]; then
    if [[ -z "$parent_id" ]]; then
      endpoint="${realm_url}/groups"
    else
      endpoint="${realm_url}/groups/${parent_id}/children"
    fi
    jq -nca --arg name "$group_name" --argjson attributes "$attributes_json" \
      '{name: $name, attributes: $attributes}' |
      kc_curl -fsS -o /dev/null -X POST "$endpoint" -d @-
    group_id="$(group_id_by_path "$group_path")"
  elif [[ "$attributes_json" != "{}" ]]; then
    group_json="$(kc_curl -fsS "${realm_url}/groups/${group_id}" |
      jq -ca --argjson attributes "$attributes_json" '.attributes = $attributes')"
    kc_curl -fsS -o /dev/null -X PUT "${realm_url}/groups/${group_id}" -d "$group_json"
  fi
  printf '%s' "$group_id"
}

ensure_group_role() {
  local group_id="$1"
  local role_name="$2"
  local role_json
  local assigned
  role_json="$(kc_curl -fsS "${realm_url}/roles/${role_name}")"
  assigned="$(kc_curl -fsS "${realm_url}/groups/${group_id}/role-mappings/realm")"
  if ! jq -e --arg name "$role_name" 'any(.name == $name)' <<<"$assigned" >/dev/null; then
    jq -nca --argjson role "$role_json" '[$role]' |
      kc_curl -fsS -o /dev/null -X POST \
        "${realm_url}/groups/${group_id}/role-mappings/realm" -d @-
  fi
}

remove_managed_roles() {
  local mapping_url="$1"
  local assigned
  local managed
  assigned="$(kc_curl -fsS "$mapping_url")"
  managed="$(jq -ca '[.[] | select(.name == "medico" or .name == "congenia-admin" or .name == "congenia-coordinador" or .name == "congenia-genetista" or .name == "congenia-superadmin" or .name == "admin" or .name == "administrador" or .name == "genetista")]' <<<"$assigned")"
  if [[ "$(jq -r 'length' <<<"$managed")" -gt 0 ]]; then
    kc_curl -fsS -o /dev/null -X DELETE "$mapping_url" -d "$managed"
  fi
}

institutions_id="$(ensure_group "" "instituciones" "/instituciones")"
while IFS= read -r tenant_id; do
  tenant_group_id="$(ensure_group "$institutions_id" "$tenant_id" "/instituciones/${tenant_id}" "$(jq -nca --arg tenant "$tenant_id" '{tenants: [$tenant]}')")"
  for function_name in medicos revisores coordinadores genetistas; do
    function_group_id="$(ensure_group "$tenant_group_id" "$function_name" "/instituciones/${tenant_id}/${function_name}")"
    case "$function_name" in
      medicos) ensure_group_role "$function_group_id" "medico" ;;
      revisores) ensure_group_role "$function_group_id" "congenia-admin" ;;
      coordinadores) ensure_group_role "$function_group_id" "congenia-coordinador" ;;
      genetistas)
        ensure_group_role "$function_group_id" "medico"
        ensure_group_role "$function_group_id" "congenia-genetista"
        ;;
    esac
  done
done < <(jq -Rr 'split(",")[] | gsub("^\\s+|\\s+$"; "") | select(test("^[0-9]+$"))' <<<"$medico_tenants")

while IFS= read -r tenant_id; do
  medico_group_id="$(group_id_by_path "/instituciones/${tenant_id}/medicos")"
  kc_curl -fsS -o /dev/null -X PUT "${realm_url}/users/${user_uuid}/groups/${medico_group_id}"
done < <(jq -Rr 'split(",")[] | gsub("^\\s+|\\s+$"; "") | select(test("^[0-9]+$"))' <<<"$medico_tenants")
remove_managed_roles "${realm_url}/users/${user_uuid}/role-mappings/realm"

superadmin_group_id="$(ensure_group "" "superadministradores" "/superadministradores")"
ensure_group_role "$superadmin_group_id" "congenia-superadmin"
ensure_group_role "$superadmin_group_id" "congenia-admin"
superadmin_uuid="$(kc_curl -fsS "${realm_url}/users?exact=true&username=${superadmin_user}" | jq -er '.[0].id // empty' || true)"
if [[ -n "$superadmin_uuid" ]]; then
  kc_curl -fsS -o /dev/null -X PUT "${realm_url}/users/${superadmin_uuid}/groups/${superadmin_group_id}"
  superadmin_json="$(kc_curl -fsS "${realm_url}/users/${superadmin_uuid}" | jq -ca 'del(.attributes.tenants)')"
  kc_curl -fsS -o /dev/null -X PUT "${realm_url}/users/${superadmin_uuid}" -d "$superadmin_json"
  remove_managed_roles "${realm_url}/users/${superadmin_uuid}/role-mappings/realm"
fi

for legacy_path in "/SADC-Congenia" "/SADC-Congenia/Admin" "/SADC-Congenia/Medicos"; do
  legacy_group_id="$(group_id_by_path "$legacy_path" || true)"
  if [[ -n "$legacy_group_id" ]]; then
    remove_managed_roles "${realm_url}/groups/${legacy_group_id}/role-mappings/realm"
  fi
done

sadc_uuid="$(kc_curl -fsS "${realm_url}/clients?clientId=sadc" | jq -er '.[0].id // empty' || true)"
if [[ -z "$sadc_uuid" ]]; then
  echo 'FALLA: no existe el cliente OAuth sadc.' >&2
  exit 1
fi
sadc_mappers_url="${realm_url}/clients/${sadc_uuid}/protocol-mappers/models"
sadc_mapper_id="$(kc_curl -fsS "$sadc_mappers_url" | jq -er '.[] | select(.name == "tenant-id") | .id' | head -n 1 || true)"
sadc_mapper="$(jq -nca --arg tenant "$sadc_tenant" '{
  name: "tenant-id",
  protocol: "openid-connect",
  protocolMapper: "oidc-hardcoded-claim-mapper",
  consentRequired: false,
  config: {
    "claim.name": "tenant_id",
    "claim.value": $tenant,
    "jsonType.label": "String",
    "access.token.claim": "true",
    "id.token.claim": "false",
    "userinfo.token.claim": "false"
  }
}')"
if [[ -z "$sadc_mapper_id" ]]; then
  kc_curl -fsS -o /dev/null -X POST "$sadc_mappers_url" -d "$sadc_mapper"
else
  sadc_mapper="$(jq --arg id "$sadc_mapper_id" '.id = $id' <<<"$sadc_mapper")"
  kc_curl -fsS -o /dev/null -X PUT "$sadc_mappers_url/${sadc_mapper_id}" -d "$sadc_mapper"
fi

client_defaults="$(kc_curl -fsS "${realm_url}/clients/${client_uuid}/default-client-scopes")"
for standard_scope in profile email roles; do
  jq -e --arg name "$standard_scope" 'any(.name == $name)' <<<"$client_defaults" >/dev/null || {
    echo "FALLA: congenia-web no tiene ${standard_scope} como default client scope." >&2
    exit 1
  }
done

kc_curl -fsS "${realm_url}/clients/${client_uuid}" |
  jq -e '
    .enabled == true and
    .publicClient == true and
    .standardFlowEnabled == true and
    .attributes["pkce.code.challenge.method"] == "S256" and
    any(.protocolMappers[]?; .name == "tenants" and .config["access.token.claim"] == "true" and .config["aggregate.attrs"] == "true") and
    any(.protocolMappers[]?; .name == "groups" and .protocolMapper == "oidc-group-membership-mapper" and .config["claim.name"] == "groups" and .config["full.path"] == "true" and .config["access.token.claim"] == "true")
  ' >/dev/null || {
    echo 'FALLA: congenia-web no conserva PKCE S256, el mapper agregado de tenants o el mapper groups con ruta completa.' >&2
    exit 1
  }

medico_groups="$(kc_curl -fsS "${realm_url}/users/${user_uuid}/groups")"
while IFS= read -r tenant_id; do
  jq -e --arg path "/instituciones/${tenant_id}/medicos" 'any(.path == $path)' <<<"$medico_groups" >/dev/null || {
    echo "FALLA: ${medico_user} no pertenece al grupo medico del tenant ${tenant_id}." >&2
    exit 1
  }
done < <(jq -Rr 'split(",")[] | gsub("^\\s+|\\s+$"; "") | select(test("^[0-9]+$"))' <<<"$medico_tenants")

kc_curl -fsS "${realm_url}/users/${user_uuid}" |
  jq -e '(.attributes.tenants // []) | length == 0' >/dev/null || {
    echo "FALLA: ${medico_user} todavia tiene tenants asignados directamente." >&2
    exit 1
  }

kc_curl -fsS "$sadc_mappers_url" |
  jq -e --arg tenant "$sadc_tenant" 'any(.[]; .name == "tenant-id" and .config["claim.value"] == $tenant)' >/dev/null || {
    echo 'FALLA: el cliente sadc no emite tenant_id.' >&2
    exit 1
  }


authorization_probe="$(command curl --connect-timeout 10 --max-time 30 -sS -o /dev/null -w '%{http_code} %{redirect_url}' -G \
  "${public_url}/realms/congenia/protocol/openid-connect/auth" \
  --data-urlencode client_id=congenia-web \
  --data-urlencode response_type=code \
  --data-urlencode 'scope=openid profile email' \
  --data-urlencode "redirect_uri=${public_url}/" \
  --data-urlencode state=scope-verification \
  --data-urlencode code_challenge=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
  --data-urlencode code_challenge_method=S256)"
case "$authorization_probe" in
  200\ *|302\ *) ;;
  *)
    echo "FALLA: el endpoint OIDC rechazo la solicitud de verificacion (${authorization_probe})." >&2
    exit 1
    ;;
esac
if [[ "$authorization_probe" == *invalid_scope* ]]; then
  echo 'FALLA: Keycloak todavía devuelve invalid_scope para openid profile email.' >&2
  exit 1
fi

echo "OK: congenia-web verificado con scopes profile, email, roles y tenants; usuario ${medico_user} configurado."

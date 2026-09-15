#!/usr/bin/env bash
set -euo pipefail

: "${KEYCLOAK_BASE_URL:?Define KEYCLOAK_BASE_URL, por ejemplo https://cogenia.app}"
: "${KEYCLOAK_ADMIN_PASSWORD:?Define KEYCLOAK_ADMIN_PASSWORD}"
: "${KEYCLOAK_MEDICO_PASSWORD:?Define KEYCLOAK_MEDICO_PASSWORD para la clave temporal}"

admin_user="${KEYCLOAK_ADMIN_USERNAME:-admin}"
medico_user="${KEYCLOAK_MEDICO_USERNAME:-medico.inicial}"
medico_name="${KEYCLOAK_MEDICO_NAME:-Medico Inicial}"
medico_specialty="${KEYCLOAK_MEDICO_SPECIALTY:-Genetica Clinica}"
medico_tenants="${KEYCLOAK_MEDICO_TENANTS:-23,254}"
superadmin_user="${KEYCLOAK_SUPERADMIN_USERNAME:-admin-doctor}"
sadc_tenant="${KEYCLOAK_SADC_TENANT:-254}"
base_url="${KEYCLOAK_BASE_URL%/}"
realm_url="${base_url}/admin/realms/congenia"

token="$({
  curl -fsS "${base_url}/realms/master/protocol/openid-connect/token" \
    --data-urlencode grant_type=password \
    --data-urlencode client_id=admin-cli \
    --data-urlencode "username=${admin_user}" \
    --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}"
} | jq -er '.access_token')"

auth=(-H "Authorization: Bearer ${token}" -H 'Content-Type: application/json')
target_scopes_url="${realm_url}/client-scopes"
master_scopes_url="${base_url}/admin/realms/master/client-scopes"

scope_id() {
  local scopes_url="$1"
  local scope_name="$2"
  curl -fsS "${auth[@]}" "$scopes_url" |
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
  source_json="$(curl -fsS "${auth[@]}" "${master_scopes_url}/${source_id}")"
  target_id="$(scope_id "$target_scopes_url" "$scope_name" || true)"
  scope_payload="$(jq -a 'del(.id, .protocolMappers)' <<<"$source_json")"

  if [[ -z "$target_id" ]]; then
    curl -fsS -o /dev/null -X POST "${auth[@]}" "$target_scopes_url" -d "$scope_payload"
    target_id="$(scope_id "$target_scopes_url" "$scope_name")"
  else
    curl -fsS -o /dev/null -X PUT "${auth[@]}" \
      "${target_scopes_url}/${target_id}" -d "$scope_payload"
  fi

  while IFS= read -r mapper; do
    local mapper_name
    local mapper_id
    local mapper_payload

    mapper_name="$(jq -er '.name' <<<"$mapper")"
    mapper_id="$({
      curl -fsS "${auth[@]}" "${target_scopes_url}/${target_id}/protocol-mappers/models"
    } | jq -er --arg name "$mapper_name" '.[] | select(.name == $name) | .id' | head -n 1 || true)"

    if [[ -z "$mapper_id" ]]; then
      mapper_payload="$(jq -a 'del(.id)' <<<"$mapper")"
      curl -fsS -o /dev/null -X POST "${auth[@]}" \
        "${target_scopes_url}/${target_id}/protocol-mappers/models" -d "$mapper_payload"
    else
      mapper_payload="$(jq --arg id "$mapper_id" '.id = $id' <<<"$mapper")"
      curl -fsS -o /dev/null -X PUT "${auth[@]}" \
        "${target_scopes_url}/${target_id}/protocol-mappers/models/${mapper_id}" \
        -d "$mapper_payload"
    fi
  done < <(jq -c '.protocolMappers[]' <<<"$source_json")

  local expected_mappers
  local actual_mappers
  expected_mappers="$(jq -c '[.protocolMappers[].name] | sort' <<<"$source_json")"
  actual_mappers="$({
    curl -fsS "${auth[@]}" "${target_scopes_url}/${target_id}/protocol-mappers/models"
  } | jq -c '[.[].name] | sort')"

  jq -e --argjson expected "$expected_mappers" --argjson actual "$actual_mappers" \
    '$expected - $actual | length == 0' <<<null >/dev/null || {
      echo "FALLA: el scope ${scope_name} no contiene todos sus mappers estándar." >&2
      return 1
    }
}

for standard_scope in basic profile email roles; do
  ensure_standard_scope "$standard_scope"
done

ensure_role() {
  local role_name="$1"
  local description="$2"

  if ! curl -fsS -o /dev/null "${auth[@]}" "${realm_url}/roles/${role_name}" 2>/dev/null; then
    jq -nca --arg name "$role_name" --arg description "$description" \
      '{name: $name, description: $description}' |
      curl -fsS -o /dev/null -X POST "${auth[@]}" "${realm_url}/roles" -d @-
  fi
}

ensure_role "medico" "Puede iniciar fichas clinicas desde el cliente web"
ensure_role "congenia-admin" "Puede revisar y resolver adendas en el dashboard"
ensure_role "congenia-coordinador" "Puede consultar y coordinar expedientes asignados"
ensure_role "congenia-genetista" "Puede crear fichas y adendas como genetista"
ensure_role "congenia-superadmin" "Puede consultar todos los tenants y administrar catalogos"

client_json="$(jq -nca --arg origin "$base_url" '{
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
    }
  ]
}')"

client_uuid="$(curl -fsS "${auth[@]}" "${realm_url}/clients?clientId=congenia-web" | jq -er '.[0].id // empty' || true)"
if [[ -z "$client_uuid" ]]; then
  curl -fsS -o /dev/null -X POST "${auth[@]}" "${realm_url}/clients" -d "$client_json"
  client_uuid="$(curl -fsS "${auth[@]}" "${realm_url}/clients?clientId=congenia-web" | jq -er '.[0].id')"
else
  curl -fsS -o /dev/null -X PUT "${auth[@]}" "${realm_url}/clients/${client_uuid}" -d "$client_json"
fi

for standard_scope in basic profile email roles; do
  standard_scope_id="$(scope_id "$target_scopes_url" "$standard_scope")"
  curl -fsS -o /dev/null -X PUT "${auth[@]}" \
    "${realm_url}/clients/${client_uuid}/default-client-scopes/${standard_scope_id}"
done

user_uuid="$(curl -fsS "${auth[@]}" "${realm_url}/users?exact=true&username=${medico_user}" | jq -er '.[0].id // empty' || true)"
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
  curl -fsS -o /dev/null -X POST "${auth[@]}" "${realm_url}/users" -d "$user_json"
  user_uuid="$(curl -fsS "${auth[@]}" "${realm_url}/users?exact=true&username=${medico_user}" | jq -er '.[0].id')"
else
  user_json="$(curl -fsS "${auth[@]}" "${realm_url}/users/${user_uuid}" |
    jq -ca \
      --arg name "$medico_name" \
      --arg specialty "$medico_specialty" \
      '.firstName = $name
       | .enabled = true
       | .attributes = ((.attributes // {}) + {especialidad: [$specialty]})
       | del(.attributes.tenants)')"
  curl -fsS -o /dev/null -X PUT "${auth[@]}" "${realm_url}/users/${user_uuid}" -d "$user_json"
fi

group_id_by_path() {
  local group_path="$1"
  curl -fsS "${auth[@]}" "${realm_url}/group-by-path${group_path}" | jq -er '.id'
}

ensure_group() {
  local parent_id="$1"
  local group_name="$2"
  local group_path="$3"
  local attributes_json="${4:-{}}"
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
      curl -fsS -o /dev/null -X POST "${auth[@]}" "$endpoint" -d @-
    group_id="$(group_id_by_path "$group_path")"
  elif [[ "$attributes_json" != "{}" ]]; then
    group_json="$(curl -fsS "${auth[@]}" "${realm_url}/groups/${group_id}" |
      jq -ca --argjson attributes "$attributes_json" '.attributes = $attributes')"
    curl -fsS -o /dev/null -X PUT "${auth[@]}" "${realm_url}/groups/${group_id}" -d "$group_json"
  fi
  printf '%s' "$group_id"
}

ensure_group_role() {
  local group_id="$1"
  local role_name="$2"
  local role_json
  local assigned
  role_json="$(curl -fsS "${auth[@]}" "${realm_url}/roles/${role_name}")"
  assigned="$(curl -fsS "${auth[@]}" "${realm_url}/groups/${group_id}/role-mappings/realm")"
  if ! jq -e --arg name "$role_name" 'any(.name == $name)' <<<"$assigned" >/dev/null; then
    jq -nca --argjson role "$role_json" '[$role]' |
      curl -fsS -o /dev/null -X POST "${auth[@]}" \
        "${realm_url}/groups/${group_id}/role-mappings/realm" -d @-
  fi
}

remove_managed_roles() {
  local mapping_url="$1"
  local assigned
  local managed
  assigned="$(curl -fsS "${auth[@]}" "$mapping_url")"
  managed="$(jq -ca '[.[] | select(.name == "medico" or .name == "congenia-admin" or .name == "congenia-coordinador" or .name == "congenia-genetista" or .name == "congenia-superadmin" or .name == "admin" or .name == "administrador" or .name == "genetista")]' <<<"$assigned")"
  if [[ "$(jq -r 'length' <<<"$managed")" -gt 0 ]]; then
    curl -fsS -o /dev/null -X DELETE "${auth[@]}" "$mapping_url" -d "$managed"
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
  curl -fsS -o /dev/null -X PUT "${auth[@]}" "${realm_url}/users/${user_uuid}/groups/${medico_group_id}"
done < <(jq -Rr 'split(",")[] | gsub("^\\s+|\\s+$"; "") | select(test("^[0-9]+$"))' <<<"$medico_tenants")
remove_managed_roles "${realm_url}/users/${user_uuid}/role-mappings/realm"

superadmin_group_id="$(ensure_group "" "superadministradores" "/superadministradores")"
ensure_group_role "$superadmin_group_id" "congenia-superadmin"
ensure_group_role "$superadmin_group_id" "congenia-admin"
superadmin_uuid="$(curl -fsS "${auth[@]}" "${realm_url}/users?exact=true&username=${superadmin_user}" | jq -er '.[0].id // empty' || true)"
if [[ -n "$superadmin_uuid" ]]; then
  curl -fsS -o /dev/null -X PUT "${auth[@]}" "${realm_url}/users/${superadmin_uuid}/groups/${superadmin_group_id}"
  superadmin_json="$(curl -fsS "${auth[@]}" "${realm_url}/users/${superadmin_uuid}" | jq -ca 'del(.attributes.tenants)')"
  curl -fsS -o /dev/null -X PUT "${auth[@]}" "${realm_url}/users/${superadmin_uuid}" -d "$superadmin_json"
  remove_managed_roles "${realm_url}/users/${superadmin_uuid}/role-mappings/realm"
fi

for legacy_path in "/SADC-Congenia" "/SADC-Congenia/Admin" "/SADC-Congenia/Medicos"; do
  legacy_group_id="$(group_id_by_path "$legacy_path" || true)"
  if [[ -n "$legacy_group_id" ]]; then
    remove_managed_roles "${realm_url}/groups/${legacy_group_id}/role-mappings/realm"
  fi
done

sadc_uuid="$(curl -fsS "${auth[@]}" "${realm_url}/clients?clientId=sadc" | jq -er '.[0].id // empty' || true)"
if [[ -z "$sadc_uuid" ]]; then
  echo 'FALLA: no existe el cliente OAuth sadc.' >&2
  exit 1
fi
sadc_mappers_url="${realm_url}/clients/${sadc_uuid}/protocol-mappers/models"
sadc_mapper_id="$(curl -fsS "${auth[@]}" "$sadc_mappers_url" | jq -er '.[] | select(.name == "tenant-id") | .id' | head -n 1 || true)"
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
  curl -fsS -o /dev/null -X POST "${auth[@]}" "$sadc_mappers_url" -d "$sadc_mapper"
else
  sadc_mapper="$(jq --arg id "$sadc_mapper_id" '.id = $id' <<<"$sadc_mapper")"
  curl -fsS -o /dev/null -X PUT "${auth[@]}" "$sadc_mappers_url/${sadc_mapper_id}" -d "$sadc_mapper"
fi

client_defaults="$(curl -fsS "${auth[@]}" "${realm_url}/clients/${client_uuid}/default-client-scopes")"
for standard_scope in profile email roles; do
  jq -e --arg name "$standard_scope" 'any(.name == $name)' <<<"$client_defaults" >/dev/null || {
    echo "FALLA: congenia-web no tiene ${standard_scope} como default client scope." >&2
    exit 1
  }
done

curl -fsS "${auth[@]}" "${realm_url}/clients/${client_uuid}" |
  jq -e '
    .enabled == true and
    .publicClient == true and
    .standardFlowEnabled == true and
    .attributes["pkce.code.challenge.method"] == "S256" and
    any(.protocolMappers[]?; .name == "tenants" and .config["access.token.claim"] == "true" and .config["aggregate.attrs"] == "true")
  ' >/dev/null || {
    echo 'FALLA: congenia-web no conserva PKCE S256 o el mapper agregado de tenants.' >&2
    exit 1
  }

medico_groups="$(curl -fsS "${auth[@]}" "${realm_url}/users/${user_uuid}/groups")"
while IFS= read -r tenant_id; do
  jq -e --arg path "/instituciones/${tenant_id}/medicos" 'any(.path == $path)' <<<"$medico_groups" >/dev/null || {
    echo "FALLA: ${medico_user} no pertenece al grupo medico del tenant ${tenant_id}." >&2
    exit 1
  }
done < <(jq -Rr 'split(",")[] | gsub("^\\s+|\\s+$"; "") | select(test("^[0-9]+$"))' <<<"$medico_tenants")

curl -fsS "${auth[@]}" "${realm_url}/users/${user_uuid}" |
  jq -e '(.attributes.tenants // []) | length == 0' >/dev/null || {
    echo "FALLA: ${medico_user} todavia tiene tenants asignados directamente." >&2
    exit 1
  }

curl -fsS "${auth[@]}" "$sadc_mappers_url" |
  jq -e --arg tenant "$sadc_tenant" 'any(.[]; .name == "tenant-id" and .config["claim.value"] == $tenant)' >/dev/null || {
    echo 'FALLA: el cliente sadc no emite tenant_id.' >&2
    exit 1
  }


authorization_probe="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -G \
  "${base_url}/realms/congenia/protocol/openid-connect/auth" \
  --data-urlencode client_id=congenia-web \
  --data-urlencode response_type=code \
  --data-urlencode 'scope=openid profile email' \
  --data-urlencode "redirect_uri=${base_url}/" \
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

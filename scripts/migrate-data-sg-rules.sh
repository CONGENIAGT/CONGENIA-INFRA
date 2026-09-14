#!/usr/bin/env bash
# Adopta reglas existentes en el estado; no crea/revoca reglas en AWS.
# Uso: script envs/aws [--apply] [argumentos de terraform import]
set -euo pipefail
TFDIR=${1:-envs/aws}
shift || true
APPLY=false
if [[ ${1:-} == --apply ]]; then APPLY=true; shift; fi
TF=${TERRAFORM:-terraform}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
tf() { "$TF" -chdir="$TFDIR" "$@"; }
tf init -input=false
tf state list > "$WORK/state"
if ! grep -qx 'module.network.aws_security_group.data' "$WORK/state"; then
  echo "Sin SG data en el estado: una instalacion nueva crea las reglas directamente."
  exit 0
fi
tf state show -no-color module.network.aws_security_group.data > "$WORK/data"
tf state show -no-color module.network.aws_security_group.app > "$WORK/app"
DATA=$(sed -nE 's/^[[:space:]]*id[[:space:]]*=[[:space:]]*"(sg-[^"]+)".*/\1/p' "$WORK/data")
APP=$(sed -nE 's/^[[:space:]]*id[[:space:]]*=[[:space:]]*"(sg-[^"]+)".*/\1/p' "$WORK/app")
[[ -n "$DATA" && -n "$APP" ]] || { echo "No pude identificar los SG del estado" >&2; exit 1; }
REGION=$(tf output -raw region)
VPC=$(tf output -raw vpc_id)
CIDR=$(aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$VPC" --query 'Vpcs[0].CidrBlock' --output text)
aws ec2 describe-security-group-rules --region "$REGION" \
  --filters "Name=group-id,Values=$DATA" > "$WORK/rules.json"

# Resolver todas antes de mutar el estado: cero o multiples coincidencias
# requieren revision y no se sustituyen por reglas nuevas.
for name in data_postgres data_redis data_vpc; do
  case "$name" in
    data_postgres) kind=ingress; port=5432 ;;
    data_redis) kind=ingress; port=6379 ;;
    data_vpc) kind=egress; port=0 ;;
  esac
  address="module.network.aws_vpc_security_group_${kind}_rule.$name"
  ids=$(jq --arg app "$APP" --arg cidr "$CIDR" --arg kind "$kind" --argjson port "$port" '
    [.SecurityGroupRules[] | select(
      if $kind == "egress" then .IsEgress and .IpProtocol == "-1" and .CidrIpv4 == $cidr
      else .IsEgress == false and .IpProtocol == "tcp" and .FromPort == $port and .ToPort == $port
        and .ReferencedGroupInfo.GroupId == $app end) | .SecurityGroupRuleId]' "$WORK/rules.json")
  [[ $(jq length <<< "$ids") == 1 ]] || { echo "Regla ambigua o ausente: $name ($ids)" >&2; exit 1; }
  id=$(jq -r '.[0]' <<< "$ids")
  if grep -qx "$address" "$WORK/state"; then
    tf state show -no-color "$address" | grep -Eq "id[[:space:]]*=[[:space:]]*\"$id\"" || {
      echo "El estado de $address apunta a otra regla" >&2; exit 1;
    }
    echo "$address ya administra $id"
  else
    printf '%s %s\n' "$address" "$id" >> "$WORK/imports"
    echo "Importar: $address <- $id"
  fi
done
if [[ "$APPLY" == true && -f "$WORK/imports" ]]; then
  while read -r address id; do tf import -input=false "$@" "$address" "$id"; done < "$WORK/imports"
else
  echo "Solo revision. --apply importa en el estado, sin cambiar accesos AWS."
fi
echo "Siguiente: revisar plan del entorno principal con sus variables vigentes y publicar db_access_context."

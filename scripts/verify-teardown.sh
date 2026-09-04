#!/usr/bin/env bash
# =============================================================================
# Comprueba contra AWS que no sobrevivio ningun recurso del proyecto.
#
# No lee el estado de Terraform a proposito: un `destroy` puede terminar en
# verde y aun asi dejar cosas atras. Los casos tipicos son recursos creados a
# mano durante una depuracion que nunca entraron al estado, secretos en
# ventana de recuperacion, y ENIs de Fargate que sobreviven a sus tareas.
#
# Uso:
#   ./scripts/verify-teardown.sh              # barrido de la cuenta
#   ./scripts/verify-teardown.sh --perimetro  # checklist fuera de AWS
#
# Sale con 0 solo si la cuenta quedo limpia.
# =============================================================================
set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
PREFIJO="${TF_VAR_name_prefix:-congenia}"
DOMINIO="${TF_VAR_domain_name:-cogenia.app}"

if [[ "${1:-}" == "--perimetro" ]]; then
  cat <<PERIMETRO

  Perimetro fuera de Terraform
  ════════════════════════════

  Estos no los borra ningun destroy porque viven fuera de los dos estados.
  Repasarlos a mano para cerrar de verdad:

  [ ] Bucket del estado remoto (congenia-tfstate).
      Va al final y no dentro de 'make nuke': Terraform necesita el backend
      para poder destruir envs/shared. Esta versionado, asi que hay que
      vaciarlo por versiones antes de borrarlo:

        aws s3api delete-objects --bucket congenia-tfstate \\
          --delete "\$(aws s3api list-object-versions \\
            --bucket congenia-tfstate \\
            --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')"
        aws s3api delete-bucket --bucket congenia-tfstate

  [ ] Delegacion de nameservers en name.com.
      Quedan apuntando a una zona de Route 53 que ya no existe. Devolverlos a
      los de name.com, o liberar el dominio si tampoco se va a usar.

  [ ] Token INFRA_TOKEN en GitHub.
      Es una credencial viva con permiso de escritura sobre CONGENIA-INFRA.
      Revocarla en Settings > Developer settings > Personal access tokens.

  [ ] Variables y secretos de organizacion en GitHub.
      AWS_ROLE_ARN, AWS_REGION y ECR_REGISTRY quedan apuntando a una cuenta
      muerta: borrarlos para que ningun workflow los reutilice por error.

  [ ] Workflows de publicacion en los repositorios de servicio.
      Sin el rol ya no pueden publicar, pero seguiran fallando en cada push.
      Desactivarlos o archivar los repositorios.

PERIMETRO
  exit 0
fi

if ! cuenta=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "No hay credenciales de AWS activas. Exporta AWS_PROFILE antes de verificar." >&2
  exit 2
fi

echo "═══════════════════════════════════════════════════════════════════════"
echo "  Barrido de recursos supervivientes"
echo "  Cuenta ${cuenta} · region ${REGION} · prefijo ${PREFIJO}"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""

SOBREVIVIENTES=0

# Ejecuta una consulta y reporta lo que devuelva. Una consulta que no devuelve
# nada es el resultado esperado.
revisar() {
  local etiqueta="$1"; shift
  local salida
  salida=$("$@" 2>/dev/null | tr -d '\r' | grep -v '^None$' | grep -v '^$' || true)

  if [[ -z "$salida" ]]; then
    printf "  \033[32mok\033[0m    %s\n" "$etiqueta"
  else
    printf "  \033[31mQUEDA\033[0m %s\n" "$etiqueta"
    printf '            %s\n' $salida
    SOBREVIVIENTES=$((SOBREVIVIENTES + 1))
  fi
}

q() { aws --region "$REGION" "$@"; }

# ── Computo ─────────────────────────────────────────────────────────────────
revisar "ECS clusters" \
  q ecs list-clusters --query "clusterArns[?contains(@, '${PREFIJO}')]" --output text

# Las ENIs de Fargate a veces sobreviven a la tarea y bloquean el borrado de la
# VPC con un DependencyViolation poco descriptivo.
revisar "ENIs sin adjuntar" \
  q ec2 describe-network-interfaces \
  --filters "Name=status,Values=available" \
  --query "NetworkInterfaces[?contains(Description, '${PREFIJO}')].NetworkInterfaceId" --output text

# ── Red ─────────────────────────────────────────────────────────────────────
revisar "VPCs" \
  q ec2 describe-vpcs --filters "Name=tag:Project,Values=CONGENIA" \
  --query "Vpcs[].VpcId" --output text

revisar "NAT gateways" \
  q ec2 describe-nat-gateways \
  --filter "Name=state,Values=available,pending" \
  --query "NatGateways[?Tags[?Value=='CONGENIA']].NatGatewayId" --output text

revisar "Elastic IPs" \
  q ec2 describe-addresses --query "Addresses[?Tags[?Value=='CONGENIA']].AllocationId" --output text

revisar "Load balancers" \
  q elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName, '${PREFIJO}')].LoadBalancerName" --output text

# ── Datos ───────────────────────────────────────────────────────────────────
revisar "Instancias RDS" \
  q rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier, '${PREFIJO}')].DBInstanceIdentifier" --output text

revisar "Snapshots RDS" \
  q rds describe-db-snapshots --snapshot-type manual \
  --query "DBSnapshots[?contains(DBSnapshotIdentifier, '${PREFIJO}')].DBSnapshotIdentifier" --output text

revisar "ElastiCache" \
  q elasticache describe-cache-clusters \
  --query "CacheClusters[?contains(CacheClusterId, '${PREFIJO}')].CacheClusterId" --output text

# El bucket del estado remoto se excluye a proposito: es el backend de
# Terraform y debe sobrevivir a cualquier reconstruccion. Se reporta aparte.
revisar "Buckets S3" \
  aws s3api list-buckets \
  --query "Buckets[?contains(Name, '${PREFIJO}') && !contains(Name, 'tfstate')].Name" --output text

# ── Imagenes y secretos ─────────────────────────────────────────────────────
revisar "Repositorios ECR" \
  q ecr describe-repositories --query "repositories[?contains(repositoryName, 'congenia')].repositoryName" --output text

revisar "Secretos activos" \
  q secretsmanager list-secrets \
  --query "SecretList[?contains(Name, '${PREFIJO}')].Name" --output text

# ── Observabilidad e identidad ──────────────────────────────────────────────
revisar "Log groups" \
  q logs describe-log-groups --log-group-name-prefix "/ecs/${PREFIJO}" \
  --query "logGroups[].logGroupName" --output text

revisar "Certificados ACM" \
  q acm list-certificates --query "CertificateSummaryList[?contains(DomainName, '${DOMINIO}')].DomainName" --output text

revisar "Zonas Route 53" \
  aws route53 list-hosted-zones --query "HostedZones[?contains(Name, '${DOMINIO}')].Name" --output text

revisar "Roles IAM" \
  aws iam list-roles --query "Roles[?contains(RoleName, '${PREFIJO}')].RoleName" --output text

revisar "Proveedor OIDC de GitHub" \
  aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn" --output text

revisar "Namespaces de Cloud Map" \
  q servicediscovery list-namespaces \
  --query "Namespaces[?contains(Name, '${PREFIJO}')].Name" --output text

# Informativo, no cuenta como sobreviviente: un secreto en ventana de
# recuperacion ya esta borrado a efectos de facturacion y desaparece solo. Solo
# estorba si hay que reutilizar exactamente ese nombre antes de que expire.
pendientes=$(q secretsmanager list-secrets --include-planned-deletion \
  --query "SecretList[?contains(Name, '${PREFIJO}') && DeletedDate != null].[Name,DeletedDate]" \
  --output text 2>/dev/null || true)

if [[ -n "$pendientes" ]]; then
  echo ""
  echo "  Secretos en ventana de recuperacion (se borran solos, no se facturan):"
  printf '%s\n' "$pendientes" | while read -r nombre fecha _; do
    printf "    %-42s borrado solicitado el %s\n" "$nombre" "${fecha%%T*}"
  done
  echo ""
  echo "  AWS no expone la fecha efectiva de borrado, solo la de solicitud: la"
  echo "  ventana de recuperacion es de 7 a 30 dias desde esa fecha. Solo"
  echo "  estorban si hay que reutilizar ese nombre exacto antes de que expiren."
  echo "  Para forzar el borrado inmediato e irreversible:"
  echo "    aws secretsmanager delete-secret --force-delete-without-recovery \\"
  echo "      --region ${REGION} --secret-id <nombre>"
fi

echo ""
if [[ "$SOBREVIVIENTES" -eq 0 ]]; then
  echo "  La cuenta quedo limpia: ningun recurso del proyecto sobrevive."
  echo "  (El bucket del estado remoto se conserva a proposito: es el backend.)"
  echo ""
  echo "  Falta el perimetro fuera de AWS:"
  echo "    ./scripts/verify-teardown.sh --perimetro"
  exit 0
fi

echo "  ${SOBREVIVIENTES} categoria(s) con recursos vivos."
echo ""
echo "  Si esto sigue a un destroy en verde, casi siempre es una de dos cosas:"
echo "  un recurso creado a mano que nunca entro al estado, o una dependencia"
echo "  que fallo en silencio (tipicamente una ENI reteniendo la VPC)."
exit 1

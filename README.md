# CONGENIA-INFRA

Infraestructura como código oficial de CONGENIA. El estado está partido en dos
stacks con ciclos de vida distintos:

- `envs/shared`: persistente. Registro de imágenes (ECR), identidad de GitHub
  Actions y zona DNS. Cuesta menos de USD 1/mes y sobrevive a los apagados.
- `envs/aws`: la infraestructura oficial, identificada como `prod`. Concentra
  todo el gasto y se destruye en cada pausa larga.

Las imágenes ya no se construyen a mano: cada repositorio de servicio publica
la suya en ECR por GitHub Actions al mergear, y abre un PR aquí registrando el
tag. Desplegar sigue siendo una decisión humana.

## Arquitectura

| Capacidad | Implementación |
|---|---|
| Red | VPC, subredes edge/app/data en 2 AZ, SG y NACL |
| Entrada | ALB con HTTPS y certificado ACM, DNS en Route 53 |
| Cómputo | ECS Fargate, cinco servicios |
| Datos | RDS PostgreSQL 16, Single-AZ y cifrada |
| Sesiones | ElastiCache Redis 7 |
| Documentos | S3 privado, cifrado y versionado |
| Identidad | Keycloak en ECS |
| Mensajería | RabbitMQ en ECS |
| Registro | ECR con tags inmutables (`envs/shared`) |
| Entrega | GitHub Actions por OIDC, sin llaves de AWS |

Los módulos compartidos viven en `modules/`; el cableado, en `envs/`.

## Requisitos

- Terraform `>= 1.6`
- AWS CLI v2 y credenciales del proyecto
- `jq`, `curl`, Bash y GNU Make
- Docker con `buildx` solo si se va a publicar una imagen a mano; el pipeline
  no lo necesita

El backend AWS usa el bucket versionado `congenia-tfstate`, con cifrado y lock
nativo de S3. El estado contiene secretos generados y su acceso debe limitarse
al equipo de infraestructura.

## Comandos

```bash
make help
make init ENV=aws|shared
make plan ENV=aws|shared
make create ENV=aws|shared
make up-aws
make smoke
make smoke-integration
make open
make close
make destroy
make verify-teardown
make nuke
make cost-status
```

`ENV` vale `aws` por defecto.

- `create` crea o reconcilia infraestructura; en AWS deja las tareas apagadas.
- `up-aws` es el ciclo completo `create → migrate → open → smoke`.
- `open` escala las tareas oficiales a las cantidades declaradas.
- `close` lleva las tareas a cero sin borrar datos ni la red.
- `destroy` elimina el entorno de aplicación; AWS exige confirmación explícita.
  Conserva `envs/shared`, así que volver no exige republicar imágenes ni
  re-delegar DNS.
- `nuke` destruye además `envs/shared`. Es un cierre de proyecto, no una
  operación de rutina.
- `verify-teardown` le pregunta a AWS qué recursos del proyecto siguen vivos,
  en lugar de confiar en que Terraform terminó en verde.
- Opciones Terraform adicionales se pasan con `TF_VARS`, por ejemplo
  `TF_VARS='-var=enable_waf=true'`.

## Despliegue oficial en AWS

El diseño de lo que corre —red, capas de aislamiento, entrega de imágenes y
persistencia— está en **[docs/ARQUITECTURA.md](docs/ARQUITECTURA.md)**.

El ciclo de vida completo está en **[docs/DEPLOY.md](docs/DEPLOY.md)**, en tres partes:

| Parte | Qué cubre | Con qué frecuencia |
|---|---|---|
| 1 | Preparar la cuenta: estado remoto, `envs/shared`, delegación de DNS, configuración de GitHub | Una vez por cuenta |
| 2 | Desplegar, configurar Keycloak, probar, publicar una versión nueva | Cada despliegue |
| 3 | Apagar: dormir servicios, destruir el entorno, nuke total | Cada pausa |

Si `make plan ENV=aws` falla diciendo que no encuentra un repositorio ECR, la
cuenta no pasó por la parte 1.

Lo que sigue en este README es el resumen; el detalle está en ese documento.

### 1. Comprobar plan y créditos

```bash
make cost-status
aws sts get-caller-identity
make plan ENV=aws
```

Revisar cuenta, región, nombres, reemplazos y costo antes del apply.

### 2. Crear la base con servicios apagados

```bash
make create ENV=aws
```

`enable_services=false` es el default. Se crean la plataforma y sus
dependencias, pero no se ejecutan imágenes pendientes o incompletas.

### 3. Publicar imágenes inmutables

Ya no se construye nada a mano: cada repositorio de servicio tiene un workflow
de GitHub Actions que publica su imagen en ECR al mergear, y abre un PR aquí
con el tag nuevo. `envs/aws/images.tfvars` sigue siendo el registro versionado
de qué versión corre; lo que cambió es quién escribe la línea.

Con las imágenes ya publicadas y el manifiesto mergeado:

```bash
make plan ENV=aws
make create ENV=aws
```

ECR es inmutable: nunca se usa `latest`, y el tag se deriva del commit. Para
publicar sin pasar por GitHub —una cuenta nueva, una depuración— siguen
existiendo `./scripts/release-plan.sh` en el orquestador y
`make migrate-image ENV=aws`, que calculan exactamente los mismos tags.

El arranque en frío de una cuenta, incluida la configuración de GitHub, está
en [docs/DEPLOY.md](docs/DEPLOY.md), parte 1.

### 4. Cargar el esquema inicial

```bash
make migrate ENV=aws
```

La tarea de una sola ejecución aplica los SQL incluidos en la imagen de
migración. Es idempotente para una base nueva; cambios futuros de esquema deben
usar migraciones incrementales.

### 5. TLS y DNS

Con el dominio delegado a Route 53 (paso único, documentado en
[docs/DEPLOY.md](docs/DEPLOY.md) parte 1), Terraform crea el registro de validación de ACM
y el ALIAS al ALB, y espera el `ISSUED` dentro del mismo apply. No hay paso
manual.

Para un dominio cuyo DNS viva fuera de la cuenta, `-var=manage_dns=false`
devuelve el proceso anterior de dos aplicaciones con `validate_certificate`;
está descrito en `envs/aws/certificate.tf`.

### 6. Abrir y validar

```bash
make open ENV=aws
make smoke ENV=aws

# Solo es necesario al actualizar un realm que ya existia: el import de
# arranque de Keycloak no sobrescribe realms persistidos. El script restaura
# profile/email/roles desde el realm master, los asigna y verifica el resultado.
export KEYCLOAK_BASE_URL="$(terraform -chdir=envs/aws output -raw public_url)"
export KEYCLOAK_ADMIN_PASSWORD="$(aws secretsmanager get-secret-value \
  --secret-id "$(terraform -chdir=envs/aws output -raw keycloak_admin_secret_arn)" \
  --query SecretString --output text)"
export KEYCLOAK_MEDICO_PASSWORD="$(aws secretsmanager get-secret-value \
  --secret-id "$(terraform -chdir=envs/aws output -raw keycloak_medico_initial_secret_arn)" \
  --query SecretString --output text)"
./scripts/configure-keycloak-web.sh
unset KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_MEDICO_PASSWORD

export SADC_CLIENT_SECRET="$(aws secretsmanager get-secret-value \
  --secret-id "$(terraform -chdir=envs/aws output -raw sadc_client_secret_arn)" \
  --query SecretString --output text)"
make smoke-integration ENV=aws
unset SADC_CLIENT_SECRET
```

El acceso web inicial usa `medico.inicial` y la contraseña del secreto
`keycloak_medico_initial_secret_arn`; Keycloak exige cambiarla en el primer
login. Los médicos posteriores deben crearse con el rol de realm `medico` y el
atributo `especialidad`.

Con el perfil menor a 1 TPS se espera `1/1` para frontend, API, Keycloak,
RabbitMQ y PDF worker.

Antes de tráfico real, completar un recorrido sin datos personales: cargar
PNG/JPEG y PDF válidos, rechazar MIME/tamaños inválidos, enviar dos veces la
misma ficha, confirmar un solo `ficha_id`, verificar el PDF generado y revisar
que logs y nombres de objeto no contengan PHI ni capabilities.

## AWS Free Plan y control de consumo

El plan gratuito actual funciona con créditos. NAT Gateway, ALB, Fargate,
ElastiCache, WAF, endpoints privados, Secrets Manager y CloudWatch son
servicios medidos: que la cuenta sea `FREE` no los vuelve costo cero.

Los defaults oficiales minimizan consumo sin cambiar la identidad productiva:

- nombres `congenia-prod-*` y `APP_ENV=prod`;
- RDS `db.t4g.micro`, Single-AZ, 20 GiB y un día de backup;
- Redis `cache.t4g.micro`, un nodo y sin snapshots de sesiones temporales;
- una tarea por servicio y tamaños Fargate equivalentes al entorno local;
- servicios apagados hasta ejecutar `make open`;
- endpoint gateway S3, que no tiene cargo adicional;
- NAT habilitado para la salida requerida por los servicios;
- endpoints privados, WAF, Flow Logs, VPN y Multi-AZ desactivados por defecto.

`free_plan_mode=true` impide durante `plan` usar Multi-AZ, tamaños mayores,
más de un día de backup o más de una tarea por servicio. Para cambiar esas
decisiones se debe desactivar explícitamente el perfil y revisar presupuesto.

NAT, ALB, RDS y Redis siguen consumiendo créditos aunque las tareas estén en
cero. `make close` reduce Fargate; para detener todo consumo hay que destruir
la infraestructura.

## Destrucción automatizada

El estado está partido en dos stacks, y eso define qué borra cada comando:

| | `envs/shared` | `envs/aws` |
|---|---|---|
| Contiene | ECR, OIDC, rol de CI, zona Route 53 | VPC, NAT, ALB, RDS, Redis, ECS, secretos |
| Cuesta | menos de USD 1/mes | prácticamente todo el gasto |
| Lo destruye | `make nuke` | `make destroy ENV=aws` |

Apagado de rutina:

```bash
make destroy ENV=aws CONFIRM_DESTROY=destroy-congenia-aws
```

El target lleva ECS a cero, activa temporalmente `allow_destroy=true` y elimina
RDS sin snapshot final, todas las versiones del bucket, los secretos y el resto
del stack de aplicación. Es irreversible en cuanto a datos, pero **conserva las
imágenes y el DNS**: volver a levantar es `make up-aws`.

AWS, cierre de proyecto:

```bash
make nuke CONFIRM_DESTROY=destroy-congenia-todo
```

Destruye `envs/aws` y después `envs/shared` —el orden es obligatorio—, y
termina comprobando contra AWS que no quedó nada, más el checklist de lo que
vive fuera de Terraform (bucket del estado, delegación en name.com, token de
GitHub). Ejecutado sin la confirmación, solo imprime qué haría.

Si el estado AWS está vacío, el target termina sin crear nada. Un recurso que
exista fuera del estado nunca debe eliminarse a ciegas: primero se recupera una
versión válida del backend o se importa, se revisa el plan y recién entonces se
autoriza su destrucción.

## Riesgos conocidos

- RabbitMQ corre en Fargate sin almacenamiento persistente; un reinicio puede
  perder trabajos. Antes de mayor carga debe migrarse a SQS/Amazon MQ o a un
  patrón outbox.
- La carga SQL cubre instalaciones iniciales, no upgrades incrementales.
- Los smoke tests comprueban contenido y no solo códigos HTTP: con las reglas
  de path mal aplicadas el ALB devuelve 200 sirviendo el SPA en todas las
  rutas, y un smoke que mirara el código daría un falso verde.
- La cuenta Free Plan tiene vigencia y créditos finitos. Consultarlos antes y
  después de cada ventana de prueba con `make cost-status`.
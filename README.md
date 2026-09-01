# CONGENIA-INFRA

Infraestructura como código oficial de CONGENIA. Terraform describe la misma
plataforma en dos destinos:

- `envs/local`: validación integral sobre MiniStack con contenedores reales.
- `envs/aws`: infraestructura oficial en AWS, identificada como `prod`.

La prueba local es el gate del despliegue: el código y las imágenes solo se
publican después de que creación, smoke tests, integración y destrucción local
terminen correctamente.

Este README es la única guía operativa versionada del repositorio.

## Arquitectura

| Capacidad | AWS | Local |
|---|---|---|
| Red | VPC, subredes edge/app/data, SG y NACL | equivalente MiniStack |
| Entrada | ALB HTTP/HTTPS y ACM | ALB emulado |
| Cómputo | ECS Fargate | tareas ECS respaldadas por Docker |
| Datos | RDS PostgreSQL | contenedor PostgreSQL |
| Sesiones | ElastiCache Redis con TLS | contenedor Redis |
| Documentos | S3 privado, cifrado y versionado | S3 MiniStack |
| Identidad | Keycloak en ECS | Keycloak en ECS |
| Mensajería | RabbitMQ en ECS | RabbitMQ en ECS |
| Registro | ECR con tags inmutables | imágenes Docker locales |

Los módulos compartidos viven en `modules/`; las diferencias de destino se
concentran en `envs/local` y `envs/aws`.

## Requisitos

- Terraform `>= 1.6`
- Docker con `buildx`
- AWS CLI v2 y credenciales del proyecto para `ENV=aws`
- `jq`, `curl`, Bash y GNU Make
- MiniStack disponible en `http://localhost:4566` para la prueba local
- repositorio orquestador `ProjectUVG` junto a este repositorio

El backend AWS usa el bucket versionado `congenia-tfstate`, con cifrado y lock
nativo de S3. El estado contiene secretos generados y su acceso debe limitarse
al equipo de infraestructura.

## Comandos

```bash
make help
make init ENV=local|aws
make plan ENV=local|aws
make create ENV=local|aws
make up ENV=local
make smoke ENV=local|aws
make smoke-integration ENV=local|aws
make open ENV=aws
make close ENV=aws
make destroy ENV=local
make cost-status
```

- `create` crea o reconcilia infraestructura; en AWS deja las tareas apagadas.
- `up` es exclusivamente el ciclo local `create → reconcile → smoke`.
- `open` escala las tareas oficiales a las cantidades declaradas.
- `close` lleva las tareas a cero sin borrar datos ni la red.
- `destroy` elimina el entorno completo; AWS exige confirmación explícita.
- Opciones Terraform adicionales se pasan con `TF_VARS`, por ejemplo
  `TF_VARS='-var=enable_waf=true'`.

## Gate local obligatorio

### 0. Iniciar el emulador

Con la distribución de MiniStack ubicada junto a este repositorio:

```bash
docker compose -f ../ministack/docker-compose.yml up -d
curl -fsS http://localhost:4566/_ministack/health
```

La respuesta debe indicar que MiniStack está disponible antes de ejecutar
Terraform.

### 1. Construir imágenes desde el código actual

```bash
make images ORCH_DIR=../ProjectUVG
```

Se construyen API, frontend, PDF worker y Keycloak con tags `:local`.

### 2. Crear y probar

```bash
make up ENV=local

export SADC_CLIENT_SECRET=congenia_local_sadc_secret
make smoke-integration ENV=local
unset SADC_CLIENT_SECRET
```

El gate exige:

- frontend accesible por el ALB;
- `/health/ready` con PostgreSQL, Redis y RabbitMQ disponibles;
- realm `congenia` de Keycloak;
- obtención de token, creación y activación de una sesión temporal;
- registro transaccional de una ficha y su consentimiento, incluyendo la
  verificación local de `origen_creacion` y `creado_por` en PostgreSQL;
- consumo del evento por el PDF worker y existencia del PDF resultante en S3;
- token de sesión únicamente en el fragmento `#sessionToken=...`.

### 3. Verificar destrucción reproducible

```bash
make destroy ENV=local
make plan ENV=local
```

Después del destroy, el plan debe proponer una creación limpia. Si cualquier
paso falla, no se publican commits ni imágenes.

### 4. Registrar el resultado aprobado

Con el gate verde, revisar y commitear cada repositorio independiente:

1. `ProjectUVG/CONGENIA-M1-SERVER`
2. `ProjectUVG/CONGENIA-M1`
3. `ProjectUVG/CONGENIA-M1-PDF-WORKER`
4. `ProjectUVG/CONGENIA-DB`
5. `ProjectUVG`
6. `CONGENIA-INFRA`

No construir una imagen publicable desde un árbol sucio: el tag debe señalar
al commit exacto que contiene su contenido.

## Despliegue oficial en AWS

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

Desde `ProjectUVG`:

```bash
./scripts/release-plan.sh
```

El script inspecciona los repos y muestra los comandos `docker buildx --push`;
no publica por sí solo. Revisar y ejecutar los comandos, incluida la imagen
`congenia/migrate`. Después generar el manifiesto desplegable:

```bash
./scripts/release-plan.sh --write ../CONGENIA-INFRA/envs/aws/images.tfvars
cd ../CONGENIA-INFRA
make plan ENV=aws
make create ENV=aws
```

`images.tfvars` registra el tag distinto de API, frontend, PDF worker,
Keycloak y migración. ECR es inmutable: nunca se usa `latest`.

### 4. Cargar el esquema inicial

```bash
make migrate ENV=aws
```

La tarea de una sola ejecución aplica los SQL incluidos en la imagen de
migración. Es idempotente para una base nueva; cambios futuros de esquema deben
usar migraciones incrementales.

### 5. Emitir TLS y configurar DNS

```bash
terraform -chdir=envs/aws output acm_validation_records
```

Crear el CNAME indicado en name.com y esperar que ACM quede `ISSUED`. Apuntar
`congenia.app` al DNS del ALB mediante ALIAS/ANAME y aplicar:

```bash
make create ENV=aws TF_VARS='-var=validate_certificate=true'
```

No abrir Keycloak antes de que el hostname HTTPS resuelva: el issuer del JWT
debe coincidir con la URL pública.

### 6. Abrir y validar

```bash
make open ENV=aws TF_VARS='-var=validate_certificate=true'
make smoke ENV=aws

export SADC_CLIENT_SECRET="$(aws secretsmanager get-secret-value \
  --secret-id "$(terraform -chdir=envs/aws output -raw sadc_client_secret_arn)" \
  --query SecretString --output text)"
make smoke-integration ENV=aws
unset SADC_CLIENT_SECRET
```

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

Local:

```bash
make destroy ENV=local
```

AWS oficial:

```bash
make destroy ENV=aws CONFIRM_DESTROY=destroy-congenia-aws
```

El target AWS primero lleva ECS a cero y activa temporalmente
`allow_destroy=true`; luego elimina RDS sin snapshot final, todas las versiones
del bucket, imágenes ECR, secretos y el resto del stack. Es una operación
irreversible y solo debe ejecutarse cuando la eliminación de datos esté
aprobada.

Si el estado AWS está vacío, el target termina sin crear nada. Un recurso que
exista fuera del estado nunca debe eliminarse a ciegas: primero se recupera una
versión válida del backend o se importa, se revisa el plan y recién entonces se
autoriza su destrucción.

## Riesgos conocidos

- RabbitMQ corre en Fargate sin almacenamiento persistente; un reinicio puede
  perder trabajos. Antes de mayor carga debe migrarse a SQS/Amazon MQ o a un
  patrón outbox.
- La carga SQL cubre instalaciones iniciales, no upgrades incrementales.
- La integración completa en AWS sigue siendo obligatoria aunque MiniStack
  esté verde; el emulador necesita `make reconcile` para ALB y AWS no.
- La cuenta Free Plan tiene vigencia y créditos finitos. Consultarlos antes y
  después de cada ventana de prueba con `make cost-status`.

# CONGENIA-INFRA

Infraestructura como codigo del proyecto CONGENIA. Un solo repositorio de
Terraform que describe **toda** la plataforma y se despliega igual en local
(MiniStack) que en AWS real.

> El *que* y el *como* de esta propuesta estan en [PROPUESTA.md](PROPUESTA.md).
> El diagrama de lo que quedo corriendo esta en
> [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md), y en version visual aqui:
> https://claude.ai/code/artifact/a50c18d9-0432-40bd-bed7-6027848dfef3

---

## Arranque rapido (local)

Requisitos: Docker, Terraform >= 1.6, Python 3, y MiniStack escuchando en
`http://localhost:4566`.

```bash
# 1. MiniStack (desde el repo de ministack)
docker compose up -d

# 2. Imagenes de los servicios propios de CONGENIA
make images ORCH_DIR=../ProjectUVG

# 3. Infraestructura + reconciliacion + pruebas
make up
```

`make up` encadena tres pasos:

| paso        | que hace                                                    |
|-------------|-------------------------------------------------------------|
| `apply`     | red, seguridad, datos, plataforma, servicios y ALB            |
| `reconcile` | aplica las reglas del ALB y registra las tareas ECS (*)      |
| `smoke`     | comprueba que el trafico atraviesa el ALB hasta cada servicio |

(*) Solo en local. Son dos integraciones que MiniStack no emula; en AWS real
son nativas. El detalle esta en PROPUESTA.md.

Salida esperada:

```
Smoke test contra ALB congenia-alb (Host: congenia-alb.alb.localhost)
  OK     frontend (ficha)       /                  200
  OK     api                    /v1/ping           404
  OK     keycloak               /realms/master     200
Todo el trafico atraviesa la DMZ hacia la red privada correctamente.
```

Para hablarle al stack desde la maquina:

```bash
curl -H 'Host: congenia-alb.alb.localhost' http://localhost:4566/
```

---

## Estructura

```
CONGENIA-INFRA/
├── modules/
│   ├── network/        VPC de 3 capas: edge / app / data + security groups
│   ├── data/           RDS PostgreSQL, ElastiCache Redis, bucket S3
│   ├── platform/       Cluster ECS, repos ECR, log groups, roles IAM
│   ├── ecs-service/    Un servicio del compose -> una task def + un service
│   ├── migrate/        Tarea de un solo uso que carga el esquema en RDS
│   ├── edge/           ALB, target groups, listener 80/443 y enrutamiento
│   ├── security/       WAF, VPC Flow Logs y NACLs por capa
│   └── vpn/            Tunel al dominio externo y acceso de operadores
├── envs/
│   ├── local/          MiniStack. Aplicado y probado.
│   └── aws/            AWS real. Valida; sin aplicar (genera costo).
├── docker/migrate/     Imagen con los .sql horneados (contexto de build)
├── scripts/
│   ├── reconcile-alb.sh / reconcile_alb.py   parches locales del ALB
│   ├── smoke-test.sh                          pruebas a traves del ALB
│   ├── build-migrate-image.sh                 publica la imagen de migracion
│   └── migrate.sh                             corre la carga del esquema
└── docs/ARQUITECTURA.md
```

Los dos entornos llaman **a los mismos modulos**. La unica diferencia
estructural es que `envs/local` declara `endpoints` apuntando a MiniStack y
`envs/aws` no.

---

## Comandos

```bash
make up                  # apply + reconcile + smoke
make plan                # terraform plan
make reconcile           # re-registra targets tras reiniciar una tarea
make smoke               # solo las pruebas
make destroy             # baja todo
make ENV=aws plan        # planifica contra AWS real (requiere credenciales)
```

Solo en AWS, y una vez por entorno nuevo (en local el esquema lo carga
`docker-entrypoint-initdb.d`):

```bash
make migrate-image ENV=aws   # hornea los .sql en una imagen y la sube a ECR
make migrate ENV=aws         # corre la carga del esquema y espera el resultado
```

`make migrate` es idempotente: si las tablas ya existen, no hace nada.

### Que version corre cada servicio

`envs/aws/images.tfvars` dice que imagen corre cada servicio, y `make apply`
lo toma solo si existe:

```hcl
image_tags = {
  "api"        = "1.0.0-9696cd8"
  "frontend"   = "0.0.0-f212790"
  "pdf-worker" = "1.0.0-23f94cc"
}
```

Lo genera `scripts/release-plan.sh` del repo orquestador. Los repos ECR se
crean con tags inmutables, asi que un push no puede pisar una version ya
publicada. Ver PROPUESTA.md seccion 10.

Tras reiniciar cualquier tarea ECS hay que volver a correr `make reconcile`:
la IP del contenedor cambia y el target group se queda apuntando a la vieja.

---

## Que corre despues de `make up`

| Servicio    | Recurso Terraform                | Respaldo real          |
|-------------|----------------------------------|------------------------|
| PostgreSQL  | `aws_db_instance`                | contenedor postgres:16 |
| Redis       | `aws_elasticache_cluster`        | contenedor redis:7     |
| Bucket      | `aws_s3_bucket`                  | S3 de MiniStack        |
| Keycloak    | `aws_ecs_service`                | contenedor keycloak    |
| RabbitMQ    | `aws_ecs_service`                | contenedor rabbitmq    |
| API         | `aws_ecs_service` + ruta ALB     | contenedor congenia/api |
| PDF Worker  | `aws_ecs_service`                | contenedor pdf-worker  |
| Frontend    | `aws_ecs_service` + ruta ALB     | contenedor nginx       |
| Entrada     | `aws_lb` + reglas                | plano de datos del ALB |
| WAF         | `aws_wafv2_web_acl`              | asociado al ALB        |
| Flow Logs   | `aws_flow_log`                   | CloudWatch             |
| NACLs       | `aws_network_acl` + reglas       | 3 capas, 10 reglas     |
| Endpoints   | `aws_vpc_endpoint`               | S3 + ECR + Logs + Secrets |

Comprobalo con `docker ps`: son contenedores de verdad, no metadatos.

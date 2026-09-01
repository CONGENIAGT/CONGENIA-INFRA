# =============================================================================
# CONGENIA-INFRA
# =============================================================================
ENV     ?= local
TFDIR    = envs/$(ENV)
TERRAFORM = terraform
TF_VARS ?=
LOCAL_SERVICE_NETWORK ?= congenia-local-services

# Manifiesto de versiones: dice que imagen corre cada servicio. Lo genera
# `scripts/release-plan.sh` del repo orquestador y se versiona junto al codigo.
# Si no existe, Terraform usa `var.image_tag` para todos.
VAR_FILE = $(if $(wildcard $(TFDIR)/images.tfvars),-var-file=images.tfvars,)
TF_ARGS  = $(VAR_FILE) $(TF_VARS)

.PHONY: help init plan create apply open close reconcile smoke smoke-integration \
	destroy fmt validate up images migrate migrate-image cost-status

help:
	@echo "make up        - ciclo local: create + reconcile + smoke"
	@echo "make init      - terraform init"
	@echo "make plan      - terraform plan"
	@echo "make create    - crea o actualiza la infraestructura"
	@echo "make open      - arranca los servicios oficiales (solo ENV=aws)"
	@echo "make close     - detiene las tareas sin destruir datos (solo ENV=aws)"
	@echo "make reconcile - ajusta reglas y targets del ALB (solo local)"
	@echo "make smoke     - pruebas de salud a traves del ALB"
	@echo "make smoke-integration - prueba OAuth y activacion (requiere SADC_CLIENT_SECRET)"
	@echo "make images    - construye las imagenes de CONGENIA desde los repos"
	@echo "make migrate-image - construye y publica la imagen de migracion en ECR"
	@echo "make migrate   - carga o verifica el esquema en la base"
	@echo "make destroy   - destruye el entorno; AWS exige CONFIRM_DESTROY=destroy-congenia-aws"
	@echo "make cost-status - muestra plan y creditos restantes de AWS Free Plan"

init:
	cd $(TFDIR) && $(TERRAFORM) init

plan: init
	cd $(TFDIR) && $(TERRAFORM) plan $(TF_ARGS)

apply: init
	cd $(TFDIR) && $(TERRAFORM) apply -auto-approve $(TF_ARGS)

create: apply

open: init
	@test "$(ENV)" = "aws" || (echo "open solo aplica con ENV=aws"; exit 1)
	cd $(TFDIR) && $(TERRAFORM) apply -auto-approve $(TF_ARGS) -var=enable_services=true

close: init
	@test "$(ENV)" = "aws" || (echo "close solo aplica con ENV=aws"; exit 1)
	cd $(TFDIR) && $(TERRAFORM) apply -auto-approve $(TF_ARGS) -var=enable_services=false

# Reconcilia las dos integraciones que MiniStack no ejecuta por si solo.
reconcile:
	@test "$(ENV)" = "local" || (echo "reconcile solo aplica con ENV=local"; exit 1)
	@./scripts/reconcile-alb.sh $(TFDIR)

smoke:
	@./scripts/smoke-test.sh $(TFDIR)

smoke-integration:
	@./scripts/smoke-integration.sh $(TFDIR)

# Carga del esquema en RDS. En AWS ejecuta la task definition de migracion;
# en local carga los SQL en el PostgreSQL creado por MiniStack.
migrate:
	@if [ "$(ENV)" = "local" ]; then \
		./scripts/migrate-local.sh $(TFDIR) $(ORCH_DIR); \
	elif [ "$(ENV)" = "aws" ]; then \
		./scripts/migrate.sh $(TFDIR); \
	else \
		echo "Entorno no soportado: $(ENV)" >&2; exit 1; \
	fi

migrate-image:
	@./scripts/build-migrate-image.sh $(TFDIR) $(ORCH_DIR) $(IMAGE_TAG)

up:
	@test "$(ENV)" = "local" || (echo "up es el ciclo de prueba local; para AWS usa create/open"; exit 1)
	@$(MAKE) create ENV=local TF_VARS='$(TF_VARS)'
	@$(MAKE) migrate ENV=local ORCH_DIR=$(ORCH_DIR)
	@$(MAKE) reconcile ENV=local
	@$(MAKE) smoke ENV=local

destroy:
ifeq ($(ENV),aws)
	@test "$(CONFIRM_DESTROY)" = "destroy-congenia-aws" || (echo "Confirma con CONFIRM_DESTROY=destroy-congenia-aws"; exit 1)
	@$(MAKE) init ENV=aws
	@resource_count=$$(cd $(TFDIR) && $(TERRAFORM) state list | wc -l | tr -d ' '); \
	if [ "$$resource_count" -eq 0 ]; then \
		echo "El estado AWS esta vacio; no hay recursos administrados que destruir."; \
	else \
		cd $(TFDIR) && \
		$(TERRAFORM) apply -auto-approve $(TF_ARGS) -var=enable_services=false -var=allow_destroy=true && \
		$(TERRAFORM) destroy -auto-approve $(TF_ARGS) -var=enable_services=false -var=allow_destroy=true; \
	fi
else
	@$(MAKE) init ENV=local
	cd $(TFDIR) && $(TERRAFORM) destroy -auto-approve $(TF_ARGS)
	@LOCAL_SERVICE_NETWORK=$(LOCAL_SERVICE_NETWORK) ./scripts/cleanup-local.sh
endif

fmt:
	$(TERRAFORM) fmt -recursive .

validate: init
	cd $(TFDIR) && $(TERRAFORM) validate

cost-status:
	@aws freetier get-account-plan-state --region us-east-1 \
		--query '{plan:accountPlanType,status:accountPlanStatus,creditos:accountPlanRemainingCredits,vence:accountPlanExpirationDate}'

# Construye las imagenes de los servicios propios desde los repos de codigo.
# ORCH_DIR debe apuntar al repositorio orquestador (CONGENIA-ORCH).
ORCH_DIR ?= ../ProjectUVG

# Vacio = lo deriva del commit del esquema (ver scripts/build-migrate-image.sh).
IMAGE_TAG ?=

images:
	docker build -t congenia/api:local        $(ORCH_DIR)/CONGENIA-M1-SERVER
	docker build -t congenia/pdf-worker:local $(ORCH_DIR)/CONGENIA-M1-PDF-WORKER
	docker build -t congenia/keycloak:local   $(ORCH_DIR)/keycloak
	docker build -t congenia/frontend:local   $(ORCH_DIR)/CONGENIA-M1 \
		--build-arg VITE_API_BASE_URL=http://congenia-alb.alb.localhost \
		--build-arg VITE_APP_ENV=local

# =============================================================================
# CONGENIA-INFRA
# =============================================================================
ENV     ?= aws
TFDIR    = envs/$(ENV)
TERRAFORM = terraform
TF_VARS ?=

# Manifiesto de versiones: dice que imagen corre cada servicio. Lo genera
# `scripts/release-plan.sh` del repo orquestador y se versiona junto al codigo.
# Si no existe, Terraform usa `var.image_tag` para todos.
VAR_FILE = $(if $(wildcard $(TFDIR)/images.tfvars),-var-file=images.tfvars,)
TF_ARGS  = $(VAR_FILE) $(TF_VARS)

.PHONY: help init plan create apply open close smoke smoke-integration \
	destroy nuke verify-teardown fmt validate up-aws migrate migrate-image \
	cost-status stop db-access-prepare db-access-plan db-access-up \
	db-access-status db-access-tunnel db-access-stop db-access-destroy db-access-verify test-db-access

help:
	@echo "make up-aws    - ciclo completo: create + migrate + open + smoke"
	@echo "make init      - terraform init"
	@echo "make plan      - terraform plan"
	@echo "make create    - crea o actualiza la infraestructura"
	@echo "make open      - arranca los servicios oficiales"
	@echo "make close     - detiene las tareas sin destruir datos"
	@echo "make stop      - alias de close; tambien detiene db-access"
	@echo "make db-access-prepare - importa las reglas data existentes (solo estado)"
	@echo "make db-access-{plan,up,status,tunnel,stop,destroy,verify} - acceso privado a PostgreSQL"
	@echo "make smoke     - pruebas de salud a traves del ALB"
	@echo "make smoke-integration - prueba OAuth y activacion (requiere SADC_CLIENT_SECRET)"
	@echo "make migrate-image - construye y publica la imagen de migracion en ECR"
	@echo "make migrate   - carga o verifica el esquema en la base"
	@echo "make destroy   - destruye el entorno de app; AWS exige CONFIRM_DESTROY=destroy-congenia-aws"
	@echo "make nuke      - destruccion total, incluido envs/shared (cierre de proyecto)"
	@echo "make verify-teardown - comprueba contra AWS que no quedaron recursos"
	@echo "make cost-status - muestra plan y creditos restantes de AWS Free Plan"

init:
	cd $(TFDIR) && $(TERRAFORM) init

plan: init
	cd $(TFDIR) && $(TERRAFORM) plan $(TF_ARGS)

apply: init
	cd $(TFDIR) && $(TERRAFORM) apply -auto-approve $(TF_ARGS)

create: apply

open: init
	cd $(TFDIR) && $(TERRAFORM) apply -auto-approve $(TF_ARGS) -var=enable_services=true

close: init
	@./scripts/db-access.sh stop
	cd $(TFDIR) && $(TERRAFORM) apply -auto-approve $(TF_ARGS) -var=enable_services=false

stop: close

db-access-prepare:
	@TERRAFORM='$(TERRAFORM)' ./scripts/migrate-data-sg-rules.sh $(TFDIR) --apply $(TF_ARGS)

db-access-plan db-access-up db-access-status db-access-tunnel db-access-stop db-access-verify:
	@TERRAFORM='$(TERRAFORM)' ./scripts/db-access.sh $(patsubst db-access-%,%,$@)

db-access-destroy:
	@TERRAFORM='$(TERRAFORM)' CONFIRM_DESTROY='$(CONFIRM_DESTROY)' ./scripts/db-access.sh destroy

test-db-access:
	@python3 -m unittest discover -s tests -v

smoke:
	@./scripts/smoke-test.sh $(TFDIR)

smoke-integration:
	@./scripts/smoke-integration.sh $(TFDIR)

# Carga del esquema en RDS ejecutando la task definition de migracion.
migrate:
	@./scripts/migrate.sh $(TFDIR)

# ORCH_DIR apunta al repositorio orquestador, donde vive el contexto de build
# de la imagen de migracion. Vacio en IMAGE_TAG = lo deriva del commit del
# esquema (ver scripts/build-migrate-image.sh).
ORCH_DIR  ?= ../ProjectUVG
IMAGE_TAG ?=

migrate-image:
	@./scripts/build-migrate-image.sh $(TFDIR) $(ORCH_DIR) $(IMAGE_TAG)

# Ciclo completo en AWS. Sustituye la parte 2 de docs/DEPLOY.md: con las
# imagenes ya en ECR y el DNS administrado por Terraform, no queda ningun paso
# manual entre una cuenta con la base creada y un entorno probado.
up-aws:
	@$(MAKE) create ENV=aws TF_VARS='$(TF_VARS)'
	@$(MAKE) migrate ENV=aws
	@$(MAKE) open ENV=aws TF_VARS='$(TF_VARS)'
	@$(MAKE) smoke ENV=aws


destroy:
	@test "$(CONFIRM_DESTROY)" = "destroy-congenia-aws" || (echo "Confirma con CONFIRM_DESTROY=destroy-congenia-aws"; exit 1)
	@$(MAKE) db-access-destroy CONFIRM_DESTROY=destroy-congenia-db-access
	@$(MAKE) init ENV=aws
	@state_json=$$(cd $(TFDIR) && $(TERRAFORM) show -json) || exit $$?; \
	resource_count=$$(printf '%s' "$$state_json" | jq '[.. | objects | select(.mode? == "managed" and has("address"))] | length') || exit $$?; \
	if [ "$$resource_count" -eq 0 ]; then \
		echo "El estado AWS esta vacio; no hay recursos administrados que destruir."; \
	else \
		$(MAKE) db-access-prepare ENV=aws TF_VARS='$(TF_VARS)' && \
		cd $(TFDIR) && \
		$(TERRAFORM) apply -auto-approve $(TF_ARGS) -var=enable_services=false -var=allow_destroy=true -var=manage_dns=false && \
		$(TERRAFORM) destroy -auto-approve $(TF_ARGS) -var=enable_services=false -var=allow_destroy=true -var=manage_dns=false; \
	fi

# ── Cierre de proyecto ──────────────────────────────────────────────────────
# `make destroy ENV=aws` borra todo el gasto significativo y deja en pie el
# stack compartido (imagenes, identidad de CI, zona DNS): reconstruir es un
# `make up-aws`. Ese es el ciclo normal.
#
# `make nuke` es otra cosa: destruye tambien envs/shared. Es un boton de
# emergencia para cuando el proyecto se cierra y la cuenta debe quedar sin nada
# colgando, no una forma de ahorrar (el stack compartido cuesta menos de un
# dolar al mes).
nuke:
	@test "$(CONFIRM_DESTROY)" = "destroy-congenia-todo" || ( \
		echo ""; \
		echo "  DESTRUCCION TOTAL — cierre de proyecto"; \
		echo "  ══════════════════════════════════════"; \
		echo ""; \
		echo "  Esto destruye envs/aws y DESPUES envs/shared. Ademas del stack"; \
		echo "  de aplicacion, borra de forma irreversible:"; \
		echo ""; \
		echo "    - las imagenes publicadas en ECR;"; \
		echo "    - la zona alojada de Route 53;"; \
		echo "    - el proveedor OIDC y el rol de GitHub Actions."; \
		echo ""; \
		echo "  Volver exige rehacer la parte 1 de docs/DEPLOY.md, incluida la"; \
		echo "  re-delegacion de nameservers en name.com y su propagacion."; \
		echo "  Para el apagado de rutina usa:"; \
		echo ""; \
		echo "    make destroy ENV=aws CONFIRM_DESTROY=destroy-congenia-aws"; \
		echo ""; \
		echo "  Si aun asi es lo que queres:"; \
		echo ""; \
		echo "    make nuke CONFIRM_DESTROY=destroy-congenia-todo"; \
		echo ""; \
		exit 1)
	@echo "==> 0/4 comprobando que el destroy pueda completarse"
	@$(MAKE) init ENV=aws >/dev/null
	@state_json=$$(cd envs/aws && $(TERRAFORM) show -json) || exit $$?; \
	huerfanos=$$(printf '%s' "$$state_json" | jq -r '.. | objects | select(.mode? == "managed" and .type? == "aws_ecr_repository") | .address') || exit $$?; \
	if [ -n "$$huerfanos" ]; then \
		echo ""; \
		echo "  ABORTADO — hay repositorios ECR en el estado de envs/aws:"; \
		echo ""; \
		printf '    %s\n' $$huerfanos; \
		echo ""; \
		echo "  Ya no estan en la configuracion, asi que el destroy intentaria"; \
		echo "  borrarlos, y ECR lo rechaza porque tienen imagenes y su"; \
		echo "  force_delete quedo guardado en false. El apply previo alcanzaria"; \
		echo "  a apagar los servicios y a quitar el listener HTTPS antes de"; \
		echo "  fallar, dejando el entorno a medias."; \
		echo ""; \
		echo "  Moverlos primero, sin destruirlos:"; \
		echo ""; \
		echo "    ./scripts/migrate-ecr-state.sh --aplicar"; \
		echo ""; \
		exit 1; \
	fi
	@echo "    ok: ningun recurso huerfano bloquea el destroy"
	@echo "==> 1/4 destruyendo envs/aws"
	@$(MAKE) destroy ENV=aws CONFIRM_DESTROY=destroy-congenia-aws
	@echo "==> 2/4 destruyendo envs/shared"
	@$(MAKE) init ENV=shared
	@cd envs/shared && \
		$(TERRAFORM) apply -auto-approve -var=allow_destroy=true && \
		$(TERRAFORM) destroy -auto-approve -var=allow_destroy=true
	@echo "==> 3/4 comprobando contra AWS que no quedo nada"
	@./scripts/verify-teardown.sh
	@echo "==> 4/4 perimetro fuera de Terraform"
	@./scripts/verify-teardown.sh --perimetro
	@$(MAKE) cost-status

# Le pregunta a AWS que sobrevivio, en vez de confiar en que Terraform dijo que
# termino. Util tambien despues de un `make destroy` normal, y para detectar
# recursos creados a mano durante una depuracion que nunca entraron al estado.
verify-teardown:
	@./scripts/verify-teardown.sh

fmt:
	$(TERRAFORM) fmt -recursive .

validate: init
	cd $(TFDIR) && $(TERRAFORM) validate

cost-status:
	@aws freetier get-account-plan-state --region us-east-1 \
		--query '{plan:accountPlanType,status:accountPlanStatus,creditos:accountPlanRemainingCredits,vence:accountPlanExpirationDate}'

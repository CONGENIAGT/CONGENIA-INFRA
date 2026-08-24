# =============================================================================
# CONGENIA-INFRA
# =============================================================================
ENV     ?= local
TFDIR    = envs/$(ENV)
TERRAFORM = terraform

.PHONY: help init plan apply reconcile smoke destroy fmt validate up images

help:
	@echo "make up        - apply + registro de targets + smoke test (entorno $(ENV))"
	@echo "make init      - terraform init"
	@echo "make plan      - terraform plan"
	@echo "make apply     - terraform apply"
	@echo "make reconcile - ajusta reglas y targets del ALB (solo local)"
	@echo "make smoke     - pruebas de salud a traves del ALB"
	@echo "make images    - construye las imagenes de CONGENIA desde los repos"
	@echo "make destroy   - destruye el entorno"

init:
	cd $(TFDIR) && $(TERRAFORM) init

plan: init
	cd $(TFDIR) && $(TERRAFORM) plan

apply: init
	cd $(TFDIR) && $(TERRAFORM) apply -auto-approve

# Cierra los dos gaps que MiniStack no emula (ver PROPUESTA.md).
reconcile:
	@./scripts/reconcile-alb.sh $(TFDIR)

smoke:
	@./scripts/smoke-test.sh $(TFDIR)

up: apply reconcile smoke

destroy:
	cd $(TFDIR) && $(TERRAFORM) destroy -auto-approve

fmt:
	$(TERRAFORM) fmt -recursive .

validate: init
	cd $(TFDIR) && $(TERRAFORM) validate

# Construye las imagenes de los servicios propios desde los repos de codigo.
# ORCH_DIR debe apuntar al repositorio orquestador (CONGENIA-ORCH).
ORCH_DIR ?= ../ProjectUVG

images:
	docker build -t congenia/api:local        $(ORCH_DIR)/CONGENIA-M1-SERVER
	docker build -t congenia/pdf-worker:local $(ORCH_DIR)/CONGENIA-M1-PDF-WORKER
	docker build -t congenia/frontend:local   $(ORCH_DIR)/CONGENIA-M1 \
		--build-arg VITE_API_BASE_URL=http://congenia-alb.alb.localhost \
		--build-arg VITE_APP_ENV=local

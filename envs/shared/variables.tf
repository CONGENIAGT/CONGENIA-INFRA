variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "congenia"
}

variable "github_org" {
  type    = string
  default = "CONGENIAGT"
}

variable "ci_subjects" {
  description = <<-DESC
    Sujetos OIDC que pueden publicar imagenes, en formato
    `repo:ORG/REPO:ref:refs/heads/RAMA`.

    El default cubre las ramas por defecto de cada repositorio: los servicios
    usan `main` y el orquestador `master`. Durante un rollout se agregan las
    ramas de trabajo con `-var` y se recortan al cerrar el cambio; dejarlas
    puestas daria a una rama cualquiera permiso de publicar en el registro de
    produccion.
  DESC
  type        = list(string)
  default = [
    "repo:CONGENIAGT/CONGENIA-M1:ref:refs/heads/main",
    "repo:CONGENIAGT/CONGENIA-M1-SERVER:ref:refs/heads/main",
    "repo:CONGENIAGT/CONGENIA-M1-PDF-WORKER:ref:refs/heads/main",
    "repo:CONGENIAGT/CONGENIA-ORCH:ref:refs/heads/master",
  ]
}

variable "create_oidc_provider" {
  description = <<-DESC
    El proveedor OIDC de GitHub es unico por cuenta. Poner false si la cuenta
    ya tiene uno creado por otro proyecto.
  DESC
  type        = bool
  default     = true
}

variable "manage_dns" {
  description = <<-DESC
    Crea la zona alojada de Route 53 para el dominio publico. Requiere delegar
    los nameservers en el registrador (name.com); el procedimiento esta en
    docs/DEPLOY.md, parte 1.

    Destruir la zona hace que Route 53 asigne nameservers nuevos al recrearla,
    obligando a repetir la delegacion. Por eso vive en este stack.
  DESC
  type        = bool
  default     = true
}

variable "domain_name" {
  description = "Dominio publico cuya zona administra Route 53."
  type        = string
  default     = "cogenia.app"
}

variable "retained_images" {
  description = "Imagenes que conserva la lifecycle policy por repositorio."
  type        = number
  default     = 20
}

variable "allow_destroy" {
  description = <<-DESC
    Permite destruir repositorios ECR con imagenes publicadas. Solo lo activa
    `make nuke` con confirmacion explicita.
  DESC
  type        = bool
  default     = false
}

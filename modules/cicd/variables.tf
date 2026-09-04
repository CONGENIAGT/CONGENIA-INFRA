variable "name_prefix" {
  type = string
}

variable "ci_subjects" {
  description = <<-DESC
    Sujetos OIDC autorizados a asumir el rol, en el formato
    `repo:ORG/REPO:ref:refs/heads/RAMA`. Se comparan con StringLike.

    Es variable y no una lista fija porque durante un rollout hace falta
    incluir temporalmente la rama de trabajo: si el rol solo admite `main`, el
    `assume-role` desde una rama falla con un AccessDenied poco descriptivo.
    Recortarla a las ramas por defecto es parte del cierre del cambio.
  DESC
  type        = list(string)
}

variable "ecr_repository_arns" {
  description = "Repositorios sobre los que el rol puede publicar."
  type        = list(string)
}

variable "create_oidc_provider" {
  description = <<-DESC
    El proveedor OIDC de GitHub es unico por cuenta AWS. En false, el modulo
    reutiliza el que ya exista en lugar de intentar crearlo.
  DESC
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

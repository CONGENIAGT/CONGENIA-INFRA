# =============================================================================
# Modulo: cicd
#
# Identidad de GitHub Actions dentro de la cuenta. Los workflows de cada
# repositorio de servicio asumen este rol por OIDC y publican en ECR sin que
# exista una sola llave de AWS guardada en GitHub.
#
# Vive en envs/shared y no en el stack de la aplicacion por una razon de
# dependencia circular: el pipeline publica las imagenes que el stack necesita
# para arrancar, asi que no puede depender de que ese stack exista.
# =============================================================================

# El proveedor OIDC es un singleton por cuenta: si otro proyecto ya lo creo,
# un `apply` fallaria con EntityAlreadyExists. `create_oidc_provider = false`
# permite reutilizar el existente en lugar de pelearse con el.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # Desde 2023 AWS valida el certificado de este emisor contra su propio
  # almacen de confianza e ignora la huella, pero la API sigue exigiendo el
  # campo. Se deja la huella publicada por GitHub como valor inerte.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = var.tags
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# `sub` identifica al repositorio y a la referencia que dispara el workflow.
# Se compara con StringLike para que la lista admita comodines durante el
# rollout; en operacion normal deberia contener solo ramas exactas.
#
# `aud` es obligatorio: sin esa condicion, cualquier repositorio de GitHub
# podria asumir el rol.
data "aws_iam_policy_document" "assume" {
  statement {
    sid     = "GitHubActionsPorOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.ci_subjects
    }
  }
}

resource "aws_iam_role" "ecr_push" {
  name               = "${var.name_prefix}-gha-ecr-push"
  description        = "Publicacion de imagenes desde GitHub Actions. Sin permisos de despliegue."
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = var.tags
}

# El rol publica imagenes y nada mas. No puede desplegarlas: mover una version
# a produccion sigue siendo un merge en images.tfvars y un `make open` humano.
data "aws_iam_policy_document" "ecr_push" {
  statement {
    sid       = "TokenDelRegistro"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # esta accion no admite acotarse por recurso
  }

  statement {
    sid    = "PublicarEnLosReposDelProyecto"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",

      # Lectura: el workflow consulta si el tag ya existe antes de construir,
      # y buildx baja capas previas para reutilizar cache.
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:ListImages",
    ]

    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "${var.name_prefix}-gha-ecr-push"
  role   = aws_iam_role.ecr_push.id
  policy = data.aws_iam_policy_document.ecr_push.json
}

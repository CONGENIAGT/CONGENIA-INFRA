# =============================================================================
# Politica del bucket del estado de Terraform.
#
# El bucket se crea fuera de Terraform (bootstrap, ver docs/DEPLOY.md) porque
# guarda el estado de este mismo stack. Su politica, en cambio, vive aqui para
# que no dependa de un comando manual: un apply de envs/shared la reescribe
# completa, incluida la regla de TLS que el bootstrap ya habia puesto.
#
# El estado contiene en texto plano las credenciales que genera envs/aws
# (random_password, random_id). La regla de lectura deja leer objetos solo a la
# cuenta raiz, al rol de despliegue de CI y a los ARN de state_reader_arns:
# cualquier otro usuario o rol de la cuenta queda denegado aunque una politica
# IAM le conceda s3:GetObject. Si alguien quedara fuera por error, la cuenta
# raiz siempre puede borrar o corregir la politica del bucket.
# =============================================================================

locals {
  state_bucket_arn = "arn:aws:s3:::${var.state_bucket_name}"

  state_readers = concat(
    ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root", aws_iam_role.deploy.arn],
    var.state_reader_arns,
  )
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.state_bucket_arn, "${local.state_bucket_arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyStateReadOutsideOperators"
    effect    = "Deny"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${local.state_bucket_arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = local.state_readers
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = var.state_bucket_name
  policy = data.aws_iam_policy_document.state_bucket.json
}

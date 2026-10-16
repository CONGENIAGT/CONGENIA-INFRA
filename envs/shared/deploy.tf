# Identidad separada del publicador: solo INFRA/master puede desplegar.
locals {
  deploy_prefix = "${var.name_prefix}-prod"
  account_arn   = "${var.region}:${data.aws_caller_identity.current.account_id}"
  deploy_families = [for service in ["api", "frontend", "pdf-worker", "keycloak", "cie10", "migrate"] :
    "arn:aws:ecs:${local.account_arn}:task-definition/${local.deploy_prefix}-${service}:*"
  ]
}

data "aws_iam_policy_document" "deploy_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.cicd.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:CONGENIAGT@271886543/CONGENIA-INFRA@1345480919:ref:refs/heads/master"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.name_prefix}-gha-deploy"
  assume_role_policy   = data.aws_iam_policy_document.deploy_assume.json
  max_session_duration = 3600
  tags                 = local.tags
}

resource "aws_iam_role_policy" "deploy_read" {
  name = "terraform-release-read"
  role = aws_iam_role.deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:Describe*", "ecs:Describe*", "ecs:List*", "elasticloadbalancing:Describe*",
          "rds:Describe*", "rds:ListTagsForResource", "elasticache:Describe*", "elasticache:ListTagsForResource",
          "acm:DescribeCertificate", "acm:ListTagsForCertificate", "route53:Get*", "route53:List*",
          "servicediscovery:Get*", "servicediscovery:List*", "logs:Describe*", "logs:ListTagsForResource", "logs:ListTagsLogGroup",
          "scheduler:GetSchedule", "scheduler:ListTagsForResource", "sts:GetCallerIdentity"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListRoleTags"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.deploy_prefix}-*"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue", "secretsmanager:GetResourcePolicy"]
        Resource = "arn:aws:secretsmanager:${local.account_arn}:secret:${var.name_prefix}/prod/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:DescribeRepositories", "ecr:DescribeImages", "ecr:ListTagsForResource"]
        Resource = "arn:aws:ecr:${local.account_arn}:repository/${var.name_prefix}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetBucket*", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration", "s3:GetAccelerateConfiguration", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::${local.deploy_prefix}-docs", "arn:aws:s3:::congenia-tfstate"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration"]
        Resource = "arn:aws:s3:::${local.deploy_prefix}-docs"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = ["arn:aws:s3:::congenia-tfstate/congenia/aws/terraform.tfstate", "arn:aws:s3:::congenia-tfstate/congenia/aws/terraform.tfstate.tflock"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:DeleteObject"]
        Resource = "arn:aws:s3:::congenia-tfstate/congenia/aws/terraform.tfstate.tflock"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:GetLogEvents"]
        Resource = "arn:aws:logs:${local.account_arn}:log-group:/ecs/${local.deploy_prefix}/*:*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "deploy_write" {
  name = "ecs-release-write"
  role = aws_iam_role.deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecs:RegisterTaskDefinition", "ecs:TagResource"]
        Resource = local.deploy_families
      },
      {
        # Esta API no admite restringir Resource a una familia.
        Effect   = "Allow"
        Action   = ["ecs:DeregisterTaskDefinition"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:UpdateService"]
        Resource = [for service in ["api", "frontend", "pdf-worker", "keycloak"] : "arn:aws:ecs:${local.account_arn}:service/${local.deploy_prefix}-cluster/${local.deploy_prefix}-${service}"]
      },
      {
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = "arn:aws:ecs:${local.account_arn}:task-definition/${local.deploy_prefix}-migrate:*"
        Condition = {
          ArnEquals = { "ecs:cluster" = "arn:aws:ecs:${local.account_arn}:cluster/${local.deploy_prefix}-cluster" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [for role in ["ecs-execution", "ecs-task"] : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.deploy_prefix}-${role}"]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["scheduler:UpdateSchedule"]
        Resource = "arn:aws:scheduler:${local.account_arn}:schedule/default/${local.deploy_prefix}-cie10-monthly"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.deploy_prefix}-cie10-scheduler"
        Condition = {
          StringEquals = { "iam:PassedToService" = "scheduler.amazonaws.com" }
        }
      }
    ]
  })
}

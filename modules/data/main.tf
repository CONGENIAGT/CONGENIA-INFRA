# =============================================================================
# Modulo: data
# Persistencia gestionada. Sustituye tres contenedores del docker-compose:
#   postgres  -> RDS PostgreSQL
#   redis     -> ElastiCache Redis
#   seaweedfs -> S3  (la aplicacion ya habla protocolo S3 via S3_ENDPOINT)
# =============================================================================

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db-subnets"
  subnet_ids = var.data_subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-db-subnets" })
}

resource "aws_db_instance" "postgres" {
  identifier     = "${var.name_prefix}-pg"
  engine         = "postgres"
  engine_version = var.postgres_version
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.data_sg_id]

  multi_az                  = var.multi_az
  publicly_accessible       = false
  backup_retention_period   = var.db_backup_retention_days
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.allow_destroy
  final_snapshot_identifier = var.allow_destroy ? null : "${var.name_prefix}-pg-final"

  tags = merge(var.tags, { Name = "${var.name_prefix}-pg" })
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name_prefix}-cache-subnets"
  subnet_ids = var.data_subnet_ids
}

# `port` se deja sin declarar a proposito: el valor por defecto del motor ya es
# el correcto, y fijarlo explicitamente ha causado drift y recreacion del
# cluster en cada apply.
resource "aws_elasticache_cluster" "redis" {
  count = var.redis_transit_encryption_enabled || var.redis_at_rest_encryption_enabled || var.redis_auth_token != null ? 0 : 1

  cluster_id        = "${var.name_prefix}-redis"
  engine            = "redis"
  engine_version    = var.redis_version
  node_type         = var.redis_node_type
  num_cache_nodes   = 1
  subnet_group_name = aws_elasticache_subnet_group.this.name

  # `port` se deja sin declarar a proposito: el valor por defecto del motor ya
  # es el correcto, y fijarlo explicitamente ha causado drift y recreacion del
  # cluster en cada apply.
  security_group_ids = [var.data_sg_id]

  tags = merge(var.tags, { Name = "${var.name_prefix}-redis" })
}

resource "aws_elasticache_replication_group" "redis" {
  count = var.redis_transit_encryption_enabled || var.redis_at_rest_encryption_enabled || var.redis_auth_token != null ? 1 : 0

  replication_group_id = "${var.name_prefix}-redis"
  description          = "Redis de sesiones temporales de ${var.name_prefix}"
  engine               = "redis"
  engine_version       = var.redis_version
  node_type            = var.redis_node_type
  num_cache_clusters   = 1
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [var.data_sg_id]

  transit_encryption_enabled = var.redis_transit_encryption_enabled
  at_rest_encryption_enabled = var.redis_at_rest_encryption_enabled
  auth_token                 = var.redis_auth_token
  automatic_failover_enabled = false
  snapshot_retention_limit   = var.redis_snapshot_retention_days

  tags = merge(var.tags, { Name = "${var.name_prefix}-redis" })
}

resource "aws_s3_bucket" "docs" {
  bucket = var.docs_bucket_name

  # Con versionado activo, vaciar el bucket no basta para destruirlo: quedan
  # las versiones y los marcadores de borrado. `force_destroy` las borra todas,
  # por eso solo se enciende durante un destroy confirmado.
  force_destroy = var.allow_destroy

  tags = merge(var.tags, { Name = var.docs_bucket_name })
}

resource "aws_s3_bucket_public_access_block" "docs" {
  bucket = aws_s3_bucket.docs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "docs" {
  bucket = aws_s3_bucket.docs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "docs" {
  bucket = aws_s3_bucket.docs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "docs" {
  count  = length(var.docs_cors_allowed_origins) > 0 ? 1 : 0
  bucket = aws_s3_bucket.docs.id

  cors_rule {
    allowed_headers = ["Content-Type", "x-amz-*"]
    allowed_methods = ["PUT"]
    allowed_origins = var.docs_cors_allowed_origins
    expose_headers  = ["ETag"]
    max_age_seconds = 600
  }
}

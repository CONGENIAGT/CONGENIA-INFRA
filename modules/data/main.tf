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

  multi_az            = var.multi_az
  publicly_accessible = false
  skip_final_snapshot = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-pg" })
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name_prefix}-cache-subnets"
  subnet_ids = var.data_subnet_ids
}

# `port` se deja sin declarar a proposito: MiniStack responde el puerto
# publicado en el host (16379+) en lugar del puerto del cluster, y fijarlo a
# 6379 hace que Terraform vea drift y recree el cluster en cada apply.
resource "aws_elasticache_cluster" "redis" {
  cluster_id        = "${var.name_prefix}-redis"
  engine            = "redis"
  engine_version    = var.redis_version
  node_type         = var.redis_node_type
  num_cache_nodes   = 1
  subnet_group_name = aws_elasticache_subnet_group.this.name

  # `port` se deja sin declarar a proposito: MiniStack responde el puerto
  # publicado en el host (16379+) en lugar del puerto del cluster. Fijarlo a
  # 6379 hace que Terraform vea drift y recree el cluster en cada apply.
  security_group_ids = [var.data_sg_id]

  tags = merge(var.tags, { Name = "${var.name_prefix}-redis" })
}

resource "aws_s3_bucket" "docs" {
  bucket = var.docs_bucket_name

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

output "db_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "db_address" {
  value = aws_db_instance.postgres.address
}

output "db_port" {
  value = aws_db_instance.postgres.port
}

output "db_name" {
  value = var.db_name
}

output "redis_address" {
  value = coalesce(
    try(aws_elasticache_replication_group.redis[0].primary_endpoint_address, null),
    try(aws_elasticache_cluster.redis[0].cache_nodes[0].address, null)
  )
}

output "redis_port" {
  value = coalesce(
    try(aws_elasticache_replication_group.redis[0].port, null),
    try(aws_elasticache_cluster.redis[0].cache_nodes[0].port, null)
  )
}

output "docs_bucket" {
  value = aws_s3_bucket.docs.id
}

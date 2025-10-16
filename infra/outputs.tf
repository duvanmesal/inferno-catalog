output "catalog_api_url" {
  value = aws_apigatewayv2_stage.stage.invoke_url
}

output "redis_endpoint" {
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "bucket_name" {
  value = aws_s3_bucket.catalog.bucket
}

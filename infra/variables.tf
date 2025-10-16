variable "aws_region"{ 
    type = string
    default = "us-east-1" 
}
variable "name_prefix"     {
    type = string
    default = "ib-dev" 
}
variable "redis_node_type" { 
    type = string
    default = "cache.t4g.small" 
}

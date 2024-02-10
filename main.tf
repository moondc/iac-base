data "aws_caller_identity" "current" {}

locals {
  domain = var.hosted_zone
}

// Hosted Zone

data "aws_route53_zone" "zone" {
    name = local.domain
}

// VPC

resource "aws_vpc" "main" {
    cidr_block = "10.0.0.0/16"
}

// Internet Gateway

resource "aws_internet_gateway" "gateway"{
    vpc_id = aws_vpc.main.id
    tags = {
      Name = "main"
    }
}

resource "aws_route_table" "public_route_table" {
    vpc_id = aws_vpc.main.id

    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.gateway.id
    }

    tags = { 
        Name = "public_route_table"
    }
}

resource "aws_route_table" "private_route_table" {
    vpc_id = aws_vpc.main.id

    route {
        cidr_block = "0.0.0.0/0"
        nat_gateway_id =  aws_nat_gateway.nat_gateway.id
    }

    tags = { 
        Name = "private_route_table"
    }
}

resource "aws_nat_gateway" "nat_gateway"{
    subnet_id = aws_subnet.public.id
    allocation_id = aws_eip.eip.id
}

resource "aws_eip" "eip" {
    domain = "vpc"
}


resource "aws_route_table_association" "rt" {
    route_table_id = aws_route_table.public_route_table.id
    subnet_id = aws_subnet.public.id
}

resource "aws_route_table_association" "private_route_table" {
    route_table_id = aws_route_table.private_route_table.id
    subnet_id = aws_subnet.private.id
}



// Subnets

resource "aws_subnet" "private" {
    vpc_id = aws_vpc.main.id
    cidr_block = cidrsubnet(aws_vpc.main.cidr_block,8,0)
    tags = {
      "Name" = "private"
    }
}

resource "aws_subnet" "public" {
    vpc_id = aws_vpc.main.id
    cidr_block = cidrsubnet(aws_vpc.main.cidr_block,8,100)
    tags = {
      "Name" = "public"
    }
}

// ECS Cluster

resource "aws_iam_role" "ecs_task_execution_role" {
    name = "${var.cluster_name}_ECS_role"
    assume_role_policy = <<POLICY
{
    "Version":"2012-10-17",
    "Statement":[{
        "Effect":"Allow",
        "Principal":{
            "Service":[
                "ecs.amazonaws.com",
                "ecs-tasks.amazonaws.com"
            ]
        },
        "Action":"sts:AssumeRole"
    }]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "ECSClusterRole-AmazonECSTaskExecutionRolePolicy" {
    policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    role       = aws_iam_role.ecs_task_execution_role.name
}

resource "aws_ecs_cluster" "cluster" {
    name = var.cluster_name
}

// API Gateway

resource "aws_api_gateway_rest_api" "api" {
    name = var.api_name
    description = "generic empty api gateway"

    endpoint_configuration {
        types = ["REGIONAL"]
    }
}

resource "aws_api_gateway_domain_name" "api_gateway_domain" {
    domain_name = local.domain
    security_policy = "TLS_1_2"

    regional_certificate_arn = aws_acm_certificate.cert.arn
    endpoint_configuration {
      types = ["REGIONAL"]
    }
}
resource "aws_api_gateway_base_path_mapping" "base_path" {
    api_id = aws_api_gateway_rest_api.api.id
    stage_name = aws_api_gateway_deployment.deployment.stage_name
    domain_name = aws_api_gateway_domain_name.api_gateway_domain.domain_name
}

resource "aws_api_gateway_resource" "pathRoot" {
    rest_api_id = aws_api_gateway_rest_api.api.id
    parent_id = aws_api_gateway_rest_api.api.root_resource_id
    path_part = "apiStatus"
}

resource "aws_api_gateway_method" "methodRoot" {
    rest_api_id = aws_api_gateway_rest_api.api.id
    resource_id = aws_api_gateway_resource.pathRoot.id
    http_method = "GET"
    authorization = "NONE"
}

resource "aws_api_gateway_integration" "integrationRoot" {
    rest_api_id = aws_api_gateway_rest_api.api.id
    resource_id = aws_api_gateway_resource.pathRoot.id
    http_method = aws_api_gateway_method.methodRoot.http_method
    type        = "MOCK"
    request_templates = {
        "application/json" = <<EOF
{
    "statusCode":200
}
EOF
    }
}

resource "aws_api_gateway_method_response" "two_hundred" {
    rest_api_id = aws_api_gateway_rest_api.api.id
    resource_id = aws_api_gateway_resource.pathRoot.id
    http_method = aws_api_gateway_method.methodRoot.http_method
    status_code = "200"
}

resource "aws_api_gateway_integration_response" "mock_response" {
    rest_api_id = aws_api_gateway_rest_api.api.id
    resource_id = aws_api_gateway_resource.pathRoot.id
    http_method = aws_api_gateway_method.methodRoot.http_method
    status_code = aws_api_gateway_method_response.two_hundred.status_code
    response_templates = {
        "${var.api_content_type}" = var.api_content
    }
}

resource "aws_api_gateway_deployment" "deployment" {
    depends_on = [ aws_api_gateway_integration.integrationRoot, aws_api_gateway_method.methodRoot ]
    rest_api_id = aws_api_gateway_rest_api.api.id
    stage_name = "api"
    variables = {
      deployed_at = timestamp()
    }

    lifecycle {
        create_before_destroy = true
    }
}

// Api Gateway ACM
resource "aws_route53_record" "domain" {
    name = local.domain
    type = "A"
    zone_id = data.aws_route53_zone.zone.id

    alias {
        name    = aws_api_gateway_domain_name.api_gateway_domain.regional_domain_name
        zone_id = aws_api_gateway_domain_name.api_gateway_domain.regional_zone_id
        evaluate_target_health = false
    }
}

resource "aws_acm_certificate" "cert"{
    domain_name = local.domain
    subject_alternative_names = [local.domain]
    validation_method = "DNS"
    lifecycle {
      create_before_destroy = true
    }
}

resource "aws_route53_record" "validation" {
    zone_id = data.aws_route53_zone.zone.zone_id
    name = element(aws_acm_certificate.cert.domain_validation_options.*.resource_record_name,0)
    type = element(aws_acm_certificate.cert.domain_validation_options.*.resource_record_type,0)
    records = [element(aws_acm_certificate.cert.domain_validation_options.*.resource_record_value,0)]
    ttl = 60
}

resource "aws_acm_certificate_validation" "cert" {
    certificate_arn = aws_acm_certificate.cert.arn
    validation_record_fqdns = aws_route53_record.validation.*.fqdn
}

// ECR

resource "aws_ecr_repository" "ecr" {
    name = var.ecr_repo
    force_delete = true
}

resource "aws_ecr_lifecycle_policy" "ecr_policy"{
    repository = aws_ecr_repository.ecr.name
    policy = <<EOF
{
"rules" : [{
    "rulePriority":1,
    "description":"there can be only 1",
    "selection":{
        "tagStatus": "any",
        "countType":"imageCountMoreThan",
        "countNumber":1
    },
    "action":{
        "type":"expire"
    }
}]
}
EOF
}
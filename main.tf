#------------------------------------------------------------------------------
# AWS Cloudwatch Logs
#------------------------------------------------------------------------------
module aws_cw_logs {
  source  = "cn-terraform/cloudwatch-logs/aws"
  version = "1.0.6"
  # source  = "../terraform-aws-cloudwatch-logs"

  logs_path = "/ecs/service/${var.name_preffix}-jenkins-master"
}

#------------------------------------------------------------------------------
# Locals
#------------------------------------------------------------------------------
locals {
  container_name = "${var.name_preffix}-jenkins"
  healthcheck = {
    command     = [ "CMD-SHELL", "curl -f http://localhost:8080 || exit 1" ]
    retries     = 5
    timeout     = 5
    interval    = 30
    startPeriod = 120
  }
  td_port_mappings = [
    {
      containerPort = 8080
      hostPort      = 8080
      protocol      = "tcp"
    },
    {
      containerPort = 50000
      hostPort      = 50000
      protocol      = "tcp"
    }
  ]
  service_http_ports  = [8080, 50000]
  service_https_ports = [443]
}

#------------------------------------------------------------------------------
# ECS Cluster
#------------------------------------------------------------------------------
module ecs-cluster {
  source  = "cn-terraform/ecs-cluster/aws"
  version = "1.0.5"
  # source  = "../terraform-aws-ecs-cluster"

  name    = "${var.name_preffix}-jenkins"
}

#------------------------------------------------------------------------------
# EFS
#------------------------------------------------------------------------------
resource "aws_efs_file_system" "jenkins_data" {
  creation_token = "${var.name_preffix}-jenkins-efs"
  tags = {
    Name = "${var.name_preffix}-jenkins-efs"
  }
}

resource "aws_security_group" "jenkins_data_allow_nfs_access" {
  name        = "${var.name_preffix}-jenkins-efs-allow-nfs"
  description = "Allow NFS inbound traffic to EFS"
  vpc_id      = var.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "${var.name_preffix}-jenkins-efs-allow-nfs"
  }
}

data "aws_subnet" "private_subnets" {
  count = length(var.private_subnets_ids)
  id    = element(var.private_subnets_ids, count.index)
}

resource "aws_security_group_rule" "jenkins_data_allow_nfs_access_rule" {
  security_group_id        = aws_security_group.jenkins_data_allow_nfs_access.id
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = module.ecs-fargate-service.ecs_tasks_sg_id
}

resource "aws_efs_mount_target" "jenkins_data_mount_targets" {
  count           = length(var.private_subnets_ids)
  file_system_id  = aws_efs_file_system.jenkins_data.id
  subnet_id       = element(var.private_subnets_ids, count.index)
  security_groups = [ aws_security_group.jenkins_data_allow_nfs_access.id ]
}

resource "aws_efs_access_point" "jenkins_data_access_point" {
  file_system_id = aws_efs_file_system.jenkins_data.id
  posix_user {
    gid = 1000
    uid = 1000
  }
  root_directory { 
    path = "/var/jenkins_home"
    creation_info {
      owner_gid = 1000
      owner_uid = 1000
      permissions = 755
    }
  }
}

#------------------------------------------------------------------------------
# Role for EFS
#------------------------------------------------------------------------------
resource "aws_iam_role" "ecs_task_role" {
  name = "${var.name_preffix}-ecs-task-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_role_assume_policy.json

  tags = {
    Terraform = "true"
  }
}

data "aws_iam_policy_document" "ecs_task_role_assume_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "ecs_task_exec_policy" {
  name        = "${var.name_preffix}-ecs-task-exec-policy"
  policy      = data.aws_iam_policy_document.ecs_task_exec_policy_document.json
}

data "aws_iam_policy_document" "ecs_task_exec_policy_document" {
  statement {
    effect = "Allow"

    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite"
    ]

    resources = [
      aws_efs_file_system.jenkins_data.arn
    ]

    condition {
      test     = "StringLike"
      variable = "elasticfilesystem:AccessPointArn"

      values = [
        aws_efs_access_point.jenkins_data_access_point.arn
      ]
    }
  }

  statement {
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:ListSecrets"
    ]

    resources = ["*"]
  }


  statement {
    effect = "Allow"

    actions = [
      "ec2:CancelSpotFleetRequests",
      "ec2:CancelSpotInstanceRequests",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeKeyPairs",
      "ec2:DescribeRegions",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotInstanceRequests",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "ec2:GetConsoleOutput",
      "ec2:GetPasswordData",
      "ec2:RequestSpotInstances",
      "ec2:RunInstances",
      "ec2:Region",
      "ec2:ResourceTag",
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
      "iam:ListInstanceProfilesForRole",
      "iam:PassRole"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy_attachment" "ecs_task_exec_policy_attachment" {
  name       = "${var.name_preffix}-ecs-task-exec-policy-attachment"
  roles      = [aws_iam_role.ecs_task_role.name]
  policy_arn = aws_iam_policy.ecs_task_exec_policy.arn
}


#------------------------------------------------------------------------------
# ECS Task Definition
#------------------------------------------------------------------------------
module "td" {
  source  = "cn-terraform/ecs-fargate-task-definition/aws"
  version = "1.0.12"
  #source  = "../terraform-aws-ecs-fargate-task-definition"

  name_preffix      = "${var.name_preffix}-jenkins"
  container_name    = local.container_name
  container_image   = "cnservices/jenkins-master"
  container_cpu     = 2048 # 2 vCPU - https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html#fargate-task-defs
  container_memory  = 4096 # 4 GB  - https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html#fargate-task-defs
  port_mappings     = local.td_port_mappings
  healthcheck       = local.healthcheck
  task_role_arn     = aws_iam_role.ecs_task_role.arn
  start_timeout     = 120
  stop_timeout      = 120
  command           = ["--sessionTimeout=180"]
  environment = [{
    name  = "JAVA_OPTS",
    value = "-Djenkins.ec2.bootstrapAuthSleepMs=120000"}
  ]
  log_configuration = {
    logDriver = "awslogs"
    options = {
      "awslogs-region"        = var.region
      "awslogs-group"         = module.aws_cw_logs.logs_path
      "awslogs-stream-prefix" = "ecs"
    }
    secretOptions = null
  }
  volumes = [{
    name      = "jenkins_efs"
    host_path = null
    docker_volume_configuration = []

    efs_volume_configuration = [{
      file_system_id = aws_efs_file_system.jenkins_data.id
      root_directory = "/var/jenkins_home"
    }]
  }]

  mount_points = [
    {
      sourceVolume  = "jenkins_efs"
      containerPath = "/var/jenkins_home"
    }
  ]
}

#------------------------------------------------------------------------------
# AWS LOAD BALANCER
#------------------------------------------------------------------------------
module "ecs-alb" {
  source  = "cn-terraform/ecs-alb/aws"
  version = "1.0.2"
  # source  = "../terraform-aws-ecs-alb"

  name_preffix    = "${var.name_preffix}-jenkins"
  vpc_id          = var.vpc_id
  private_subnets = var.private_subnets_ids
  public_subnets  = var.public_subnets_ids
  http_ports      = local.service_http_ports
  https_ports     = local.service_https_ports

  target_group_health_check_unhealthy_threshold = 10
}

#------------------------------------------------------------------------------
# ECS Service
#------------------------------------------------------------------------------
module ecs-fargate-service {
  source  = "cn-terraform/ecs-fargate-service/aws"
  version = "2.0.4"
  # source  = "../terraform-aws-ecs-fargate-service"

  name_preffix                      = "${var.name_preffix}-jenkins"
  vpc_id                            = var.vpc_id
  ecs_cluster_arn                   = module.ecs-cluster.aws_ecs_cluster_cluster_arn
  health_check_grace_period_seconds = 120
  task_definition_arn               = module.td.aws_ecs_task_definition_td_arn
  public_subnets                    = var.public_subnets_ids
  private_subnets                   = var.private_subnets_ids
  container_name                    = local.container_name
  ecs_cluster_name                  = module.ecs-cluster.aws_ecs_cluster_cluster_name
  lb_arn                            = module.ecs-alb.aws_lb_lb_arn
  lb_http_tgs_arns                  = module.ecs-alb.lb_http_tgs_arns
  lb_https_tgs_arns                 = module.ecs-alb.lb_https_tgs_arns
  lb_http_listeners_arns            = module.ecs-alb.lb_http_listeners_arns
  lb_https_listeners_arns           = module.ecs-alb.lb_https_listeners_arns
  load_balancer_sg_id               = module.ecs-alb.aws_security_group_lb_access_sg_id
}

#------------------------------------------------------------------------------
# SG for agents
#------------------------------------------------------------------------------
resource "aws_security_group" "jenkins_agents_allow_ssh_access" {
  name        = "${var.name_preffix}-jenkins-agents-allow-ssh"
  description = "Allow SSH inbound traffic to agents"
  vpc_id      = var.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "${var.name_preffix}-jenkins-agents-allow-ssh"
  }
}

resource "aws_security_group_rule" "jenkins_agents_allow_ssh_access_rule" {
  security_group_id        = aws_security_group.jenkins_agents_allow_ssh_access.id
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  source_security_group_id = module.ecs-fargate-service.ecs_tasks_sg_id
}

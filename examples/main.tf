provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_availability_zones" "available" {}

locals {
  name            = "example"
  region          = "us-west-2"
  cluster_version = "1.27"
  eks_auth        = "IRSA" # IRSA (IAM roles for services accounts) or EKSPI (EKS pod identities); use IRSA, EKSPI not working yet

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  pause_container_account_id = {
    aws-iso = "725322719131"
  }

  ssm_agent = {
    aws     = "https://s3.us-east-1.amazonaws.com/amazon-ssm-us-east-1/latest/linux_amd64/amazon-ssm-agent.rpm"
    aws-iso = "https://s3.us-iso-east-1.c2s.ic.gov/amazon-ssm-us-iso-east-1/latest/linux_amd64/amazon-ssm-agent.rpm"
  }
  tags = {
    GithubRepo = "github.com/aws-samples/eks-node-group-warm-pool"
  }
}

################################################################################
# Cluster
################################################################################

module "eks" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks.git?ref=dfed830957079301b879814e87608728576dd168"

  cluster_name                   = local.name
  cluster_version                = local.cluster_version
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  create_aws_auth_configmap               = true
  manage_aws_auth_configmap               = true
  aws_auth_node_iam_role_arns_non_windows = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}"]

  tags = local.tags
}

################################################################################
# Self-managed node group
################################################################################

module "smng" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks.git//modules/self-managed-node-group?ref=dfed830957079301b879814e87608728576dd168"
  count  = 0

  cluster_version                   = local.cluster_version
  cluster_name                      = local.name
  cluster_primary_security_group_id = module.eks.cluster_primary_security_group_id

  name            = local.name
  use_name_prefix = false

  subnet_ids = module.vpc.private_subnets

  min_size     = 1
  max_size     = 7
  desired_size = 2

  ami_id        = data.aws_ami.eks_default.id
  instance_type = "t3.small"
  key_name      = "jeb-kp-usw2"

  launch_template_name            = local.name
  launch_template_use_name_prefix = false
  launch_template_description     = "Self managed node group example launch template"

  enable_monitoring = false

  block_device_mappings = {
    xvda = {
      device_name = "/dev/xvda"
      ebs = {
        volume_size           = 75
        volume_type           = "gp3"
        iops                  = 3000
        throughput            = 150
        delete_on_termination = true
      }
    }
  }

  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  iam_role_name            = local.name
  iam_role_use_name_prefix = false
  iam_role_description     = "Self managed node group complete example role"
  iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
    CloudWatchAgentServerPolicy  = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
    NodeAdditional               = aws_iam_policy.node_additional.arn
  }

  autoscaling_group_tags = {
    "k8s.io/cluster-autoscaler/enabled" : true,
    "k8s.io/cluster-autoscaler/${local.name}" : "owned",
  }

  warm_pool = {
    pool_state                  = "Stopped"
    min_size                    = 2
    max_group_prepared_capacity = 6
  }

  initial_lifecycle_hooks = [
    {
      lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
      name                 = "finish_user_data"
    },
  ]

  user_data_template_path = local_file.user_data.filename

  tags = {
    "InWarmPool" = "unknown"
  }
}

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git?ref=bf9a89bf447a9c866dc0d30486aec5a24dbe2631"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k + 3)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]


  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

module "vpc_endpoints" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git//modules/vpc-endpoints?ref=bf9a89bf447a9c866dc0d30486aec5a24dbe2631"

  vpc_id = module.vpc.vpc_id

  # Security group
  create_security_group      = true
  security_group_name_prefix = "${local.name}-vpc-endpoints-"
  security_group_description = "VPC endpoint security group"
  security_group_rules = {
    ingress_https = {
      description = "HTTPS from VPC"
      cidr_blocks = [module.vpc.vpc_cidr_block]
    }
  }

  endpoints = merge({
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
      tags = {
        Name = "${local.name}-s3"
      }
    }
    },
    { for service in toset(["autoscaling", "ecr.api", "ecr.dkr", "ec2", "ec2messages", "sts"]) :
      replace(service, ".", "_") =>
      {
        service             = service
        subnet_ids          = module.vpc.private_subnets
        private_dns_enabled = true
        tags                = { Name = "${local.name}-${service}" }
      }
  })

  tags = local.tags
}

data "aws_ami" "eks_default" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amazon-eks-node-${local.cluster_version}-v*"]
  }
}

locals {
  template_vars = {
    cluster_name                           = module.eks.cluster_name
    cluster_endpoint                       = module.eks.cluster_endpoint
    cluster_certificate_authority          = module.eks.cluster_certificate_authority_data
    outbound_proxy_url                     = ""
    no_proxy_endpoints                     = join(",", [for k, v in module.vpc_endpoints.endpoints : v.service_name])
    pause_container_account_id             = data.aws_partition.current.partition == "aws" ? "aws" : lookup(local.pause_container_account_id, data.aws_partition.current.partition)
    amazon_ssm_agent_url                   = lookup(local.ssm_agent, data.aws_partition.current.partition)
    kubelet_extra_args                     = ""
    enable_cloudwatch_agent                = false
    cloudwatch_agent_config_parameter_name = ""
  }

}

data "template_cloudinit_config" "node" {
  gzip          = false
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content      = file("../user_data/cloud-init.tftpl")
  }
  part {
    content_type = "text/x-shellscript"
    content      = templatefile("../user_data/node-config.tftpl", local.template_vars)
  }

}

resource "local_file" "user_data" {
  content  = data.template_cloudinit_config.node.rendered
  filename = "../user_data/user-data"
}

locals {
  policy_vars = {
    Region       = local.region,
    Account      = data.aws_caller_identity.current.account_id
    Partition    = data.aws_partition.current.partition
    ClusterName  = module.eks.cluster_name
    UrlSuffix    = data.aws_partition.current.dns_suffix
    OidcProvider = module.eks.oidc_provider
  }

}

resource "aws_iam_policy" "node_additional" {
  name        = "${local.name}NodeAdditional"
  description = "Additional policy to enable warm pools"
  policy      = templatefile("../policies/NodeAdditional.json", local.policy_vars)
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "${local.name}ClusterAutoscaler"
  description = "Additional policy to enable the cluster autoscaler"
  policy      = templatefile("../policies/ClusterAutoscaler.json", local.policy_vars)
}

locals {
  trust_policy = local.eks_auth == "IRSA" ? "../policies/ClusterAutoscalerOidcTrust.json" : "../policies/EksPodIdentities.json"
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${local.name}ClusterAutoscaler"
  description        = "Additional role to enable the cluster autoscaler"
  assume_role_policy = templatefile(local.trust_policy, local.policy_vars)
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

data "aws_eks_addon_version" "eks_pod_identities" {
  addon_name         = "eks-pod-identity-agent"
  kubernetes_version = local.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "eks_pod_identities" {
  count = local.eks_auth == "EKSPI" ? 1 : 0

  cluster_name  = module.eks.cluster_name
  addon_name    = "eks-pod-identity-agent"
  addon_version = data.aws_eks_addon_version.eks_pod_identities.version
}

locals {
  cluster_autoscaler_values = {
    cluster_autoscaler_helm_repository_uri  = "https://kubernetes.github.io/autoscaler"
    cluster_autoscaler_image_repository_uri = "registry.k8s.io/autoscaling/cluster-autoscaler"
    cluster_autoscaler_image_tag            = "v1.27.5"
    cluster_name                            = module.eks.cluster_name
    cluster_autoscaler_role_arn             = aws_iam_role.cluster_autoscaler.arn
    region                                  = local.region
  }
}

resource "local_file" "cluster_autoscaler_helm_cmds" {
  content  = templatefile("../helm/install_cluster_autoscaler.tftpl", local.cluster_autoscaler_values)
  filename = "../helm/install_cluster_autoscaler.sh"
}

output "configure_kubectl" {
  description = "Run the following command to update your kubeconfig. You must be using the same AWS credentials that were used to create the cluster."
  value       = "aws eks update-kubeconfig --region ${local.region} --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}"
}

output "add_eks_pod_identity_agent" {
  description = "Run the following command to deploy the EKS pod identity agent"
  value       = local.eks_auth == "EKSPI" ? "aws eks create-addon --region ${local.region} --cluster-name ${module.eks.cluster_name} --addon-name eks-pod-identity-agent --addon-version v1.0.0-eksbuild.1" : null
}

output "create_pod_identity_association" {
  description = "Run the following command to associate the Cluster Autoscaler service account with an IAM role."
  value       = local.eks_auth == "EKSPI" ? "aws eks create-pod-identity-association --region ${local.region} --cluster-name ${module.eks.cluster_name} --role-arn ${aws_iam_role.cluster_autoscaler.arn} --namespace kube-system --service-account cluster-autoscaler" : null
}

variable "environment" {
  type = string
}
variable "github_org" {
  type = string
}
variable "github_repo" {
  type = string
}

# --- GitHub OIDC for CI ---

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["ffffffffffffffffffffffffffffffffffffffff"]
}

resource "aws_iam_role" "ci" {
  name = "cloudsleuth-${var.environment}-ci"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ci" {
  role = aws_iam_role.ci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "TerraformStateRead"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::cloudsleuth-tfstate", "arn:aws:s3:::cloudsleuth-tfstate/*"]
      },
      {
        Sid      = "TerraformLock"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = "arn:aws:dynamodb:us-east-1:*:table/cloudsleuth-tflock"
      },
      {
        Sid    = "ReadOnlyInfra"
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "globalaccelerator:Describe*", "globalaccelerator:List*",
          "lambda:GetFunction", "lambda:ListFunctions",
          "route53:GetHealthCheck", "route53:ListHealthChecks",
          "cloudwatch:DescribeAlarms",
          "iam:GetRole", "iam:GetPolicy", "iam:ListRolePolicies",
          "ssm:DescribeDocument",
          "dynamodb:DescribeTable",
          "sns:GetTopicAttributes",
          "sts:GetCallerIdentity",
        ]
        Resource = "*"
      }
    ]
  })
}

# --- SSM Automation role (used by the failover document) ---

resource "aws_iam_role" "ssm_automation" {
  name = "cloudsleuth-${var.environment}-ssm-failover"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ssm_automation" {
  role = aws_iam_role.ssm_automation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2Manage"
        Effect = "Allow"
        Action = ["ec2:StartInstances", "ec2:StopInstances"]
        # tag-based condition — only instances tagged Project=cloudsleuth
        Resource = "*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Project" = "cloudsleuth" }
        }
      },
      {
        Sid      = "EC2Describe"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"]
        Resource = "*"
      },
      {
        Sid    = "AcceleratorUpdate"
        Effect = "Allow"
        Action = [
          "globalaccelerator:UpdateEndpointGroup",
          "globalaccelerator:DescribeEndpointGroup",
        ]
        # GA ARNs use account-id-less format, hard to scope tighter
        Resource = "*"
      },
      {
        Sid      = "Notify"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = "arn:aws:sns:*:*:cloudsleuth-*"
      }
    ]
  })
}

output "ci_role_arn" {
  value = aws_iam_role.ci.arn
}

output "ssm_automation_role_arn" {
  value = aws_iam_role.ssm_automation.arn
}

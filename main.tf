terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

############################
# ───  METRIC & ALARM   ─── #
############################

resource "aws_cloudwatch_metric_alarm" "ebs_usage_high" {
  alarm_name          = "${var.environment}-${var.instance_name}-HighEBSUsageAlarm"
  alarm_description   = "Alarm when EBS volume usage exceeds ${var.alarm_threshold_percent}%."
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alarm_threshold_percent
  evaluation_periods  = 1
  period              = 300     # 5 min
  statistic           = "Average"

  namespace    = var.cloudwatch_metric_namespace
  metric_name  = "disk_used_percent"
  dimensions = {
    InstanceId = var.instance_id
    fstype     = var.fs_type
    path       = var.mount_path
  }

  tags = merge(var.additional_tags, {
    Name        = "ebs-usage-${var.alarm_threshold_percent}-alarm"
    Environment = var.environment
  })
}

###################################
# ───  EVENTBRIDGE CONNECTION  ─── #
###################################

resource "aws_cloudwatch_event_rule" "ebs_high_usage" {
  name        = "${var.environment}-${var.instance_name}-ebs-high-usage"
  description = "Trigger Step Functions workflow when EBS usage exceeds ${var.alarm_threshold_percent}%"
  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [aws_cloudwatch_metric_alarm.ebs_usage_high.alarm_name]
      state     = { value = ["ALARM"] }
    }
  })
}

########################################
# ───  CUSTOM IAM POLICY FOR LAMBDAS ─── #
########################################

data "aws_iam_policy_document" "lambda_ebs_permissions" {
  statement {
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeVolumes",
      "ec2:ModifyVolume",
      "ec2:DescribeTags",
      "ssm:SendCommand"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lambda_ebs_policy" {
  name        = "${var.environment}-${var.instance_name}-lambda-ebs-policy"
  description = "Allows Lambda functions to inspect and modify the instance’s root EBS volume"
  policy      = data.aws_iam_policy_document.lambda_ebs_permissions.json
}

################################
# ───  LAMBDA  FUNCTIONS   ─── #
################################

module "resize_lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 6.0"

  function_name = "${var.environment}-${var.instance_name}-resize-volume"
  handler       = "resize-volume.handler"
  runtime       = var.lambda_runtime
  source_path   = "${path.module}/handlers"

  attach_policies    = true
  number_of_policies = 2
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.lambda_ebs_policy.arn
  ]

  environment_variables = {
    INSTANCE_ID      = var.instance_id
    ROOT_DEVICE_NAME = var.root_device_name
    MAX_SIZE_GIB     = tostring(var.max_size_gib)
    GROWTH_PERCENT   = tostring(var.desired_growth_percent)
  }
}

module "check_state_lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 6.0"

  function_name = "${var.environment}-${var.instance_name}-check-volume-state"
  handler       = "check-state.handler"
  runtime       = var.lambda_runtime
  source_path   = "${path.module}/handlers"

  attach_policies    = true
  number_of_policies = 2
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.lambda_ebs_policy.arn
  ]
}

module "expand_partition_lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 6.0"

  function_name = "${var.environment}-${var.instance_name}-expand-partition"
  handler       = "expand-partition.handler"
  runtime       = var.lambda_runtime
  source_path   = "${path.module}/handlers"

  attach_policies    = true
  number_of_policies = 2
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    aws_iam_policy.lambda_ebs_policy.arn
  ]
}

################################
# ───  STEP FUNCTIONS WF   ─── #
################################

# Execution role for the state machine
resource "aws_iam_role" "sfn_execution_role" {
  name = "${var.environment}-${var.instance_name}-StepFunctionsExecutionRole"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Action    = "sts:AssumeRole",
      Principal = { Service = "states.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sfn_lambda_access" {
  role       = aws_iam_role.sfn_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
}

resource "aws_sfn_state_machine" "ebs_expansion" {
  name     = "${var.environment}-${var.instance_name}-ebs-expansion-workflow"
  role_arn = aws_iam_role.sfn_execution_role.arn

  definition = jsonencode({
    Comment : "Automatically resize the root EBS volume when the CloudWatch alarm fires",
    StartAt : "ResizeVolume",
    States  : {
      ResizeVolume : {
        Type  : "Task",
        Resource : module.resize_lambda.lambda_function_arn,
        Next  : "WaitForOptimization",
        Retry : [{
          ErrorEquals     : ["IncorrectModificationState"],
          IntervalSeconds : 30,
          MaxAttempts     : 2
        }]
      },
      WaitForOptimization : {
        Type    : "Wait",
        Seconds : var.optimization_wait_seconds,
        Next    : "CheckVolumeState"
      },
      CheckVolumeState : {
        Type     : "Task",
        Resource : module.check_state_lambda.lambda_function_arn,
        Next     : "EvaluateState",
        Retry    : [{
          ErrorEquals     : ["States.ALL"],
          IntervalSeconds : 60,
          MaxAttempts     : 2
        }]
      },
      EvaluateState : {
        Type    : "Choice",
        Choices : [{
          Variable     : "$.state",
          StringEquals : "completed",
          Next         : "ExpandPartition"
        }],
        Default : "WaitForOptimization"
      },
      ExpandPartition : {
        Type     : "Task",
        Resource : module.expand_partition_lambda.lambda_function_arn,
        End      : true
      }
    }
  })
}

#########################################
# ───  EVENTBRIDGE ▸ STEP-FUNCTION  ─── #
#########################################

# Role used by EventBridge to start executions
resource "aws_iam_role" "eventbridge_sfn_role" {
  name = "${var.environment}-${var.instance_name}-EventBridgeStepFunctionsRole"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Action    = "sts:AssumeRole",
      Principal = { Service = "events.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eventbridge_sfn_policy" {
  role       = aws_iam_role.eventbridge_sfn_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSStepFunctionsFullAccess"
}

resource "aws_cloudwatch_event_target" "invoke_step_function" {
  rule      = aws_cloudwatch_event_rule.ebs_high_usage.name
  target_id = "InvokeEBSStepFunction"
  arn       = aws_sfn_state_machine.ebs_expansion.arn
  role_arn  = aws_iam_role.eventbridge_sfn_role.arn
}

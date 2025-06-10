################################
# ───  REQUIRED PARAMETERS  ─── #
################################
variable "instance_id" {
  description = "ID of the EC2 instance whose root EBS volume should be monitored and auto-expanded."
  type        = string
}

variable "environment" {
  description = "Environment tag (e.g. dev, staging, prod). Used in resource names."
  type        = string
}

variable "instance_name" {
  description = "Human-readable name for the instance. Used to make resource names unique."
  type        = string
}

################################
# ───  OPTIONAL TUNABLES   ─── #
################################

variable "alarm_threshold_percent" {
  description = "Trigger threshold for the CloudWatch alarm (disk_used_percent)."
  type        = number
  default     = 90
}

variable "max_size_gib" {
  description = "Hard-stop maximum size (GiB) to which the root volume can grow."
  type        = number
  default     = 100
}

variable "desired_growth_percent" {
  description = "Percent growth applied each time the alarm fires (e.g. 50 → 1.5×)."
  type        = number
  default     = 50
}

variable "optimization_wait_seconds" {
  description = "How long Step Functions should wait for AWS to finish the volume optimisation step."
  type        = number
  default     = 600
}

variable "lambda_runtime" {
  description = "Runtime to use for Lambda functions."
  type        = string
  default     = "nodejs22.x"
}

variable "root_device_name" {
  description = "Block-device name used in the EC2 block-device mapping (e.g. /dev/sda1 or /dev/xvda)."
  type        = string
  default     = "/dev/sda1"
}

variable "cloudwatch_metric_namespace" {
  description = "Namespace where the CloudWatch Agent publishes disk_used_percent."
  type        = string
  default     = "CWAgent"
}

variable "fs_type" {
  description = "File-system type reported by the CloudWatch Agent."
  type        = string
  default     = "ext4"
}

variable "mount_path" {
  description = "Mount path reported by the CloudWatch Agent metric."
  type        = string
  default     = "/"
}

variable "additional_tags" {
  description = "Extra tags to attach to every resource created by this module."
  type        = map(string)
  default     = {}
}

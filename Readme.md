# AWS EBS Auto-Expand Module 

Automatically resizes an EC2 instance’s **root** EBS volume when disk
utilisation crosses a threshold (default 90 %).  
It uses only managed AWS services—CloudWatch, EventBridge, Lambda, Step
Functions, and SSM.

## Prerequisites 

| Requirement | Why / details |
|-------------|---------------|
| **Ubuntu 22.04** (Jammy) on Nitro-based EC2 (nvme) | Partition-expand handler is hard-coded for `/dev/nvme0n1`. |
| **CloudWatch Agent** installed & running | Publishes `disk_used_percent` in **CWAgent** namespace. |
| **IAM instance-profile** with: <br>• `AmazonSSMManagedInstanceCore` <br>• `CloudWatchAgentServerPolicy` | Lets the agent publish metrics and SSM run commands. |
| Terraform ≥ 1.5 & AWS provider ≥ 5.0 | Module uses newer syntax (`terraform-aws-lambda` v6). |

### One-liner to install the agent

```bash
wget https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb &&
sudo dpkg -i -E ./amazon-cloudwatch-agent.deb &&
sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json >/dev/null <<'EOF'
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root"
  },
  "metrics": {
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}"
    },
    "metrics_collected": {
      "disk": {
        "drop_original_metrics": true,
        "aggregation_dimensions": [["InstanceId"]],
        "drop_device": true,
        "drop_filesystem": true,
        "drop_fstype": true,
        "measurement": [
          { "name": "disk_used_percent" }
        ],
        "metrics_collection_interval": 10,
        "resources": ["/"]
      }
    }
  }
}
EOF
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s
```

---

## Quick-start 
```hcl
# ─── Small test instance ────────────────────────────────────────────────────
data "aws_ami" "ubuntu" {
  most_recent = true
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  owners = ["099720109477"]
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.nano"
  iam_instance_profile   = aws_iam_instance_profile.profile.name
  root_block_device {
    volume_type = "gp3"
    volume_size = 10
  }
  tags = { Name = "web-test" }
}

# ─── Instance role with SSM + CW agent perms ────────────────────────────────
resource "aws_iam_role" "role" {
  name               = "web_test_role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { 
      type = "Service"
      identifiers = ["ec2.amazonaws.com"] 
    }
  }
}

resource "aws_iam_instance_profile" "profile" {
  name = "web_test_profile"
  role = aws_iam_role.role.name
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# ─── Drop-in module call ────────────────────────────────────────────────────
module "auto_expand_root_ebs" {
  source = "git::https://github.com/PCG-International/ebs-exapand-volume.git//?ref=main"

  instance_id          = aws_instance.web.id
  environment          = "dev"
  instance_name        = "web"
}
```

---

## Input variables

| Variable                      | Type / default          | Description                                          |
| ----------------------------- | ----------------------- | ---------------------------------------------------- |
| **`instance_id`**             | `string` (required)     | EC2 whose *root* volume you want to auto-expand.     |
| **`environment`**             | `string` (required)     | Tag + prefix in all resource names (`dev`,`prod`,…). |
| **`instance_name`**           | `string` (required)     | Human-friendly label to keep names unique.           |
| `alarm_threshold_percent`     | `number` = 90           | Utilisation that triggers the resize workflow.       |
| `max_size_gib`                | `number` = 100          | Hard cap for total disk size after successive grows. |
| `desired_growth_percent`      | `number` = 50           | How much to **increase** each time (50 → +50 %).     |
| `optimization_wait_seconds`   | `number` = 600          | Wait state in Step Functions before re-checking.     |
| `lambda_runtime`              | `string` = `nodejs22.x` | Runtime for all three Lambdas.                       |
| `root_device_name`            | `string` = `/dev/sda1`  | Device name used in EC2’s block-device mapping.      |
| `cloudwatch_metric_namespace` | `string` = `CWAgent`    | Namespace where the agent publishes.                 |
| `fs_type`                     | `string` = `ext4`       | Filter dimension on the metric alarm.                |
| `mount_path`                  | `string` = `/`          | Filter dimension on the metric alarm.                |
| `additional_tags`             | `map(string)` = `{}`    | Extra tags applied to every resource.                |

---

## Outputs

| Name                   | Description                                   |
| ---------------------- | --------------------------------------------- |
| `cloudwatch_alarm_arn` | ARN of “HighEBSUsageAlarm”.                   |
| `step_function_arn`    | State-machine ARN.                            |
| `resize_lambda_name`   | Name of the Lambda that calls `ModifyVolume`. |
| `event_rule_name`      | EventBridge rule that triggers the workflow.  |

---

## End-to-end test 

1. SSH/SSM into the instance.
2. `sudo fallocate -l 7G /tmp/bloatfile` (make sure usage > 90 %).
3. Wait ≤ 6 min → CloudWatch alarm flips to **ALARM**.
4. Step-Functions execution runs **ResizeVolume → ExpandPartition**.
5. `lsblk` shows root grows from 10 G → 15 G.
6. Delete `/tmp/bloatfile`; alarm returns to **OK**.

---

## Troubleshooting

| Symptom                        | Fix                                                           |
| ------------------------------ | ------------------------------------------------------------- |
| Metric not in CW               | Agent not running, bad IAM, outbound HTTPS blocked.           |
| SFN fails at `ResizeVolume`    | Lambda role missing `ec2:ModifyVolume` (check inline policy). |
| Filesystem size doesn’t change | SSM command failed—check *Run Command* history.               |

---

## Things still missing / nice-to-have 

1. **Non-Nitro support** (xvda / sda devices) with conditional commands.
2. **Cross-platform agent config** for Amazon Linux, RHEL, etc.
3. **Parameter Store-hosted config** to avoid shipping JSON in the AMI.
4. **Unit tests / CD pipeline** publishing versioned tags to Terraform Registry.
5. **CloudWatch log group retention** variables for the Lambda functions.
6. **Alarm suppression** timer to avoid thrashing on sustained high usage.

**PRs welcome!**

---
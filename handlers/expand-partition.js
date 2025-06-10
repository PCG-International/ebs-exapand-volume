// handlers/expand-partition.js
const { SSMClient, SendCommandCommand } = require("@aws-sdk/client-ssm");

const ssm = new SSMClient();

exports.handler = async (event) => {
  await ssm.send(new SendCommandCommand({
    InstanceIds: [event.instanceId],
    DocumentName: "AWS-RunShellScript",
    Parameters: {
      commands: [
        "sudo growpart /dev/nvme0n1 1",
        "sudo resize2fs /dev/nvme0n1p1",
      ]
    }
  }));
  return { status: "partition_expanded", ...event };
};
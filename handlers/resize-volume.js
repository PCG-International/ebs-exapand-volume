// handlers/resize-volume.js
const { EC2Client, DescribeInstancesCommand, DescribeVolumesCommand, ModifyVolumeCommand } = require("@aws-sdk/client-ec2");

const ec2 = new EC2Client();
const instanceId = process.env.INSTANCE_ID;
const rootDeviceName = process.env.ROOT_DEVICE_NAME;
const growthPercent = process.env.GROWTH_PERCENT;
const maxSizeGb = process.env.MAX_SIZE_GIB;

exports.handler = async (event) => {
  try {
    if (!instanceId) throw new Error("INSTANCE_ID environment variable not set");

    // Get instance and volume details
    const instanceResponse = await ec2.send(new DescribeInstancesCommand({ InstanceIds: [instanceId] }));
    const rootVolumeId = instanceResponse.Reservations[0].Instances[0]
      .BlockDeviceMappings.find(bdm => bdm.DeviceName === rootDeviceName)?.Ebs?.VolumeId;

    const volumeResponse = await ec2.send(new DescribeVolumesCommand({ VolumeIds: [rootVolumeId] }));
    const currentSize = volumeResponse.Volumes[0].Size;
    const newSize = Math.min(Math.ceil(currentSize * (1 + growthPercent / 100)), maxSizeGb);

    if (newSize <= currentSize) return { status: "skipped", reason: "Already at max size" };

    // Check modification state
    const currentState = volumeResponse.Volumes[0].Modifications?.[0]?.State || "completed";
    if (["optimizing", "modifying"].includes(currentState)) {
      throw new Error(`IncorrectModificationState: Volume ${rootVolumeId} is ${currentState}`);
    }

    await ec2.send(new ModifyVolumeCommand({ VolumeId: rootVolumeId, Size: newSize }));
    return { 
      instanceId,
      volumeId: rootVolumeId,
      newSize,
      modificationTime: new Date().toISOString()
    };
  } catch (error) {
    console.error("Resize error:", error);
    throw error;
  }
};
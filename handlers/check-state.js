// handlers/check-state.js
const { EC2Client, DescribeVolumesCommand } = require("@aws-sdk/client-ec2");

const ec2 = new EC2Client();

exports.handler = async (event) => {
  const volumeResponse = await ec2.send(new DescribeVolumesCommand({
    VolumeIds: [event.volumeId]
  }));

  console.log("Volume state:", volumeResponse.Volumes[0].Modifications?.[0]?.State);
  console.log("Full Volume response:", volumeResponse);
  
  return {
    state: volumeResponse.Volumes[0].Modifications?.[0]?.State || "completed",
    ...event
  };
};
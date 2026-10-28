# Canvas development on AWS

This setup uses one Ubuntu 22.04 EC2 `t3.xlarge` (4 vCPUs, 16 GiB), a 100 GiB
encrypted gp3 root volume, a security group with no inbound rules, and a private
S3 bucket for transferring the tracked repository source. Canvas, PostgreSQL,
Redis, and background jobs run in Docker. No RDS, load balancer, or NAT gateway
is created. CPU credits use standard mode to avoid surplus-credit charges.

This is a development installation. Email, external tools, and other optional
Canvas integrations require separate configuration. S3 source archives expire
after seven days. Database files, uploads, and Docker volumes live on the EC2
root disk and survive instance stop/start. Terminating the instance or deleting
the stack deletes that disk and its application data; take backups first.

## Provision

From the repository root in PowerShell:

```powershell
aws sts get-caller-identity --profile default
./deploy/aws/provision.ps1
```

The script checks EC2 launch permissions before creating resources. It discovers
the region's default VPC, public subnet, and current Canonical Ubuntu image.
Supply `-VpcId`, `-SubnetId`, or `-ImageId` to override those choices. The subnet
must have an internet-gateway route. `-Profile` selects another credentials-file
profile. No credentials are embedded in the template, source archive, or VM.

By default the stack creates an instance role with Session Manager permissions
and read access to its own source archive. Where required, use an existing role
with `-InstanceProfileName LabInstanceProfile`. That role must already permit
Session Manager and downloading the source object. The AWS Academy lab tested
on October 26, 2026 explicitly denied `t3.xlarge`; the user elected to keep that
size and switch to an account permitting it. No instance was launched there.

CloudFormation completion confirms infrastructure creation. Application setup
continues separately and must pass the login-page health check before use.
Generated stack outputs are saved in `tmp/aws-canvas/outputs.json`.

```powershell
./deploy/aws/remote.ps1 -Command 'tail -n 50 /var/log/canvas-bootstrap.log'
./deploy/aws/remote.ps1 -Command 'test -f /var/lib/canvas-bootstrap-ready && curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/login/canvas'
```

If bootstrap fails, `/var/lib/canvas-bootstrap-failed` is created. Inspect the
log before repairing the failed step; rerunning bootstrap recreates secrets
and configuration and is not an upgrade procedure. The source archive contains
`git archive HEAD`, so uncommitted changes and ignored files are not transferred.

## Connect

Install the official [Session Manager plugin for Windows](https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-windows.html).
Then substitute the instance ID from the saved outputs:

```powershell
aws ssm start-session --region us-east-1 --target INSTANCE_ID --document-name AWS-StartPortForwardingSession --parameters 'portNumber=8080,localPortNumber=8080'
```

Keep the session open and visit <http://localhost:8080>. The generated admin
email is `admin@canvas.local`. Retrieve its random password from the instance
without copying it into source control or shared logs. Start a shell using the
EC2 console's **Connect > Session Manager**, then run:

```bash
sudo cat /home/ubuntu/canvas-admin.env
sudo -iu ubuntu
cd /home/ubuntu/canvas-lms
docker compose ps
```

Run all Yarn, Ruby, and Rails commands inside the web container, for example
`docker compose run --rm web yarn build`.

## Stop or remove

Stop the instance when idle using the EC2 console. Storage remains billable;
restarting it preserves application data. To remove this deployment after
backing up anything needed, first delete its single source object using the
saved `SourceBucket` and `SourceKey` outputs, then delete stack `canvas-dev`.
Do not empty unrelated buckets or delete the shared/default VPC or lab role.

The provisioning scripts have been checked for PowerShell syntax and the
generated initial template passed AWS validation. Full bootstrap and application
verification remain pending because the lab denied the requested instance size.

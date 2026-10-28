param(
    [string]$Region = 'us-east-1',
    [string]$Profile = 'default',
    [string]$StackName = 'canvas-dev',
    [string]$InstanceType = 't3.xlarge',
    [string]$VpcId,
    [string]$SubnetId,
    [string]$ImageId,
    [string]$InstanceProfileName
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$artifactDir = Join-Path $repoRoot 'tmp/aws-canvas'
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

function Invoke-Aws {
    param([Parameter(ValueFromRemainingArguments)] [string[]]$Arguments)
    $output = & aws @Arguments --region $Region --profile $Profile --no-cli-pager
    if ($LASTEXITCODE -ne 0) { throw "AWS command failed: $($Arguments[0..1] -join ' ')" }
    $output
}

$identity = (Invoke-Aws sts get-caller-identity --output json) | ConvertFrom-Json
Write-Output "Provisioning in account $($identity.Account), region $Region"
if (!$VpcId) {
    $vpcs = (Invoke-Aws ec2 describe-vpcs --filters 'Name=is-default,Values=true' --output json) | ConvertFrom-Json
    $VpcId = $vpcs.Vpcs[0].VpcId
}
if (!$VpcId) { throw 'No default VPC found. Supply VpcId and a public SubnetId.' }
if (!$SubnetId) {
    $subnets = (Invoke-Aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VpcId" 'Name=map-public-ip-on-launch,Values=true' --output json) | ConvertFrom-Json
    $SubnetId = $subnets.Subnets[0].SubnetId
}
if (!$SubnetId) { throw 'No public subnet found. Supply SubnetId with internet access.' }
if (!$ImageId) {
    $ImageId = (Invoke-Aws ec2 describe-images --owners 099720109477 --filters 'Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*' 'Name=state,Values=available' --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text).Trim()
}
if (!$ImageId -or $ImageId -eq 'None') { throw 'No Ubuntu 22.04 image found.' }

# Reject unavailable instance types before creating any billable resources.
$dryRun = & aws ec2 run-instances --image-id $ImageId --instance-type $InstanceType --subnet-id $SubnetId --count 1 --dry-run --region $Region --profile $Profile --no-cli-pager 2>&1
if (($dryRun | Out-String) -notmatch 'DryRunOperation') {
    throw "EC2 launch preflight failed for $InstanceType. No stack was created. Check account permissions and the instance size."
}
$commit = (& git -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the repository commit.' }
$sourceKey = "source/$commit.tar.gz"
$archivePath = Join-Path $artifactDir 'canvas-source.tar.gz'
& git -C $repoRoot archive --format=tar.gz "--output=$archivePath" HEAD
if ($LASTEXITCODE -ne 0) { throw 'Source archive failed.' }

$bootstrap = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'bootstrap.sh')).Replace("`r`n", "`n")
$template = @{
    AWSTemplateFormatVersion = '2010-09-09'
    Description = 'Private Canvas development host managed with Session Manager.'
    Resources = @{
        SourceBucket = @{
            Type = 'AWS::S3::Bucket'
            Properties = @{
                PublicAccessBlockConfiguration = @{
                    BlockPublicAcls = $true; BlockPublicPolicy = $true
                    IgnorePublicAcls = $true; RestrictPublicBuckets = $true
                }
                BucketEncryption = @{ ServerSideEncryptionConfiguration = @(@{ ServerSideEncryptionByDefault = @{ SSEAlgorithm = 'AES256' } }) }
                LifecycleConfiguration = @{ Rules = @(@{ Id = 'ExpireSourceArchives'; Status = 'Enabled'; ExpirationInDays = 7 }) }
                Tags = @(@{ Key = 'Project'; Value = 'canvas-lms' })
            }
        }
        HostSecurityGroup = @{
            Type = 'AWS::EC2::SecurityGroup'
            Properties = @{
                GroupDescription = 'Canvas development: no inbound access; use SSM port forwarding'
                VpcId = $VpcId
                SecurityGroupEgress = @(@{ IpProtocol = '-1'; CidrIp = '0.0.0.0/0' })
                Tags = @(@{ Key = 'Name'; Value = "$StackName-ssm-only" })
            }
        }
        CanvasHost = @{
            Type = 'AWS::EC2::Instance'
            Properties = @{
                ImageId = $ImageId
                InstanceType = $InstanceType
                CreditSpecification = @{ CPUCredits = 'standard' }
                MetadataOptions = @{ HttpTokens = 'required'; HttpEndpoint = 'enabled'; HttpPutResponseHopLimit = 1 }
                NetworkInterfaces = @(@{
                    DeviceIndex = '0'; AssociatePublicIpAddress = $true
                    SubnetId = $SubnetId; GroupSet = @(@{ 'Fn::GetAtt' = @('HostSecurityGroup', 'GroupId') })
                })
                BlockDeviceMappings = @(@{
                    DeviceName = '/dev/sda1'
                    Ebs = @{ VolumeSize = 100; VolumeType = 'gp3'; Encrypted = $true; DeleteOnTermination = $true }
                })
                Tags = @(@{ Key = 'Name'; Value = $StackName }, @{ Key = 'Project'; Value = 'canvas-lms' }, @{ Key = 'SourceCommit'; Value = $commit })
                UserData = @{ 'Fn::Base64' = @{ 'Fn::Join' = @('', @(
                    "#!/bin/bash`nexport SOURCE_BUCKET='",
                    @{ Ref = 'SourceBucket' },
                    "'`nexport SOURCE_KEY='$sourceKey'`nexport AWS_DEFAULT_REGION='$Region'`n",
                    $bootstrap
                )) } }
            }
        }
    }
    Outputs = @{
        InstanceId = @{ Value = @{ Ref = 'CanvasHost' } }
        SourceBucket = @{ Value = @{ Ref = 'SourceBucket' } }
        SourceKey = @{ Value = $sourceKey }
        ApplicationUrl = @{ Value = 'http://localhost:8080' }
    }
}
if ($InstanceProfileName) {
    $template.Resources.CanvasHost.Properties.IamInstanceProfile = $InstanceProfileName
} else {
    $template.Resources.InstanceRole = @{
        Type = 'AWS::IAM::Role'
        Properties = @{
            AssumeRolePolicyDocument = @{
                Version = '2012-10-17'
                Statement = @(@{ Effect = 'Allow'; Principal = @{ Service = 'ec2.amazonaws.com' }; Action = 'sts:AssumeRole' })
            }
            ManagedPolicyArns = @('arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore')
            Policies = @(@{
                PolicyName = 'ReadCanvasSource'
                PolicyDocument = @{
                    Version = '2012-10-17'
                    Statement = @(@{
                        Effect = 'Allow'; Action = 's3:GetObject'
                        Resource = @{ 'Fn::Join' = @('', @(@{ 'Fn::GetAtt' = @('SourceBucket', 'Arn') }, '/source/*')) }
                    })
                }
            })
        }
    }
    $template.Resources.InstanceProfile = @{
        Type = 'AWS::IAM::InstanceProfile'
        Properties = @{ Roles = @(@{ Ref = 'InstanceRole' }) }
    }
    $template.Resources.CanvasHost.Properties.IamInstanceProfile = @{ Ref = 'InstanceProfile' }
}
$templatePath = Join-Path $artifactDir 'cloudformation.json'
$template | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $templatePath -Encoding utf8
Invoke-Aws cloudformation validate-template --template-body "file://$templatePath" --output json
Invoke-Aws cloudformation create-stack --stack-name $StackName --template-body "file://$templatePath" --capabilities CAPABILITY_IAM --tags 'Key=Project,Value=canvas-lms' --output json

do {
    Start-Sleep -Seconds 10
    $stack = ((Invoke-Aws cloudformation describe-stacks --stack-name $StackName --output json) | ConvertFrom-Json).Stacks[0]
    Write-Output "Stack status: $($stack.StackStatus)"
    if ($stack.StackStatus -match 'FAILED|ROLLBACK|DELETE') {
        Invoke-Aws cloudformation describe-stack-events --stack-name $StackName --output json
        throw "Stack failed: $($stack.StackStatus)"
    }
} until ($stack.StackStatus -eq 'CREATE_COMPLETE')

$stack.Outputs | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $artifactDir 'outputs.json')
$bucket = ($stack.Outputs | Where-Object OutputKey -eq 'SourceBucket').OutputValue
Invoke-Aws s3api put-object --bucket $bucket --key $sourceKey --body $archivePath --output json
$instanceId = ($stack.Outputs | Where-Object OutputKey -eq 'InstanceId').OutputValue
Write-Output "Host created: $instanceId. Canvas setup continues in /var/log/canvas-bootstrap.log."
Write-Output "Connect: aws ssm start-session --target $instanceId --region $Region --profile $Profile"

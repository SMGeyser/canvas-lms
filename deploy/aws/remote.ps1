param(
    [Parameter(Mandatory)] [string[]]$Command,
    [string]$InstanceId,
    [string]$Region = 'us-east-1',
    [string]$Profile = 'default',
    [int]$TimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
$artifactDir = Join-Path $PSScriptRoot '../../tmp/aws-canvas'
if (!$InstanceId) {
    $outputs = Get-Content (Join-Path $artifactDir 'outputs.json') -Raw | ConvertFrom-Json
    $InstanceId = ($outputs | Where-Object OutputKey -eq 'InstanceId').OutputValue
}
if (!$InstanceId) { throw 'Provide InstanceId or run provision.ps1 first.' }
$request = @{
    DocumentName = 'AWS-RunShellScript'
    InstanceIds = @($InstanceId)
    Parameters = @{ commands = @($Command); executionTimeout = @("$TimeoutSeconds") }
}
$requestPath = Join-Path $artifactDir ("ssm-" + [guid]::NewGuid().ToString('N') + '.json')
$request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $requestPath -Encoding utf8
$sent = & aws ssm send-command --cli-input-json "file://$requestPath" --region $Region --profile $Profile --output json --no-cli-pager
if ($LASTEXITCODE -ne 0) { throw 'Failed to send SSM command.' }
$commandId = ($sent | ConvertFrom-Json).Command.CommandId
do {
    Start-Sleep -Seconds 2
    $resultText = & aws ssm get-command-invocation --command-id $commandId --instance-id $InstanceId --region $Region --profile $Profile --output json --no-cli-pager
    if ($LASTEXITCODE -ne 0) { throw 'Failed to read SSM command result.' }
    $result = $resultText | ConvertFrom-Json
} while ($result.Status -in @('Pending', 'InProgress', 'Delayed'))
Write-Output $result.StandardOutputContent
if ($result.StandardErrorContent) { Write-Output $result.StandardErrorContent }
if ($result.Status -ne 'Success') { throw "Remote command $commandId ended with $($result.Status)." }

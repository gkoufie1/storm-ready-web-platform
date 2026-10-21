# Flip Emergency Mode for an environment.
#   .\scripts\emergency.ps1 staging on|off|status
#
# PowerShell twin of emergency.sh.
param(
    [Parameter(Mandatory)][ValidateSet("staging", "prod")][string]$Environment,
    [Parameter(Mandatory)][ValidateSet("on", "off", "status")][string]$Mode
)
$ErrorActionPreference = "Stop"

$function = "storm-ready-$Environment-emergency-mode"
$who = aws sts get-caller-identity --query Arn --output text
if ($LASTEXITCODE -ne 0) { throw "AWS credentials not working - set `$env:AWS_PROFILE first" }

$payloadFile = New-TemporaryFile
$outFile = New-TemporaryFile
try {
    # Write the payload to a file: PowerShell 5.1 mangles quotes in inline JSON arguments.
    @{ mode = $Mode; requested_by = $who } | ConvertTo-Json -Compress |
        Set-Content -Path $payloadFile -Encoding ascii

    aws lambda invoke `
        --function-name $function `
        --cli-binary-format raw-in-base64-out `
        --payload "fileb://$payloadFile" `
        $outFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "lambda invoke failed" }

    Get-Content $outFile -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 10
}
finally {
    Remove-Item $payloadFile, $outFile -ErrorAction SilentlyContinue
}

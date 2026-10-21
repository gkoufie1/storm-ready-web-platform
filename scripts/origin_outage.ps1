# Simulate a total CMS outage (and recover from it) to prove static failover.
#   .\scripts\origin_outage.ps1 staging start   # suspend scaling, stop all tasks
#   .\scripts\origin_outage.ps1 staging end     # resume scaling, restore capacity
#
# PowerShell twin of origin_outage.sh. Scaling must be suspended first, or
# Application Auto Scaling would just start the tasks again.
param(
    [Parameter(Mandatory)][ValidateSet("staging", "prod")][string]$Environment,
    [Parameter(Mandatory)][ValidateSet("start", "end")][string]$Action
)
$ErrorActionPreference = "Stop"

$cluster  = "storm-ready-$Environment-cluster"
$service  = "storm-ready-$Environment-cms"
$resource = "service/$cluster/$service"

function Set-ScalingSuspended([string]$state) {
    aws application-autoscaling register-scalable-target `
        --service-namespace ecs `
        --scalable-dimension ecs:service:DesiredCount `
        --resource-id $resource `
        --suspended-state "DynamicScalingInSuspended=$state,DynamicScalingOutSuspended=$state,ScheduledScalingSuspended=$state" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "register-scalable-target failed" }
}

if ($Action -eq "start") {
    Set-ScalingSuspended "true"
    aws ecs update-service --cluster $cluster --service $service --desired-count 0 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "update-service failed" }
    Write-Host "CMS stopping. Within ~30-60s the ALB returns 503 and CloudFront serves the S3 snapshot."
    Write-Host "Cached pages keep serving from the edge; add a query string (/?v=123) to force an origin fetch."
}
else {
    $min = aws application-autoscaling describe-scalable-targets `
        --service-namespace ecs --resource-ids $resource `
        --query "ScalableTargets[0].MinCapacity" --output text
    if ($LASTEXITCODE -ne 0) { throw "describe-scalable-targets failed" }
    aws ecs update-service --cluster $cluster --service $service --desired-count $min | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "update-service failed" }
    Set-ScalingSuspended "false"
    Write-Host "CMS restarting with $min task(s); scaling resumed. Allow ~1-2 minutes to become healthy."
}

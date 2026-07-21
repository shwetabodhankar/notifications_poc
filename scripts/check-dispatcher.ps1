$tok = (az account get-access-token --query accessToken -o tsv)
$base = "https://management.azure.com/subscriptions/852f8491-61e9-4d75-b79a-9744a28c42a5/resourceGroups/rg-notifpoc-dev/providers/Microsoft.Logic/workflows"

# Dispatcher latest run
$r = (Invoke-RestMethod -Uri "$base/la-notif-dispatcher-dev/runs?api-version=2016-06-01&`$top=1" -Headers @{ Authorization = "Bearer $tok" }).value[0]
Write-Host "=== Dispatcher: $($r.properties.status) [$($r.properties.startTime)] ==="
$acts = (Invoke-RestMethod -Uri "$base/la-notif-dispatcher-dev/runs/$($r.name)/actions?api-version=2016-06-01" -Headers @{ Authorization = "Bearer $tok" }).value
$acts | Select-Object @{n='Action';e={$_.name}}, @{n='Status';e={$_.properties.status}}, @{n='Error';e={$_.properties.error.message}} | Sort-Object Action | Format-Table -AutoSize

# Show the input to Call_Teams_Notifier if it ran
$callTeams = $acts | Where-Object { $_.name -eq 'Call_Teams_Notifier' }
if ($callTeams) {
    Write-Host "--- Call_Teams_Notifier status: $($callTeams.properties.status) ---"
    if ($callTeams.properties.error.message) { Write-Host "Error: $($callTeams.properties.error.message)" }
}

# Show Dispatch_Teams_Notification if present
$dispTeams = $acts | Where-Object { $_.name -eq 'Dispatch_Teams_Notification' }
if ($dispTeams) {
    Write-Host "--- Dispatch_Teams_Notification status: $($dispTeams.properties.status) ---"
    if ($dispTeams.properties.error.message) { Write-Host "Error: $($dispTeams.properties.error.message)" }
}

# Show the input body sent to teams notifier
Write-Host "`n=== Orchestrator latest run ==="
$ro = (Invoke-RestMethod -Uri "$base/la-notif-orchestrator-dev/runs?api-version=2016-06-01&`$top=1" -Headers @{ Authorization = "Bearer $tok" }).value[0]
Write-Host "Orchestrator: $($ro.properties.status) [$($ro.properties.startTime)]"
$oa = (Invoke-RestMethod -Uri "$base/la-notif-orchestrator-dev/runs/$($ro.name)/actions?api-version=2016-06-01" -Headers @{ Authorization = "Bearer $tok" }).value
$oa | Select-Object @{n='Action';e={$_.name}}, @{n='Status';e={$_.properties.status}} | Sort-Object Action | Format-Table -AutoSize

$url = "https://prod-68.eastus.logic.azure.com:443/workflows/74c48fb29bdd4a97afc11660ca4bebdf/triggers/Receive_WorkItem_Webhook/paths/invoke?api-version=2019-05-01&sp=%2Ftriggers%2FReceive_WorkItem_Webhook%2Frun&sv=1.0&sig=JYl3EdRtZ-WR7Ayb-6cbLoBRkq_cO6oiPZVq-MxhIlw"
$payload = Get-Content C:\Projects\aveva\notificationspoc\docs\samples\ado-webhook-sample.json -Raw
$r = Invoke-WebRequest -Method POST -Uri $url -Headers @{ "x-webhook-secret" = "" } -ContentType "application/json" -Body $payload
Write-Host "Orchestrator trigger: HTTP $($r.StatusCode)"
Write-Host "Waiting 15s for chain to complete..."
Start-Sleep 15
$tok = (az account get-access-token --query accessToken -o tsv)
$base = "https://management.azure.com/subscriptions/852f8491-61e9-4d75-b79a-9744a28c42a5/resourceGroups/rg-notifpoc-dev/providers/Microsoft.Logic/workflows"
foreach ($la in @('la-notif-orchestrator-dev','la-notif-dispatcher-dev','la-notif-teams-dev-connector')) {
    $run = (Invoke-RestMethod -Uri "$base/$la/runs?api-version=2016-06-01&`$top=1" -Headers @{ Authorization = "Bearer $tok" }).value[0]
    $status = $run.properties.status
    $sym = if ($status -eq 'Succeeded') {'[OK]'} elseif ($status -eq 'Failed') {'[FAIL]'} else {'[...]'}
    Write-Host "$sym $la -> $status"
    if ($status -eq 'Failed') {
        $acts = (Invoke-RestMethod -Uri "$base/$la/runs/$($run.name)/actions?api-version=2016-06-01" -Headers @{ Authorization = "Bearer $tok" }).value
        $acts | Where-Object { $_.properties.status -eq 'Failed' } | ForEach-Object {
            Write-Host "     x $($_.name): $($_.properties.error.message)"
        }
    }
}

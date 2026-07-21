$tok = (az account get-access-token --query accessToken -o tsv)
$sub = "852f8491-61e9-4d75-b79a-9744a28c42a5"
$rg  = "rg-notifpoc-dev"
$la  = "la-notif-teams-dev"
$url = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Logic/workflows/$la`?api-version=2019-05-01"

Write-Host "Getting current definition..."
$wf = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $tok" }

$fixed = "@concat(if(contains(coalesce(triggerBody()?['scenarios'], json('[]')), 'C'), 'CYBER SECURITY | ', ''), if(contains(coalesce(triggerBody()?['scenarios'], json('[]')), 'B'), 'P1 CRITICAL | ', ''), 'Scenario A')"
$wf.properties.definition.actions.Determine_Scenario_Label.inputs = $fixed
Write-Host "Expression updated."

$body = $wf | ConvertTo-Json -Depth 50
Write-Host "Pushing update..."
$r = Invoke-RestMethod -Method PUT -Uri $url -Headers @{ Authorization = "Bearer $tok"; "Content-Type" = "application/json" } -Body $body
Write-Host "Done: $($r.properties.provisioningState)"

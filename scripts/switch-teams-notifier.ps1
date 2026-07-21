$tok = (az account get-access-token --query accessToken -o tsv)
$sub = "852f8491-61e9-4d75-b79a-9744a28c42a5"
$rg  = "rg-notifpoc-dev"
$la  = "la-notif-dispatcher-dev"
$url = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Logic/workflows/$la`?api-version=2019-05-01"

$newTeamsUrl = "https://prod-75.eastus.logic.azure.com:443/workflows/8d45de578fc54600967342b284786f27/triggers/Receive_Teams_Notification_Request/paths/invoke?api-version=2019-05-01&sp=%2Ftriggers%2FReceive_Teams_Notification_Request%2Frun&sv=1.0&sig=-38_2NG9ola8XEgbTHvuoDwjp9K62oX4UBIbpIfQ5DE"

Write-Host "Getting email notifier trigger URL..."
$emailCbUrl = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Logic/workflows/la-notif-email-dev/triggers/Receive_Email_Notification_Request/listCallbackUrl?api-version=2019-05-01"
$emailCb = Invoke-RestMethod -Method POST -Uri $emailCbUrl -Headers @{ Authorization = "Bearer $tok" }
$emailUrl = $emailCb.value
Write-Host "  emailNotifierUrl retrieved."

Write-Host "Getting current dispatcher definition..."
$wf = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $tok" }

# Securestring values are masked in GET — set parameters block explicitly with both required params
$wf.properties | Add-Member -MemberType NoteProperty -Name parameters -Value @{
    teamsNotifierUrl = @{ value = $newTeamsUrl }
    emailNotifierUrl = @{ value = $emailUrl }
} -Force
Write-Host "Set teamsNotifierUrl -> la-notif-teams-dev-connector"

$body = $wf | ConvertTo-Json -Depth 50
$r = Invoke-RestMethod -Method PUT -Uri $url `
    -Headers @{ Authorization = "Bearer $tok"; "Content-Type" = "application/json" } `
    -Body $body
Write-Host "Dispatcher updated: $($r.properties.provisioningState)"

TOKEN=$(curl -fsS https://overstate-setback-going.ngrok-free.dev/api/catalog/v1/oauth/tokens --user root:s3cr3t -d 'grant_type=client_credentials' -d 'scope=PRINCIPAL_ROLE:ALL' | jq -r .access_token)                        
echo "$TOKEN"    

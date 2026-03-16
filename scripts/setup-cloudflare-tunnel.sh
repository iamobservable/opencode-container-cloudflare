#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../env/cloudflare-setup.env"

log() {
    echo "$@" >&2
}

load_env() {
    if [ ! -f "$ENV_FILE" ]; then
        log "Error: $ENV_FILE not found"
        log "Copy env/cloudflare-setup.env.example to env/cloudflare-setup.env and fill in your values"
        exit 1
    fi
    
    set -a
    source "$ENV_FILE"
    set +a
}

validate_env() {
    local missing=()
    
    [ -z "$CLOUDFLARE_API_TOKEN" ] && missing+=("CLOUDFLARE_API_TOKEN")
    [ -z "$CLOUDFLARE_ACCOUNT_ID" ] && missing+=("CLOUDFLARE_ACCOUNT_ID")
    [ -z "$CLOUDFLARE_ZONE_ID" ] && missing+=("CLOUDFLARE_ZONE_ID")
    [ -z "$CLOUDFLARE_DOMAIN" ] && missing+=("CLOUDFLARE_DOMAIN")
    [ -z "$OPENCODE_SUBDOMAIN" ] && missing+=("OPENCODE_SUBDOMAIN")
    [ -z "$CLOUDFLARE_TUNNEL_NAME" ] && missing+=("CLOUDFLARE_TUNNEL_NAME")
    
    if [ ${#missing[@]} -gt 0 ]; then
        log "Error: Missing required environment variables:"
        printf '  - %s\n' "${missing[@]}" >&2
        exit 1
    fi
}

validate_api_token() {
    log "Validating Cloudflare API token..."
    
    local response
    response=$(curl -s -X GET \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        "https://api.cloudflare.com/client/v4/user/tokens/verify")
    
    local status
    status=$(echo "$response" | jq -r '.success' 2>/dev/null)
    
    if [ "$status" != "true" ]; then
        local error_code error_message
        error_code=$(echo "$response" | jq -r '.errors[0].code // "unknown"' 2>/dev/null)
        error_message=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"' 2>/dev/null)
        
        log "Error: Cloudflare API token is invalid or lacks required permissions"
        log "  Code: $error_code"
        log "  Message: $error_message"
        log ""
        log "Please ensure your API token has the following permissions:"
        log "  - Account > Zero Trust > Access: Apps and Policies (Edit)"
        log "  - Account > Cloudflare Tunnel > Edit"
        log "  - Zone > DNS > Edit"
        log ""
        log "Create a token at: https://dash.cloudflare.com/profile/api-tokens"
        exit 1
    fi
    
    local token_id token_name
    token_id=$(echo "$response" | jq -r '.result.id // "N/A"' 2>/dev/null)
    token_name=$(echo "$response" | jq -r '.result.name // "N/A"' 2>/dev/null)
    
    log "API token validated successfully"
    log "  Token: $token_name (ID: $token_id)"
    log ""
}

api_call() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    
    local args=(-X "$method" -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")
    
    if [ -n "$data" ]; then
        args+=(-H "Content-Type: application/json" -d "$data")
    fi
    
    curl "${args[@]}" "https://api.cloudflare.com/client/v4$endpoint"
}

check_api_response() {
    local response="$1"
    local context="$2"
    
    local success
    success=$(echo "$response" | jq -r '.success' 2>/dev/null)
    
    if [ "$success" != "true" ]; then
        log "Error: API call failed - $context"
        log "Response: $response"
        local errors
        errors=$(echo "$response" | jq -r '.errors[] | "  - \(.code): \(.message)"' 2>/dev/null)
        if [ -n "$errors" ]; then
            log "Errors:"
            log "$errors"
        fi
        return 1
    fi
    return 0
}

get_tunnel() {
    local response
    response=$(api_call GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel")
    
    if ! check_api_response "$response" "list tunnels"; then
        return 1
    fi
    
    echo "$response" | jq -r --arg name "$CLOUDFLARE_TUNNEL_NAME" \
        '.result[] | select(.name == $name) | .id' 2>/dev/null | head -1
}

create_tunnel() {
    local existing_id="$1"
    
    if [ -n "$existing_id" ] && [ "$existing_id" != "null" ] && [ "$existing_id" != "" ]; then
        log "Using existing tunnel: $existing_id"
        echo "$existing_id"
        return 0
    fi
    
    log "Creating new tunnel: $CLOUDFLARE_TUNNEL_NAME"
    
    local response
    response=$(api_call POST "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel" \
        "{\"name\":\"$CLOUDFLARE_TUNNEL_NAME\"}")
    
    if ! check_api_response "$response" "create tunnel"; then
        return 1
    fi
    
    local tunnel_id
    tunnel_id=$(echo "$response" | jq -r '.result.id' 2>/dev/null)
    
    if [ -z "$tunnel_id" ] || [ "$tunnel_id" == "null" ]; then
        log "Error: Failed to extract tunnel ID from response"
        log "Response: $response"
        return 1
    fi
    
    local tunnel_token
    tunnel_token=$(echo "$response" | jq -r '.result.token' 2>/dev/null)
    
    if [ -n "$tunnel_token" ] && [ "$tunnel_token" != "null" ]; then
        echo "$tunnel_id|$tunnel_token"
    else
        echo "$tunnel_id"
    fi
}

get_tunnel_token() {
    local tunnel_id="$1"
    
    local response
    response=$(api_call GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel/$tunnel_id/token")
    
    if ! check_api_response "$response" "get tunnel token"; then
        return 1
    fi
    
    echo "$response" | jq -r '.result' 2>/dev/null
}

get_dns_record() {
    local hostname="$1"
    
    local response
    response=$(api_call GET "/zones/$CLOUDFLARE_ZONE_ID/dns_records?name=$hostname")
    
    echo "$response" | jq -r '.result[0].id' 2>/dev/null | head -1
}

create_dns_record() {
    local tunnel_id="$1"
    local hostname="${OPENCODE_SUBDOMAIN}.${CLOUDFLARE_DOMAIN}"
    
    local existing_record
    existing_record=$(get_dns_record "$hostname")
    
    if [ -n "$existing_record" ] && [ "$existing_record" != "null" ]; then
        log "DNS record already exists for $hostname"
        return 0
    fi
    
    log "Creating DNS record for $hostname"
    
    local response
    response=$(api_call POST "/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
        "{\"type\":\"CNAME\",\"name\":\"$OPENCODE_SUBDOMAIN\",\"content\":\"${tunnel_id}.cfargotunnel.com\",\"ttl\":3600,\"proxied\":true}")
    
    if ! check_api_response "$response" "create DNS record"; then
        return 1
    fi
    
    log "DNS record created successfully"
}

create_access_application() {
    local hostname="${OPENCODE_SUBDOMAIN}.${CLOUDFLARE_DOMAIN}"
    
    local response
    response=$(api_call GET "/zones/$CLOUDFLARE_ZONE_ID/access/apps")
    
    if ! check_api_response "$response" "list access apps"; then
        log "Warning: Could not check existing access applications"
    fi
    
    local existing_app
    existing_app=$(echo "$response" | jq -r --arg domain "$hostname" \
        '.result[] | select(.domain == $domain) | .id' 2>/dev/null | head -1)
    
    if [ -n "$existing_app" ] && [ "$existing_app" != "null" ]; then
        log "Access application already exists: $existing_app"
        echo "$existing_app"
        return 0
    fi
    
    log "Creating Access application for $hostname"
    
    response=$(api_call POST "/zones/$CLOUDFLARE_ZONE_ID/access/apps" \
        "{\"name\":\"OpenCode\",\"domain\":\"$hostname\",\"type\":\"self_hosted\"}")
    
    if ! check_api_response "$response" "create access application"; then
        log "Warning: Access application creation failed, continuing without Access"
        return 1
    fi
    
    local app_id
    app_id=$(echo "$response" | jq -r '.result.id' 2>/dev/null)
    
    if [ -z "$app_id" ] || [ "$app_id" == "null" ]; then
        log "Warning: Could not extract app ID"
        return 1
    fi
    
    echo "$app_id"
}

create_access_policy() {
    local app_id="$1"
    
    if [ -z "$CLOUDFLARE_ALLOWED_EMAILS" ] || [ -z "$app_id" ]; then
        log "Skipping Access policy (no emails configured or app ID missing)"
        return 0
    fi
    
    log "Creating Access policy for allowed emails"
    
    local app_uid
    app_uid=$(api_call GET "/zones/$CLOUDFLARE_ZONE_ID/access/apps/$app_id" | jq -r '.result.uid' 2>/dev/null)
    
    if [ -z "$app_uid" ] || [ "$app_uid" == "null" ]; then
        log "Warning: Could not get app UID for policy creation"
        return 1
    fi
    
    local existing_policies
    existing_policies=$(api_call GET "/zones/$CLOUDFLARE_ZONE_ID/access/apps/$app_id/policies")
    
    local max_precedence
    max_precedence=$(echo "$existing_policies" | jq -r '.result | map(.precedence) | max // 0' 2>/dev/null)
    
    if [ -z "$max_precedence" ] || [ "$max_precedence" == "null" ]; then
        max_precedence=0
    fi
    
    local next_precedence=$((max_precedence + 1))
    
    local include_rules=""
    local first=true
    
    while IFS=',' read -ra emails; do
        for email in "${emails[@]}"; do
            email=$(echo "$email" | xargs)
            if [ -n "$email" ]; then
                if [ "$first" = true ]; then
                    include_rules="{\"email\":{\"email\":\"$email\"}}"
                    first=false
                else
                    include_rules="$include_rules,{\"email\":{\"email\":\"$email\"}}"
                fi
            fi
        done
    done <<< "$CLOUDFLARE_ALLOWED_EMAILS"
    
    local json_payload="{\"name\":\"Allowed Emails\",\"decision\":\"allow\",\"include\":[$include_rules],\"precedence\":$next_precedence,\"app_uid\":\"$app_uid\"}"
    
    log "Creating policy with precedence $next_precedence..."
    
    local response
    response=$(api_call POST "/zones/$CLOUDFLARE_ZONE_ID/access/apps/$app_id/policies" "$json_payload")
    
    if ! check_api_response "$response" "create access policy"; then
        log "Warning: Access policy creation failed"
        return 1
    fi
    
    log "Access policy created successfully"
}

save_tunnel_token() {
    local token="$1"
    local output_file="$SCRIPT_DIR/../env/cloudflared.env"
    
    if [ -f "$output_file" ]; then
        log "Updating existing $output_file"
        if grep -q "^CLOUDFLARE_TUNNEL_TOKEN=" "$output_file"; then
            sed -i.bak "s|^CLOUDFLARE_TUNNEL_TOKEN=.*|CLOUDFLARE_TUNNEL_TOKEN=$token|" "$output_file"
            rm -f "${output_file}.bak"
        else
            echo "CLOUDFLARE_TUNNEL_TOKEN=$token" >> "$output_file"
        fi
    else
        log "Creating $output_file"
        cat > "$output_file" <<EOF
# Cloudflare Tunnel Configuration
# Generated by setup script

CLOUDFLARE_TUNNEL_TOKEN=$token
EOF
    fi
}

main() {
    log "=== Cloudflare Tunnel Setup Script ==="
    log ""
    
    load_env
    validate_env
    validate_api_token
    
    log "Configuration:"
    log "  Domain: $CLOUDFLARE_DOMAIN"
    log "  Subdomain: $OPENCODE_SUBDOMAIN"
    log "  Tunnel: $CLOUDFLARE_TUNNEL_NAME"
    log "  Zone ID: $CLOUDFLARE_ZONE_ID"
    log "  Account ID: $CLOUDFLARE_ACCOUNT_ID"
    log ""
    
    local tunnel_result tunnel_id tunnel_token
    
    log "Step 1: Checking for existing tunnel..."
    tunnel_id=$(get_tunnel)
    
    if [ -n "$tunnel_id" ] && [ "$tunnel_id" != "null" ]; then
        log "Found existing tunnel: $tunnel_id"
    else
        log "No existing tunnel found"
    fi
    log ""
    
    log "Step 2: Creating tunnel..."
    tunnel_result=$(create_tunnel "$tunnel_id")
    
    if [ -z "$tunnel_result" ] || [ "$tunnel_result" == "null" ]; then
        log "Error: Failed to create or retrieve tunnel"
        exit 1
    fi
    
    if echo "$tunnel_result" | grep -q '|'; then
        tunnel_id=$(echo "$tunnel_result" | cut -d'|' -f1)
        tunnel_token=$(echo "$tunnel_result" | cut -d'|' -f2)
        log "Tunnel ID: $tunnel_id"
        log "Token received from tunnel creation"
    else
        tunnel_id="$tunnel_result"
        log "Tunnel ID: $tunnel_id"
    fi
    log ""
    
    log "Step 3: Creating DNS record..."
    create_dns_record "$tunnel_id"
    log ""
    
    if [ -n "$CLOUDFLARE_ALLOWED_EMAILS" ]; then
        local app_id
        
        log "Step 4: Creating Access application..."
        app_id=$(create_access_application)
        
        if [ -n "$app_id" ] && [ "$app_id" != "null" ]; then
            log "Step 5: Creating Access policy..."
            create_access_policy "$app_id"
        fi
        log ""
    fi
    
    if [ -z "$tunnel_token" ]; then
        log "Step 6: Retrieving tunnel token..."
        tunnel_token=$(get_tunnel_token "$tunnel_id")
        
        if [ -z "$tunnel_token" ] || [ "$tunnel_token" == "null" ]; then
            log "Error: Failed to retrieve tunnel token"
            exit 1
        fi
    fi
    
    log ""
    log "=== Setup Complete ==="
    log ""
    log "Your tunnel token:"
    log "$tunnel_token"
    
    save_tunnel_token "$tunnel_token"
    
    log ""
    log "Tunnel token saved to env/cloudflared.env"
    log ""
    log "Next steps:"
    log "  1. Review env/opencode.env and configure your Ollama Cloud API key"
    log "  2. Run: docker compose up -d"
    log "  3. Visit: https://${OPENCODE_SUBDOMAIN}.${CLOUDFLARE_DOMAIN}"
    log ""
}

main "$@"
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../env/cloudflare-setup.env"

load_env() {
    if [ ! -f "$ENV_FILE" ]; then
        echo "Error: $ENV_FILE not found"
        echo "Copy env/cloudflare-setup.env.example to env/cloudflare-setup.env and fill in your values"
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
        echo "Error: Missing required environment variables:"
        printf '  - %s\n' "${missing[@]}"
        exit 1
    fi
}

validate_api_token() {
    echo "Validating Cloudflare API token..."
    
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
        
        echo "Error: Cloudflare API token is invalid or lacks required permissions"
        echo "  Code: $error_code"
        echo "  Message: $error_message"
        echo ""
        echo "Please ensure your API token has the following permissions:"
        echo "  - Account > Zero Trust > Access: Apps and Policies (Edit)"
        echo "  - Account > Cloudflare Tunnel > Edit"
        echo "  - Zone > DNS > Edit"
        echo ""
        echo "Create a token at: https://dash.cloudflare.com/profile/api-tokens"
        exit 1
    fi
    
    local token_id token_name
    token_id=$(echo "$response" | jq -r '.result.id // "N/A"' 2>/dev/null)
    token_name=$(echo "$response" | jq -r '.result.name // "N/A"' 2>/dev/null)
    
    echo "API token validated successfully"
    echo "  Token: $token_name (ID: $token_id)"
    echo ""
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

get_tunnel() {
    api_call GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfn_tunnel" | \
        jq -r --arg name "$CLOUDFLARE_TUNNEL_NAME" \
        '.result[] | select(.name == $name) | .id' 2>/dev/null || echo ""
}

create_tunnel() {
    local tunnel_id="$1"
    
    if [ -n "$tunnel_id" ]; then
        echo "Using existing tunnel: $tunnel_id"
        echo "$tunnel_id"
        return 0
    fi
    
    echo "Creating new tunnel: $CLOUDFLARE_TUNNEL_NAME"
    
    local response
    response=$(api_call POST "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfn_tunnel" \
        "{\"name\":\"$CLOUDFLARE_TUNNEL_NAME\",\"config_src\":\"cloudflare\"}")
    
    echo "$response" | jq -r '.result.id'
}

get_tunnel_token() {
    local tunnel_id="$1"
    api_call GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/cfn_tunnel/$tunnel_id/token" | \
        jq -r '.result' 2>/dev/null
}

get_dns_record() {
    local hostname="$1"
    api_call GET "/zones/$CLOUDFLARE_ZONE_ID/dns_records?name=$hostname" | \
        jq -r '.result[0].id' 2>/dev/null || echo ""
}

create_dns_record() {
    local tunnel_id="$1"
    local hostname="${OPENCODE_SUBDOMAIN}.${CLOUDFLARE_DOMAIN}"
    
    local existing_record
    existing_record=$(get_dns_record "$hostname")
    
    if [ -n "$existing_record" ]; then
        echo "DNS record already exists for $hostname"
        return 0
    fi
    
    echo "Creating DNS record for $hostname"
    
    api_call POST "/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
        "{\"type\":\"CNAME\",\"name\":\"$OPENCODE_SUBDOMAIN\",\"content\":\"${tunnel_id}.cfargotunnel.com\",\"ttl\":3600,\"proxied\":true}" \
        > /dev/null
}

create_access_application() {
    local hostname="${OPENCODE_SUBDOMAIN}.${CLOUDFLARE_DOMAIN}"
    
    local existing_app
    existing_app=$(api_call GET "/zones/$CLOUDFLARE_ZONE_ID/access/apps" | \
        jq -r --arg domain "$hostname" '.result[] | select(.domain == $domain) | .id' 2>/dev/null || echo "")
    
    if [ -n "$existing_app" ]; then
        echo "Access application already exists: $existing_app"
        echo "$existing_app"
        return 0
    fi
    
    echo "Creating Access application for $hostname"
    
    api_call POST "/zones/$CLOUDFLARE_ZONE_ID/access/apps" \
        "{\"name\":\"OpenCode\",\"domain\":\"$hostname\",\"type\":\"self_hosted\"}" | \
        jq -r '.result.id'
}

create_access_policy() {
    local app_id="$1"
    
    if [ -z "$CLOUDFLARE_ALLOWED_EMAILS" ] || [ -z "$app_id" ]; then
        echo "Skipping Access policy (no emails configured or app ID missing)"
        return 0
    fi
    
    echo "Creating Access policy for allowed emails"
    
    local emails_json
    emails_json=$(echo "$CLOUDFLARE_ALLOWED_EMAILS" | tr ',' '\n' | \
        jq -R -s 'split("\n") | map(select(length > 0)) | {email: .}')
    
    local app_uid
    app_uid=$(api_call GET "/zones/$CLOUDFLARE_ZONE_ID/access/apps/$app_id" | \
        jq -r '.result.uid')
    
    if [ -z "$app_uid" ]; then
        echo "Warning: Could not get app UID for policy creation"
        return 0
    fi
    
    api_call POST "/zones/$CLOUDFLARE_ZONE_ID/access/apps/$app_id/policies" \
        "{\"name\":\"Allowed Emails\",\"decision\":\"allow\",\"include\":[$emails_json],\"precedence\":1,\"app_uid\":\"$app_uid\"}" \
        > /dev/null
    
    echo "Access policy created successfully"
}

save_tunnel_token() {
    local token="$1"
    local output_file="$SCRIPT_DIR/../env/cloudflared.env"
    
    if [ -f "$output_file" ]; then
        echo "Updating existing $output_file"
        if grep -q "^CLOUDFLARE_TUNNEL_TOKEN=" "$output_file"; then
            sed -i.bak "s|^CLOUDFLARE_TUNNEL_TOKEN=.*|CLOUDFLARE_TUNNEL_TOKEN=$token|" "$output_file"
            rm -f "${output_file}.bak"
        else
            echo "CLOUDFLARE_TUNNEL_TOKEN=$token" >> "$output_file"
        fi
    else
        echo "Creating $output_file"
        cat > "$output_file" <<EOF
# Cloudflare Tunnel Configuration
# Generated by setup script

CLOUDFLARE_TUNNEL_TOKEN=$token
EOF
    fi
}

main() {
    echo "=== Cloudflare Tunnel Setup Script ==="
    echo ""
    
    load_env
    validate_env
    validate_api_token
    
    echo "Configuration:"
    echo "  Domain: $CLOUDFLARE_DOMAIN"
    echo "  Subdomain: $OPENCODE_SUBDOMAIN"
    echo "  Tunnel: $CLOUDFLARE_TUNNEL_NAME"
    echo "  Zone ID: $CLOUDFLARE_ZONE_ID"
    echo "  Account ID: $CLOUDFLARE_ACCOUNT_ID"
    echo ""
    
    echo "Step 1: Checking for existing tunnel..."
    tunnel_id=$(get_tunnel)
    
    echo "Step 2: Creating tunnel..."
    tunnel_id=$(create_tunnel "$tunnel_id")
    
    if [ -z "$tunnel_id" ] || [ "$tunnel_id" == "null" ]; then
        echo "Error: Failed to create or retrieve tunnel"
        exit 1
    fi
    
    echo "Tunnel ID: $tunnel_id"
    echo ""
    
    echo "Step 3: Creating DNS record..."
    create_dns_record "$tunnel_id"
    echo ""
    
    if [ -n "$CLOUDFLARE_ALLOWED_EMAILS" ]; then
        echo "Step 4: Creating Access application..."
        app_id=$(create_access_application)
        
        if [ -n "$app_id" ] && [ "$app_id" != "null" ]; then
            echo "Step 5: Creating Access policy..."
            create_access_policy "$app_id"
        fi
        echo ""
    fi
    
    echo "Step: Retrieving tunnel token..."
    token=$(get_tunnel_token "$tunnel_id")
    
    if [ -z "$token" ] || [ "$token" == "null" ]; then
        echo "Error: Failed to retrieve tunnel token"
        exit 1
    fi
    
    echo ""
    echo "=== Setup Complete ==="
    echo ""
    echo "Your tunnel token:"
    echo "$token"
    echo ""
    
    save_tunnel_token "$token"
    
    echo "Tunnel token saved to env/cloudflared.env"
    echo ""
    echo "Next steps:"
    echo "  1. Review env/opencode.env and configure your Ollama Cloud API key"
    echo "  2. Run: docker compose up -d"
    echo "  3. Visit: https://${OPENCODE_SUBDOMAIN}.${CLOUDFLARE_DOMAIN}"
    echo ""
}

main "$@"
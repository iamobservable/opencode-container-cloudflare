#!/bin/bash
set -e

generate_config() {
    local config_dir="/root/.config/opencode"
    local config_file="$config_dir/opencode.json"
    
    mkdir -p "$config_dir"
    
    if [ ! -f "$config_file" ]; then
        local model="${OPENCODE_MODEL:-glm-5:cloud}"
        local provider_config=""
        
        if [ -n "$OLLAMA_CLOUD_API_KEY" ]; then
            provider_config=$(cat <<EOF
    "ollama-cloud": {
        "options": {
            "apiKey": "$OLLAMA_CLOUD_API_KEY"
        }
    },
    "ollama": {
        "options": {
            "baseURL": "http://localhost:11434/v1"
        }
    }
EOF
)
        else
            provider_config=$(cat <<EOF
    "ollama": {
        "options": {
            "baseURL": "http://localhost:11434/v1"
        }
    }
EOF
)
        fi
        
        cat > "$config_file" <<EOF
{
    "$schema": "https://opencode.ai/config.json",
    "model": "$model",
    "provider": {
$provider_config
    }
}
EOF
        echo "Generated OpenCode config with model: $model"
    else
        echo "OpenCode config already exists, skipping generation"
    fi
}

generate_config

ollama serve &
OLLAMA_PID=$!

for i in {1..30}; do
    if curl -s http://localhost:11434/ > /dev/null 2>&1; then
        echo "Ollama is ready"
        break
    fi
    echo "Waiting for Ollama to start..."
    sleep 1
done

echo "Starting OpenCode web server..."
exec opencode web --hostname 0.0.0.0 --port 4000
#!/bin/bash
set -e

generate_config() {
    local config_dir="/root/.config/opencode"
    local config_file="$config_dir/opencode.json"
    
    mkdir -p "$config_dir"
    
    if [ ! -f "$config_file" ] && [ -n "$OPENCODE_PROVIDER_API_KEY" ]; then
        cat > "$config_file" <<EOF
{
    "$schema": "https://opencode.ai/config.json",
    "provider": {
        "ollama": {
            "options": {
                "baseURL": "http://localhost:11434/v1"
            }
        }
    }
}
EOF
    fi
}

generate_config

ollama serve &
OLLAMA_PID=$!

for i in {1..30}; do
    if curl -s http://localhost:11434/ > /dev/null 2>&1; then
        break
    fi
    echo "Waiting for Ollama to start..."
    sleep 1
done

exec opencode web --hostname 0.0.0.0 --port 4000
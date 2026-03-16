#!/bin/bash
set -e

generate_config() {
    local config_dir="/root/.config/opencode"
    local config_file="$config_dir/opencode.json"
    
    mkdir -p "$config_dir"
    
    if [ ! -f "$config_file" ]; then
        local model="${OPENCODE_MODEL:-ollama}"
        
        if [ -n "$OLLAMA_CLOUD_API_KEY" ]; then
            cat > "$config_file" <<EOF
{
    "model": "$model",
    "provider": {
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
    }
}
EOF
        else
            cat > "$config_file" <<EOF
{
    "model": "$model",
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
exec /root/.opencode/bin/opencode web --hostname 0.0.0.0 --port 4000
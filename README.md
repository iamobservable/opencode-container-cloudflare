# OpenCode + Ollama + Cloudflare Tunnel

Docker Compose deployment for OpenCode web interface with Ollama Cloud, exposed via Cloudflare Tunnel.

## Quick Start

1. **Copy environment templates:**
   ```bash
   cp env/opencode.env.example env/opencode.env
   cp env/cloudflared.env.example env/cloudflared.env
   ```

2. **Configure OpenCode:**
   - Get your Ollama Cloud API key from https://ollama.com/settings/keys
   - Edit `env/opencode.env` and set `OLLAMA_CLOUD_API_KEY`

3. **Configure Cloudflare Tunnel:**
   
   **Option A: Automatic setup (recommended)**
   ```bash
   cp env/cloudflare-setup.env.example env/cloudflare-setup.env
   # Edit env/cloudflare-setup.env with your Cloudflare credentials
   ./scripts/setup-cloudflare-tunnel.sh
   ```

   **Option B: Manual setup**
   - Create a tunnel in [Cloudflare Zero Trust](https://one.dash.cloudflare.com/)
   - Copy the tunnel token to `env/cloudflared.env`

4. **Start services:**
   ```bash
   docker compose up -d
   ```

5. **Access OpenCode:**
   - Visit `https://opencode.yourdomain.com`

## Services

- **opencode**: Runs OpenCode web on port 4000 with Ollama server
- **cloudflared**: Cloudflare Tunnel for secure external access

## Volumes

- `opencode_config`: Persists OpenCode configuration (including API keys)
- `ollama_models`: Persists Ollama model cache

## Environment Variables

### opencode.env
| Variable | Description |
|----------|-------------|
| `OLLAMA_CLOUD_API_KEY` | Your Ollama Cloud API key |
| `OPENCODE_MODEL` | Default model (default: `glm-5:cloud`) |

### cloudflared.env
| Variable | Description |
|----------|-------------|
| `CLOUDFLARE_TUNNEL_TOKEN` | Cloudflare Tunnel token |

## Cloudflare Access

This setup includes optional Cloudflare Access authentication using One-time PIN. Configure allowed emails in `env/cloudflare-setup.env` during tunnel setup.

## Troubleshooting

View logs:
```bash
docker compose logs -f opencode
docker compose logs -f cloudflared
```

## Security Notes

- Never commit `env/*.env` files (they're in `.gitignore`)
- Use scoped API tokens, not global keys
- Limit Cloudflare Access to specific email addresses
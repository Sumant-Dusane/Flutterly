# Flutter + Claude Code Split View

## What It Does

A standalone web app. User visits a URL and sees:
- **Left pane**: Web terminal running Claude Code CLI
- **Right pane**: Flutter web preview (shows "Starting Flutter..." until ready)

When Claude Code edits files in the left terminal, Flutter hot reload updates the right pane automatically.

---

## First-Visit Auth Flow

1. User visits `https://yourdomain.com`
2. Page checks if Bedrock is already configured (by fetching a small status endpoint or checking a marker)
3. If not configured → modal with 1 field:
   - **AWS Bearer Token** (the Bedrock token)
4. On submit → a script writes to `~/.zshrc`:
   ```bash
   export CLAUDE_CODE_USE_BEDROCK=1
   export AWS_REGION=us-east-1
   export AWS_BEARER_TOKEN_BEDROCK=<entered-token>
   ```
   (`CLAUDE_CODE_USE_BEDROCK=1` and `AWS_REGION=us-east-1` are hardcoded defaults, only the bearer token is user input)
5. Restarts ttyd service so env vars take effect
6. Modal dismissed, split view loads

Subsequent visits: checks if `AWS_BEARER_TOKEN_BEDROCK` already exists in `~/.zshrc` → skips modal.

---

## Architecture

```
Browser → https://domain.com/
    ↓
Caddy (HTTPS)
    ├── /              → split-view.html
    ├── /terminal/*    → ttyd:7681 (Claude Code)
    ├── /preview/*     → Flutter dev server:8080
    └── /config        → CGI/script endpoint for Bedrock setup
```

---

## File Structure

```
flutter-claude-split/
├── setup.sh                # One-time setup script
├── split-view.html         # The split-view UI + auth modal
├── scripts/
│   ├── configure-bedrock.sh  # Writes env vars to ~/.zshrc
│   └── check-bedrock.sh     # Checks if env vars exist in ~/.zshrc
├── Caddyfile.template      # Caddy config template
└── config/
    └── .flutter-project    # Path to Flutter project
```

---

## Config

**`config/.flutter-project`** - contains the absolute path to the Flutter project:
```
/home/user/my_flutter_app
```

Set during setup:
```bash
sudo bash setup.sh yourdomain.com /path/to/flutter/project
```

---

## Prerequisites (must already be installed)

- Flutter SDK (with `flutter` on PATH)
- Node.js (for Claude Code CLI)

---

## Setup Script (`setup.sh`)

Takes 2 args: `<domain> <flutter-project-path>`

What it does:
1. Validates Flutter is installed (`which flutter`)
2. Installs ttyd (downloads binary)
3. Installs Caddy (apt)
4. Saves config: domain, flutter project path
5. Creates 2 systemd services:
   - **ttyd** → web terminal on port 7681, working dir = flutter project, sources `~/.zshrc` for env
   - **flutter-dev** → `flutter run -d web-server --web-port=8080` in the flutter project dir
6. Writes Caddyfile (HTTPS, reverse proxy routes)
7. Starts everything

---

## Split View Page (`split-view.html`)

Single HTML file with embedded CSS/JS.

### Layout
```
┌──────────────────────┬──────────────────────┐
│                      │                      │
│   Claude Code        │   Flutter Preview    │
│   Terminal           │                      │
│   (iframe)           │   (iframe)           │
│                      │                      │
└──────────────────────┴──────────────────────┘
         ↑ draggable divider ↑
```

### Behavior
- Dark theme
- Two iframes, 50/50 split
- Draggable divider to resize panes
- Right pane: polls `/preview/` every 2s until Flutter responds, shows "Starting Flutter..." overlay until then
- On page load: GET `/check-bedrock` → if not configured, show modal
- Auth modal: 1 input (AWS Bearer Token) + submit button
- On submit: POST `/configure-bedrock` with the token → script writes to `~/.zshrc` and restarts ttyd

---

## Scripts

### `scripts/check-bedrock.sh`
- Reads `~/.zshrc`
- Checks if `AWS_BEARER_TOKEN_BEDROCK` is exported
- Outputs `configured` or `not-configured`

### `scripts/configure-bedrock.sh`
- Takes bearer token as argument
- Removes any existing `CLAUDE_CODE_USE_BEDROCK`, `AWS_REGION`, `AWS_BEARER_TOKEN_BEDROCK` lines from `~/.zshrc`
- Appends:
  ```bash
  export CLAUDE_CODE_USE_BEDROCK=1
  export AWS_REGION=us-east-1
  export AWS_BEARER_TOKEN_BEDROCK=<token>
  ```
- Restarts ttyd service: `systemctl restart claude-ttyd`

---

## Systemd Services

### ttyd (web terminal)
```ini
[Service]
ExecStart=/usr/local/bin/ttyd -p 7681 -W /bin/bash -l -c "cd /path/to/flutter/project && exec bash"
Environment=TERM=xterm-256color
Restart=always
```

Bash login shell sources `~/.zshrc`/`~/.bashrc`, so Bedrock env vars are available. User types `claude` to start Claude Code.

### Flutter dev server
```ini
[Service]
ExecStart=/usr/bin/flutter run -d web-server --web-port=8080 --web-hostname=127.0.0.1
WorkingDirectory=/path/to/flutter/project
Restart=always
```

---

## Caddyfile

```caddyfile
yourdomain.com {
    # Split view page
    handle / {
        root * /path/to/flutter-claude-split
        file_server
        try_files /split-view.html
    }

    # Terminal proxy
    handle /terminal/* {
        uri strip_prefix /terminal
        reverse_proxy localhost:7681
    }

    # Flutter preview proxy
    handle /preview/* {
        uri strip_prefix /preview
        reverse_proxy localhost:8080
    }

    # Bedrock config check (script-backed)
    handle /check-bedrock {
        exec /path/to/scripts/check-bedrock.sh
    }

    handle /configure-bedrock {
        exec /path/to/scripts/configure-bedrock.sh {query.token}
    }
}
```

Note: Caddy doesn't natively support CGI. The actual implementation will use a tiny shell-based HTTP handler or embed the check/configure logic differently (e.g., a small Node script that serves both endpoints, or use Caddy's `exec` plugin). The simplest approach: **a single small Node.js script** that handles just these 2 routes and the static file serving, running on port 7600, with Caddy proxying to it. Or skip Caddy for the config endpoints and have the split-view.html call the scripts via a different mechanism.

**Simplest approach**: Use a small Node.js HTTP server (~50 lines) that:
- Serves `split-view.html` at `/`
- Handles `GET /check-bedrock` → runs `check-bedrock.sh`
- Handles `POST /configure-bedrock` → runs `configure-bedrock.sh`
- Caddy proxies `/`, `/check-bedrock`, `/configure-bedrock` to this server

---

## Hot Reload Flow

1. User runs `claude` in left terminal
2. Claude Code edits a `.dart` file and saves
3. Flutter dev server detects file change (built-in watcher)
4. Hot reload triggers automatically
5. Right iframe updates within ~1-2 seconds

No extra watchers needed.

---

## User Experience

```
1. sudo bash setup.sh mysite.com /home/user/my_flutter_app
   → Installs ttyd, Caddy, creates services, starts everything

2. Open https://mysite.com/
   → First visit: modal asks for AWS Bearer Token
   → Saves to ~/.zshrc with defaults (USE_BEDROCK=1, REGION=us-east-1)

3. Split view loads:
   - Left: bash terminal (type "claude" to start Claude Code)
   - Right: "Starting Flutter..." → then live Flutter preview

4. Tell Claude to make changes → see them live on the right
```

---

## Summary

**Files:**
- `setup.sh` - one-time setup
- `split-view.html` - the UI (iframes + auth modal)
- `scripts/check-bedrock.sh` - checks if token is configured
- `scripts/configure-bedrock.sh` - saves token to ~/.zshrc
- `Caddyfile.template` - reverse proxy template

**Installed by setup.sh:**
- ttyd, Caddy

**Must be pre-installed:**
- Flutter SDK, Node.js
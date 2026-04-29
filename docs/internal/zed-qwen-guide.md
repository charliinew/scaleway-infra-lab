# Zed + Qwen Quick Reference Guide

## 🚀 Getting Started

### 1. Verify Setup
```bash
.zed/scripts/verify-setup.sh
```

### 2. Open in Zed
```bash
zed .
```

### 3. Open Assistant
- **Chat**: `Cmd+Shift+A`
- **Agent Panel**: `Cmd+Shift+L`
- **Inline Edit**: `Cmd+K`

---

## 🤖 Agent Triggers

Prefix your prompt with `/agent-name` to activate specialized agents.

| Agent | Use Case | Example |
|-------|----------|---------|
| `/explore-codebase` | Find existing code patterns | `/explore-codebase how does image upload work?` |
| `/team-backend` | Backend implementation | `/team-backend add GET /images/:id endpoint` |
| `/team-frontend` | Frontend/UI changes | `/team-frontend add download button` |
| `/team-tester` | Write tests | `/team-tester test the new image endpoint` |
| `/team-security` | Security audit | `/team-security audit the upload endpoint` |
| `/team-reviewer` | Code review | `/team-reviewer review my changes in app.py` |
| `/apex` | Systematic implementation | `/apex -a -s implement image resizing` |
| `/commit` | Quick commit | `/commit` |
| `/pedagogue` | Learn concepts | `/pedagogue explain Scaleway Secret Manager` |
| `/oneshot` | Fast implementation | `/oneshot add health check endpoint` |
| `/ultrathink` | Deep problem solving | `/ultrathink how to optimize image processing` |
| `/websearch` | Find documentation | `/websearch actix-web image processing best practices` |

---

## 🔧 How Slash-Commands Work

When you use a slash-command like `/explore-codebase`, here's what happens:

1. **Qwen reads the command** from your prompt
2. **Loads the skill file** from `~/.qwen/agents/` or `~/.qwen/skills/`:
   - `/explore-codebase` → `~/.qwen/agents/explore-codebase.md`
   - `/team-backend` → `~/.qwen/agents/team-backend.md`
   - `/apex` → `~/.qwen/skills/apex/SKILL.md`
   - `/commit` → `~/.qwen/skills/commit/SKILL.md`
3. **Follows the workflow** defined in that file
4. **Uses appropriate tools** (grep, read, edit, etc.)

**Important:** The skill files contain detailed instructions that override the basic description. Always use slash-commands to activate the full skill behavior.

### Skill Locations

| Type | Location | Examples |
|------|----------|----------|
| **Agents** | `~/.qwen/agents/<name>.md` | explore-codebase, team-*, websearch, action |
| **Skills** | `~/.qwen/skills/<name>/SKILL.md` | apex, commit, pedagogue, oneshot, ultrathink |

---

## 🎯 APEX Workflow Flags

| Flag | Description | When to Use |
|------|-------------|-------------|
| `-a` | Auto mode | Skip confirmations, full speed |
| `-s` | Save mode | Save output to `~/.qwen/output/apex/` |
| `-e` | Economy mode | No subagents (save tokens) |
| `-b` | Branch mode | Create git branch for feature |
| `-t` | Team mode | Spawn agent teams |

**Example:**
```
/apex -a -s -b implement password reset feature
```

---

## 📁 Project Context Files

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Architecture overview, tech stack, patterns |
| `.zed/settings.json` | Zed configuration |
| `.zed/rules/project-rules.md` | AI behavior rules for this project |
| `~/.qwen/QWEN.md` | Global Qwen preferences |
| `~/.qwen/agents/*.md` | Agent definitions |
| `~/.qwen/skills/*/SKILL.md` | Skill definitions |

---

## 🔧 Common Workflows

### Add a New Feature
```
1. /explore-codebase find similar endpoints
2. /apex -a -s implement new feature
3. /team-tester write tests
4. /team-reviewer review changes
5. /commit
```

### Fix a Bug
```
1. /explore-codebase find the bug location
2. /oneshot fix the issue
3. /team-tester add regression test
4. /commit
```

### Learn Something New
```
/pedagogue explain how Secret Manager works
/websearch find Scaleway RDB connection pooling best practices
```

### Security Audit
```
/team-security audit the authentication flow
```

---

## 🛠 Development Commands

### Local Development
```bash
# Start all services
docker compose up

# Test upload
curl -F "file=@logo.png" http://localhost:8080/upload

# View logs
docker compose logs -f app
```

### Infrastructure
```bash
# Initialize Terraform
make init

# Preview changes
make plan

# Deploy everything
make deploy

# Destroy infra (keep bucket + registry)
make destroy
```

### Docker
```bash
# Build and push all images
docker buildx bake --push
```

---

## 🔐 Security Rules

**NEVER:**
- Hardcode secrets in code
- Commit `.env` or `terraform.tfvars`
- Use public IPs for internal services

**ALWAYS:**
- Fetch secrets from Secret Manager
- Use private network for service communication
- Validate input types (PNG only)

---

## 📝 Code Style

### Python (FastAPI)
```python
# Use async/await
async def upload_image(file: UploadFile = File(...)):
    async with aiohttp.ClientSession() as session:
        async with session.post(url, data=data) as response:
            ...

# Type hints on all functions
# SQLAlchemy 2.0 declarative style
class ImageRecord(Base):
    __tablename__ = "images"
    id = Column(String, primary_key=True)
```

### Rust (Actix)
```rust
// Use web::Bytes for payloads
async fn process_image(payload: web::Bytes) -> HttpResponse {
    match load_from_memory(&payload) {
        Ok(img) => HttpResponse::Ok().body(processed),
        Err(e) => HttpResponse::BadRequest().body("error"),
    }
}
```

### Terraform
```hcl
# Use depends_on for ordering
resource "scaleway_instance_server" "rest_api" {
  depends_on = [scaleway_rdb_instance.main]
}

# Use var.* for all configurable values
type = var.instance_type
```

---

## 🐛 Troubleshooting

| Problem | Solution |
|---------|----------|
| Agent not responding | Check `/agent-name` syntax, verify `~/.qwen/agents/` exists |
| Hook not working | Run `chmod +x ~/.qwen/hooks/*.py` |
| Context not loading | Verify `CLAUDE.md` exists at project root |
| Zed not recognizing Qwen | Check `~/.qwen/settings.json` model config |

---

## 📚 Resources

- **Zed Docs**: https://zed.dev/docs
- **Project README**: See architecture diagrams
- **Challenges**: `challenges/` for implementation learnings
- **Global Config**: `~/.qwen/README.md`

---

## ⚡ Pro Tips

1. **Chain agents**: Explore → Implement → Test → Review → Commit
2. **Use APEX for complex tasks**: `/apex -s` saves output for reference
3. **Read before editing**: AI reads files automatically, but specify context
4. **Parallel tool calls**: Qwen uses them automatically for speed
5. **Economy mode**: Use `/apex -e` when on token budget

---

**Quick Start Command:**
```
/explore-codebase show me how image upload works from start to finish
```

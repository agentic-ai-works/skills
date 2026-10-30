# Agentic AI skills

Open-source skills and tools that let AI agents do real work safely. MIT licensed.

| Skill | What it does | Status |
|---|---|---|
| [bitwarden](bitwarden/) | Use a Bitwarden vault from an AI agent without exposing secrets: sandboxed `bw` CLI, tick-box permissions, TOTP codes | Linux works; macOS and Windows (WSL2) are untested |

Each skill lives in its own folder with its own README, installer and checksums.

Sponsoring is optional and unlocks nothing; it pays for testing on real machines and upkeep.

## Support
Everything here is free and MIT licensed. If it saves you time, you can chip in: [Ko-fi](https://ko-fi.com/AgenticAIWorks) or [Liberapay](https://liberapay.com/AgenticAIWorks). It pays for testing on real machines and upkeep, and unlocks nothing.

## Install
```
git clone https://github.com/agentic-ai-works/skills.git
cd skills/bitwarden
bash install/install.sh        # Linux; see bitwarden/README.md (macOS and Windows: untested)
```

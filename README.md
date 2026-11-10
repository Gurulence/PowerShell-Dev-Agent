# PowerShell & .NET Enterprise Agent Kit (VS Code Copilot + Standalone Loop)

An enterprise-grade **PowerShell (5.1 + 7+)** and **.NET** engineering agent suite built for **VS Code** with **strict manual approval** on every action.

It gives you **two tightly integrated ways to run the agent** sharing the same safety rules, workspace containment, `PSScriptAnalyzer` settings, and scaffolding tools:

1. **GitHub Copilot Custom Agents in VS Code** (`.github/agents/*.agent.md`, `.github/skills/`, `.github/instructions/`, `.github/prompts/`, `.github/hooks/`, `.vscode/mcp.json`, `.vscode/settings.json`) — uses your VS Code Copilot chat UI with all auto-approvals disabled.
2. **Standalone Terminal Agent (`Agent.ps1`)** — a zero-dependency PowerShell OpenAI-compatible BYOK loop with terminal diff previews, strict `[Y]es / [N]o / [F]eedback / [Q]uit` gates, session persistence, and JSONL audit logs.

---

## Strict Control & Safety Model

Every layer is configured so **nothing runs, edits, or publishes without your explicit approval**:

- **VS Code Copilot Settings (`.vscode/settings.json`)**:
  - `chat.permissions.default`: `"default"`
  - `chat.tools.global.autoApprove`: `false`
  - `chat.tools.terminal.enableAutoApprove`: `false` and destructive rules explicitly `false`
  - `chat.tools.edits.autoApprove`: `{ "**/*": false }`
  - `chat.tools.urls.autoApprove`: `{}`
  - `chat.tools.terminal.autoReplyToPrompts`: `false`
  - `chat.tools.terminal.blockDetectedFileWrites`: `"outsideWorkspace"`
  - `chat.autopilot.advanced.enabled`: `false`
  - `chat.mcp.autostart`: `"never"`
  - `task.allowAutomaticTasks`: `"off"`
- **Hard Safety Hook (`.github/hooks/safety-gate.json` -> `.github/hooks/Invoke-PreToolGuard.ps1`)**:
  - Runs on every `preToolUse` event and evaluates `config/agent.config.json` `denyPatterns` (`rm -rf /`, `iwr | iex`, `git push --force`, `git reset --hard`, `Publish-Module`, `dotnet nuget push`, `format`, `diskpart`, registry writes, etc.).
  - Returns `permissionDecision: "deny"` with exit code `2` (fail-closed) when a destructive pattern matches, and `{}` otherwise so VS Code's normal manual confirmation prompt still appears.
- **Standalone `Agent.ps1` Approval Gate (`config/agent.config.json`)**:
  - `approvalGate`: `"strict"` — requires explicit `Y`, `N`, `F`, or `Q` on every tool call (no `[A]lways` blanket auto-approve, no Enter-to-accept).

---

## Repository & Workspace Layout

```text
.
├── AGENTS.md                           Cross-agent repo rules
├── Agent.ps1                           Standalone BYOK PowerShell agent loop
├── AgentApproval.ps1                   Strict confirmation gate & denyPatterns engine
├── AgentConfig.ps1                     Config defaults & DPAPI/secure secret loader
├── AgentLlm.ps1                        OpenAI-compatible / Ollama REST client
├── AgentTools.ps1                      20 workspace-bounded PS & .NET tools
├── Install-Agent.ps1                   Project installer (deploys .agent/, .github/, .vscode/)
├── agent-doctor.ps1                    Environment & configuration verifier
├── config/
│   ├── agent.config.json               Default provider, strict gate, and denyPatterns
│   └── agent.config.schema.json        JSON Schema (Draft-07)
├── prompts/modes/
│   ├── planner.md                      Read-only planning mode contract
│   ├── hybrid.md                       Plan-first, confirm-every-step mode contract
│   └── executor.md                     Direct strict execution mode contract
├── tools/
│   ├── PsDotnetMcpServer.ps1           Stdio JSON-RPC 2.0 MCP server (10 PS/.NET tools)
│   ├── Invoke-AgentPester.ps1          Pester v5+ test runner
│   ├── New-EnterprisePsModule.ps1      Script & C# binary PowerShell module scaffolder
│   ├── New-EnterpriseDotnetSolution.ps1 .NET solution + classlib + xUnit scaffolder
│   └── Sign-Artifact.ps1               Authenticode verify/sign helper (no plaintext secrets)
├── templates/
│   ├── Directory.Build.props           Strict MSBuild defaults (nullable, analyzers, XML docs)
│   └── github-workflows/               CI/CD YAML for PS modules & .NET libraries
├── tests/
│   ├── AgentTools.Tests.ps1            Unit tests for tools & enterprise scaffolders
│   ├── DenyPatterns.Tests.ps1          Safety pattern block/allow regression tests
│   ├── AgentLoop.Tests.ps1             End-to-end mock-LLM, MCP, hook, .NET, & installer tests
│   ├── mock_llm.py                     Local OpenAI-compatible mock server for testing
│   └── tty_drive.py                    Interactive PTY test harness
├── .vscode/
│   ├── settings.json                   Strict Copilot permissions, PS analyzer, C# Roslyn, terminal
│   ├── extensions.json                   Recommended Copilot, PowerShell, Pester, .NET, Git extensions
│   ├── mcp.json                        Registers ps-dotnet-tools MCP server
│   ├── tasks.json                      20 tasks (Agent, PS 5.1/7, Pester, dotnet build/test/pack/audit)
│   ├── launch.json                     Debugging configs for Agent.ps1, Pester, modules, and .NET
│   ├── keybindings.recommended.json    Optional user shortcuts for Agent/PS/dotnet tasks
│   └── PSScriptAnalyzerSettings.psd1   Shared ruleset (PS 5.1 + 7.0 syntax & formatting)
└── .github/
    ├── copilot-instructions.md         Repo-wide Copilot instructions
    ├── agents/                         4 custom agents: Architect, Planner, Executor, Reviewer
    ├── instructions/                   Scoped rules (PowerShell, .NET, Testing, Release/Signing)
    ├── prompts/                        Slash-command prompt templates (.prompt.md)
    ├── skills/                         Cross-harness Agent Skills (SKILL.md)
    └── hooks/                          Fail-closed Copilot preToolUse safety gate
```

---

## Quick Start

### 1. Prerequisites

- **VS Code** with recommended extensions from `.vscode/extensions.json`:
  - `github.copilot-chat` (and `github.copilot` if applicable)
  - `ms-vscode.powershell`, `pspester.pester-test`
  - `ms-dotnettools.csdevkit`, `ms-dotnettools.csharp`, `ms-dotnettools.vscode-dotnet-runtime`
  - `editorconfig.editorconfig`, `redhat.vscode-yaml`, `eamodio.gitlens`
- **PowerShell 7+** (`pwsh`) + PowerShell modules `PSScriptAnalyzer` and `Pester` (`>= 5.3`).
- **.NET 8+ SDK** (`dotnet`).
- **Git**.

### 2. Verify Your Environment

```powershell
pwsh -NoProfile -File ./agent-doctor.ps1
```

### 3. Install into Another Project

To equip an existing or new PowerShell/.NET repository with the full VS Code Copilot custom agents, MCP server, strict settings, and `.agent/` runner:

```powershell
pwsh -NoProfile -File ./Install-Agent.ps1 -Project C:\src\MyLibrary
```

- Existing `.vscode/` or `.github/` files are **preserved** (written alongside as `*.agent-kit`) unless you pass `-Force` (which creates timestamped `*.bak-*` backups).
- Only pass `-StoreKey persist` if you also want to configure a BYOK API key for the standalone `Agent.ps1` terminal loop (VS Code Copilot uses your existing GitHub Copilot sign-in).

### 4. Use in VS Code

1. Open the repository in VS Code and accept **Install Recommended Extensions** (or run **Extensions: Show Recommended Extensions**).
2. Open Copilot Chat and select one of the custom agents:
   - **`PS-DotNet-Architect`** — full PS 5.1/7 + .NET design, scaffolding, testing, and verification.
   - **`PS-DotNet-Planner`** — strictly read-only architectural planning & audit agent.
   - **`PS-DotNet-Executor`** — implements approved plans step-by-step with build/test gates.
   - **`PS-DotNet-Reviewer`** — code review, compatibility audit, security & signing verification.
3. Available skills & slash prompts:
   - `/powershell-module-scaffold` / `/new-ps-module`
   - `/binary-ps-module` / `/new-binary-ps-module`
   - `/dotnet-library-scaffold` / `/new-dotnet-library`
   - `/security-audit-signing` / `/audit-and-verify` / `/release-and-sign`
4. Start the **`ps-dotnet-tools`** MCP server on demand via **MCP: List Servers** in the Command Palette (`chat.mcp.autostart` is `"never"` so nothing starts automatically).
5. Run tasks anytime via **Terminal > Run Task**:
   - `PS: PSScriptAnalyzer (workspace)`
   - `PS: Run Pester tests`
   - `PS: Scaffold Enterprise Script Module` / `PS: Scaffold Binary C# Cmdlet Module`
   - `Dotnet: build` / `Dotnet: test` / `Dotnet: format verify` / `Dotnet: audit vulnerable packages` / `Dotnet: pack NuGet (artifacts)`
   - `Agent: doctor (verify environment)` / `Agent: run task (approve every step)`

### 5. Optional Keybindings

VS Code does not load workspace-level `keybindings.json` automatically. To enable the shortcuts from `.vscode/keybindings.recommended.json`, open **Preferences: Open Keyboard Shortcuts (JSON)** in VS Code and merge its entries into your user `keybindings.json`.

---

## Running the Test Suite

```powershell
pwsh -NoProfile -File ./tools/Invoke-AgentPester.ps1 -Path ./tests
```

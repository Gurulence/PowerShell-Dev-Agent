# Repository Engineering & Control Contract

This repository provides a **strictly human-controlled PowerShell & .NET engineering agent** — usable both natively inside VS Code GitHub Copilot (via `.github/agents/`, `.github/skills/`, `.github/hooks/`, and `.vscode/mcp.json`) and as a standalone BYOK terminal agent (`Agent.ps1`).

## Non-negotiable rules for all AI agents
1. **Strict human control**: Never run commands, modify files, publish artifacts, or chain unrelated actions without explicit user confirmation. Keep edits small, atomic, and independently reviewable.
2. **Read before write**: Always read target files and inspect surrounding conventions before proposing edits.
3. **Never guess APIs**: Verify cmdlets, parameters, and .NET types via `Get-Command`, `Get-Help`, `dotnet build`, or MCP tool `ps_inspect`.
4. **PowerShell compatibility**: Target **Windows PowerShell 5.1 AND PowerShell 7+** unless explicitly scoped to 7-only. Avoid `??`, `?.`, `?:` ternary, `&&`/`||` pipeline chains, and `-Parallel`.
5. **Modern .NET standards**: Enable `<Nullable>enable</Nullable>`, `<TreatWarningsAsErrors>true</TreatWarningsAsErrors>`, XML documentation on public APIs, `Async` suffix + `CancellationToken`, and proper `IDisposable`/`IAsyncDisposable`.
6. **Zero secrets**: Never write API keys, PATs, passwords, or private signing material into files, prompts, logs, or commands. Use environment variables or OS credential storage.
7. **Evidence-based completion**: Never claim a build, lint, manifest check, or test passed unless you ran it and observed real passing output.

See `.github/copilot-instructions.md` and `.github/instructions/` for full language-specific standards.

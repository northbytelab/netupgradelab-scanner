# NetUpgradeLab Scanner

A free, **read-only** scanner that shows what needs attention before you upgrade a .NET solution to **.NET 10 (LTS)**.

.NET 8 and .NET 9 reached end of support on November 10, 2026. Run one command and get a Markdown report of everything in your repo that is still pinned to an older version, uses an obsolete API, or needs a full migration from .NET Framework.

The scanner never modifies your files.

## What it checks

| Area | What you get |
| --- | --- |
| Projects | Every `.csproj` / `.fsproj` / `.vbproj`: SDK-style or legacy, target framework(s), and a category: **Ready**, **Upgrade** or **Migration** |
| Packages | Microsoft platform packages below 10.x, `PackageReference` without a version, `packages.config`, known deprecated packages (supports `Directory.Packages.props`) |
| Code | Obsolete or removed APIs in .NET 9 / 10: `WebHostBuilder`, `IActionContextAccessor`, `WithOpenApi()`, `KnownNetworks`, Razor runtime compilation, `BinaryFormatter`, `System.Web` |
| Pins | SDK versions in `global.json`, .NET Docker image tags, GitHub Actions and Azure DevOps SDK versions |
| Legacy ASP.NET | `Global.asax`, Web Forms (`.aspx`) and WCF (`.svc`) files that need a partial rewrite |

## Requirements

[PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) on Windows, Linux or macOS. No .NET SDK needed to run the scan.

## Usage

```powershell
# from the root of your repository
pwsh ./Invoke-NetUpgradeScan.ps1

# or point it at a folder and choose the report name
pwsh ./Invoke-NetUpgradeScan.ps1 -Path C:\src\MySolution -OutFile upgrade-report.md

# also write raw results as JSON (for CI or your own tooling)
pwsh ./Invoke-NetUpgradeScan.ps1 -Json
```

On Windows, if scripts are blocked by your execution policy, run it with:

```powershell
pwsh -ExecutionPolicy Bypass -File .\Invoke-NetUpgradeScan.ps1
```

## Example output

```text
NetUpgradeLab Scanner v1.0.0
Scanning C:\src\MySolution (read-only)...

Projects: 4  |  ready: 1  |  upgrade: 2  |  migration: 1
Findings: 3 package, 5 code, 5 SDK/Docker/CI pins
Report:   C:\src\MySolution\netupgrade-report.md
```

## Limitations

- Pattern matching finds likely spots, not every breaking change. After retargeting, build with `dotnet build -warnaserror` against the .NET 10 SDK to surface the rest.
- Third-party NuGet packages are not checked online. Use `dotnet list package --outdated` and `dotnet list package --vulnerable` for that.

## Need a hand?

**NetUpgradeLab** by Northbyte Lab helps teams upgrade to .NET 10 and migrate from .NET Framework. It's run by Jasmin, a .NET developer with 6+ years of professional experience in C#, ASP.NET Core, Blazor, EF Core and SQL Server.

📫 labnorthbyte@gmail.com · [Upgrade service on Fiverr](https://www.fiverr.com/jassoman/upgrade-your-dotnet-framework-or-dotnet-8-app-to-dotnet-10)

## License

MIT

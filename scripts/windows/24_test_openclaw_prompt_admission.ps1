[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$AgentId = 'chef-operations',
    [ValidateRange(30, 300)][int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($DryRun) {
    Write-Host '[DRY-RUN] Contrôle d admission du prompt full-agent OpenClaw.'
    Write-Host "[DRY-RUN] Agent=$AgentId timeout=${TimeoutSeconds}s."
    Write-Host '[DRY-RUN] Exécuter explicitement via openclaw agent --local: ce gate précède le démarrage du Gateway dans install-full.'
    Write-Host '[DRY-RUN] Séparer stdout JSON de stderr diagnostic avant tout ConvertFrom-Json.'
    Write-Host '[DRY-RUN] Exiger skills.limits.maxSkillsPromptChars=0 et agents.defaults.skills vide.'
    Write-Host '[DRY-RUN] Utiliser une session fraîche, thinking=off et une réponse déterministe.'
    Write-Host '[DRY-RUN] Exiger PROMPT_ADMISSION_SKILLS_CHARS=0 et refuser toute meta.error, dont context_overflow.'
    exit 0
}

function Get-PlatformRoot {
    if ($env:OPENCLAW_LOCAL_ROOT) {
        return $env:OPENCLAW_LOCAL_ROOT
    }
    if (Test-Path -LiteralPath 'E:\') {
        return 'E:\AI\OpenClawLocal'
    }
    return (Join-Path $env:LOCALAPPDATA 'OpenClawLocal')
}

function Get-OpenClawCommand([string]$PlatformRoot) {
    $Found = Get-Command openclaw -ErrorAction SilentlyContinue
    if ($Found) {
        return $Found.Source
    }
    $Managed = Join-Path $PlatformRoot 'runtime\npm-global\openclaw.cmd'
    if (Test-Path -LiteralPath $Managed) {
        return $Managed
    }
    throw 'OpenClaw absent. Exécutez install-core.'
}

function Get-AgentEntry {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Id
    )
    $Entries = $Config.agents.PSObject.Properties['entries']
    if ($Entries -and $Entries.Value) {
        $Entry = $Entries.Value.PSObject.Properties[$Id]
        if ($Entry -and $Entry.Value) {
            return $Entry.Value
        }
    }
    $List = $Config.agents.PSObject.Properties['list']
    if ($List -and $List.Value) {
        $Entry = @($List.Value | Where-Object { [string]$_.id -eq $Id }) | Select-Object -First 1
        if ($Entry) {
            return $Entry
        }
    }
    throw "Agent absent de la configuration OpenClaw: $Id"
}

function Assert-ZeroSkillPromptConfig {
    param([Parameter(Mandatory)]$Config)

    $SkillsProperty = $Config.PSObject.Properties['skills']
    if (-not $SkillsProperty -or -not $SkillsProperty.Value) {
        throw 'Contrat prompt skills absent: section skills requise.'
    }
    $LimitsProperty = $SkillsProperty.Value.PSObject.Properties['limits']
    if (-not $LimitsProperty -or -not $LimitsProperty.Value) {
        throw 'Contrat prompt skills absent: skills.limits requis.'
    }
    $LimitProperty = $LimitsProperty.Value.PSObject.Properties['maxSkillsPromptChars']
    if (-not $LimitProperty) {
        throw 'Contrat prompt skills absent: skills.limits.maxSkillsPromptChars requis.'
    }
    $Limit = [int]$LimitProperty.Value
    if ($Limit -ne 0) {
        throw "Contrat prompt skills invalide: maxSkillsPromptChars=$Limit attendu=0."
    }

    $AgentsProperty = $Config.PSObject.Properties['agents']
    if (-not $AgentsProperty -or -not $AgentsProperty.Value) {
        throw 'Contrat prompt skills absent: section agents requise.'
    }
    $DefaultsProperty = $AgentsProperty.Value.PSObject.Properties['defaults']
    if (-not $DefaultsProperty -or -not $DefaultsProperty.Value) {
        throw 'Contrat prompt skills absent: agents.defaults requis.'
    }
    $DefaultSkillsProperty = $DefaultsProperty.Value.PSObject.Properties['skills']
    if (-not $DefaultSkillsProperty) {
        throw 'Contrat prompt skills absent: agents.defaults.skills requis.'
    }
    $DefaultSkillsCount = @($DefaultSkillsProperty.Value).Count
    if ($DefaultSkillsCount -ne 0) {
        throw "Contrat prompt skills invalide: agents.defaults.skills contient $DefaultSkillsCount entrée(s), attendu=0."
    }

    Write-Host "PROMPT_ADMISSION_CONFIG_SKILL_LIMIT=$Limit"
    Write-Host "PROMPT_ADMISSION_CONFIG_DEFAULT_SKILLS=$DefaultSkillsCount"
}

function Get-VisibleText {
    param([Parameter(Mandatory)]$Payload)

    $Result = $Payload.PSObject.Properties['result']
    if ($Result -and $Result.Value) {
        $Meta = $Result.Value.PSObject.Properties['meta']
        if ($Meta -and $Meta.Value) {
            $Visible = $Meta.Value.PSObject.Properties['finalAssistantVisibleText']
            if ($Visible -and -not [string]::IsNullOrWhiteSpace([string]$Visible.Value)) {
                return [string]$Visible.Value
            }
        }
    }
    $Final = $Payload.PSObject.Properties['final']
    if ($Final -and -not [string]::IsNullOrWhiteSpace([string]$Final.Value)) {
        return [string]$Final.Value
    }
    $Payloads = $Payload.PSObject.Properties['payloads']
    if ($Payloads) {
        $Texts = @(
            $Payloads.Value | ForEach-Object {
                $Text = $_.PSObject.Properties['text']
                if ($Text -and -not [string]::IsNullOrWhiteSpace([string]$Text.Value)) {
                    [string]$Text.Value
                }
            }
        )
        if ($Texts.Count -gt 0) {
            return ($Texts -join "`n")
        }
    }
    return ''
}

function Write-PromptBudgetSummary {
    param([Parameter(Mandatory)]$Payload)

    $Result = $Payload.PSObject.Properties['result']
    if (-not $Result -or -not $Result.Value) {
        return
    }
    $Meta = $Result.Value.PSObject.Properties['meta']
    if (-not $Meta -or -not $Meta.Value) {
        return
    }
    $ReportProperty = $Meta.Value.PSObject.Properties['systemPromptReport']
    if (-not $ReportProperty -or -not $ReportProperty.Value) {
        return
    }

    $Report = $ReportProperty.Value
    $SystemPrompt = $Report.PSObject.Properties['systemPrompt']
    $Tools = $Report.PSObject.Properties['tools']
    $Skills = $Report.PSObject.Properties['skills']
    $SkillPromptChars = $null

    if ($SystemPrompt -and $SystemPrompt.Value) {
        $Chars = $SystemPrompt.Value.PSObject.Properties['chars']
        if ($Chars) {
            Write-Host "PROMPT_ADMISSION_SYSTEM_CHARS=$($Chars.Value)"
        }
    }
    if ($Tools -and $Tools.Value) {
        foreach ($Name in @('listChars', 'schemaChars')) {
            $Value = $Tools.Value.PSObject.Properties[$Name]
            if ($Value) {
                Write-Host "PROMPT_ADMISSION_TOOLS_$($Name.ToUpperInvariant())=$($Value.Value)"
            }
        }
    }
    if ($Skills -and $Skills.Value) {
        $Chars = $Skills.Value.PSObject.Properties['promptChars']
        if ($Chars) {
            $SkillPromptChars = [int]$Chars.Value
            Write-Host "PROMPT_ADMISSION_SKILLS_CHARS=$SkillPromptChars"
        }
    }

    if ($null -ne $SkillPromptChars) {
        return $SkillPromptChars
    }
}

$PlatformRoot = Get-PlatformRoot
$StateDir = Join-Path $PlatformRoot 'state'
$ProofsRoot = Join-Path $PlatformRoot 'proofs'
$ConfigPath = Join-Path $StateDir 'openclaw.json'
$OpenClaw = Get-OpenClawCommand $PlatformRoot

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw 'Configuration OpenClaw absente avant le contrôle d admission.'
}
New-Item -ItemType Directory -Path $ProofsRoot -Force | Out-Null

$env:OPENCLAW_STATE_DIR = $StateDir
$env:OLLAMA_API_KEY = 'ollama-local'
$env:INTEL_SYCL_API_KEY = 'intel-sycl-local'
$env:INTEL_VULKAN_API_KEY = 'intel-vulkan-local'
$env:OPENCLAW_LOCAL_CLOUD_ENABLED = 'false'

$Config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
Assert-ZeroSkillPromptConfig -Config $Config
$Agent = Get-AgentEntry -Config $Config -Id $AgentId
$ModelRef = [string]$Agent.model.primary
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmssfff'
$EvidencePath = Join-Path $ProofsRoot "openclaw_prompt_admission_$Stamp.json"
$SessionKey = "configure-admission-$Stamp-$AgentId"
$Expected = "PROMPT_ADMISSION_OK $AgentId"
$Prompt = "N'utilise aucun outil. Réponds immédiatement en une ligne avec exactement: $Expected"
$ExecutionMode = 'local'
$StdoutPath = Join-Path $ProofsRoot ".openclaw_prompt_admission_${Stamp}_${AgentId}.stdout.tmp"
$StderrPath = Join-Path $ProofsRoot ".openclaw_prompt_admission_${Stamp}_${AgentId}.stderr.tmp"

Write-Host "ADMISSION  Agent=$AgentId modèle=$ModelRef timeout=${TimeoutSeconds}s mode=$ExecutionMode"
Write-Host "PROMPT_ADMISSION_MODE=$ExecutionMode"
# Ce gate est exécuté par configure-openclaw avant install/start du Gateway dans
# install-full. --local évite donc une dépendance circulaire tout en exécutant
# réellement le même agent, sa configuration, son prompt système et son modèle.
# OpenClaw 2026.9.4 peut émettre ses diagnostics agent sur stderr même avec
# --json. stdout reste le contrat JSON machine-readable et doit être parsé seul.
$StdoutText = ''
$StderrText = ''
try {
    & $OpenClaw 'agent' '--local' '--agent' $AgentId `
        '--session-key' $SessionKey '--message' $Prompt '--thinking' 'off' `
        '--timeout' ([string]$TimeoutSeconds) '--json' 1> $StdoutPath 2> $StderrPath
    $ExitCode = $LASTEXITCODE
    if (Test-Path -LiteralPath $StdoutPath) {
        $StdoutText = (Get-Content -Raw -LiteralPath $StdoutPath).Trim()
    }
    if (Test-Path -LiteralPath $StderrPath) {
        $StderrText = (Get-Content -Raw -LiteralPath $StderrPath).Trim()
    }
}
finally {
    Remove-Item -LiteralPath $StdoutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StderrPath -Force -ErrorAction SilentlyContinue
}

if (-not [string]::IsNullOrWhiteSpace($StderrText)) {
    Write-Host $StderrText
}

if ($ExitCode -ne 0) {
    [ordered]@{
        schema_version = '1.2.0'
        timestamp_utc = [DateTime]::UtcNow.ToString('o')
        execution_mode = $ExecutionMode
        agent = $AgentId
        model_ref = $ModelRef
        exit_code = $ExitCode
        stdout = $StdoutText
        stderr = $StderrText
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
    Write-Host "PROMPT_ADMISSION_EVIDENCE=$EvidencePath"
    throw "Contrôle d admission OpenClaw en échec processus (code $ExitCode)."
}

try {
    $Payload = $StdoutText | ConvertFrom-Json
}
catch {
    [ordered]@{
        schema_version = '1.2.0'
        timestamp_utc = [DateTime]::UtcNow.ToString('o')
        execution_mode = $ExecutionMode
        agent = $AgentId
        model_ref = $ModelRef
        exit_code = $ExitCode
        stdout = $StdoutText
        stderr = $StderrText
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
    Write-Host "PROMPT_ADMISSION_EVIDENCE=$EvidencePath"
    throw 'Contrôle d admission OpenClaw: stdout JSON invalide.'
}

$Payload | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
Write-Host "PROMPT_ADMISSION_EVIDENCE=$EvidencePath"
$SkillPromptChars = Write-PromptBudgetSummary -Payload $Payload
if ($null -eq $SkillPromptChars) {
    throw "Contrat prompt skills OpenClaw non mesurable: systemPromptReport.skills.promptChars absent. preuve=$EvidencePath"
}
if ([int]$SkillPromptChars -ne 0) {
    throw "Contrat prompt skills OpenClaw non respecté: skillsPromptChars=$SkillPromptChars attendu=0. preuve=$EvidencePath"
}

$Result = $Payload.PSObject.Properties['result']
if (-not $Result -or -not $Result.Value) {
    throw 'Contrôle d admission OpenClaw sans résultat agent.'
}
$Meta = $Result.Value.PSObject.Properties['meta']
if (-not $Meta -or -not $Meta.Value) {
    throw 'Contrôle d admission OpenClaw sans métadonnées agent.'
}
$ErrorProperty = $Meta.Value.PSObject.Properties['error']
if ($ErrorProperty -and $ErrorProperty.Value) {
    $KindProperty = $ErrorProperty.Value.PSObject.Properties['kind']
    $MessageProperty = $ErrorProperty.Value.PSObject.Properties['message']
    $Kind = if ($KindProperty) { [string]$KindProperty.Value } else { '' }
    $Message = if ($MessageProperty) { [string]$MessageProperty.Value } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($Kind) -or -not [string]::IsNullOrWhiteSpace($Message)) {
        throw "Contrôle d admission OpenClaw refusé: kind=$Kind message=$Message preuve=$EvidencePath"
    }
}

$Visible = (Get-VisibleText -Payload $Payload).Trim()
if ($Visible -ne $Expected) {
    throw "Contrôle d admission OpenClaw réponse inattendue. Attendu='$Expected' Reçu='$Visible' preuve=$EvidencePath"
}

Write-Host "OK  Admission prompt OpenClaw validée: $AgentId -> $ModelRef"
exit 0
Set-StrictMode -Version Latest

function Assert-OpenClawReadOnlySteadyState {
    $ProcessValue = $env:OPENCLAW_CONFIG_READONLY
    $UserValue = [Environment]::GetEnvironmentVariable('OPENCLAW_CONFIG_READONLY', 'User')
    if ($ProcessValue -ne '1') {
        throw "OPENCLAW_CONFIG_READONLY process doit valoir 1 hors fenêtre d'écriture (reçu=$ProcessValue)."
    }
    if ($UserValue -ne '1') {
        throw "OPENCLAW_CONFIG_READONLY User doit valoir 1 hors fenêtre d'écriture (reçu=$UserValue)."
    }
}

function Set-OpenClawReadOnlySteadyState {
    $env:OPENCLAW_CONFIG_READONLY = '1'
    [Environment]::SetEnvironmentVariable('OPENCLAW_CONFIG_READONLY', '1', 'User')
    Assert-OpenClawReadOnlySteadyState
}

function Invoke-OpenClawConfigWriteWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Operation)

    Set-OpenClawReadOnlySteadyState
    $PersistentValue = [Environment]::GetEnvironmentVariable('OPENCLAW_CONFIG_READONLY', 'User')
    if ($PersistentValue -ne '1') {
        throw 'Fenêtre d écriture refusée: le mode User persistant n est pas READONLY=1.'
    }

    $env:OPENCLAW_CONFIG_READONLY = '0'
    if ($env:OPENCLAW_CONFIG_READONLY -ne '0') {
        throw 'Impossible d ouvrir la fenêtre d écriture OpenClaw dans le process courant.'
    }
    if ([Environment]::GetEnvironmentVariable('OPENCLAW_CONFIG_READONLY', 'User') -ne '1') {
        throw 'Fenêtre d écriture refusée: la valeur User a été modifiée.'
    }

    try {
        & $Operation
    }
    finally {
        Set-OpenClawReadOnlySteadyState
    }
}

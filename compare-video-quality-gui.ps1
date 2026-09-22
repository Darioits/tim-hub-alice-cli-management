<#
.SYNOPSIS
    GUI (Windows Forms) per compare-video-quality: seleziona le due cartelle
    sorgente, imposta i parametri e avvia il confronto senza usare la riga
    di comando.

.DESCRIPTION
    Interfaccia grafica per VideoQualityCompareCore.psm1 (la stessa logica
    usata da compare-video-quality.ps1). Richiede Windows (Windows Forms)
    e ffmpeg/ffprobe nel PATH.

.NOTES
    Va lanciata su Windows. Se l'esecuzione e' bloccata dalla execution
    policy, avviala cosi':
        powershell -ExecutionPolicy Bypass -File .\compare-video-quality-gui.ps1
#>

[CmdletBinding()]
param(
    # Parametri usati solo per il test automatico non interattivo (CI): quando
    # -SmokeTest e' presente, la GUI si autocompila i campi, simula il click
    # su "Avvia confronto" e si chiude da sola invece di aspettare l'utente.
    # Non servono per l'uso normale.
    [switch]$SmokeTest,
    [string]$SmokeTestDirA,
    [string]$SmokeTestDirB,
    [string]$SmokeTestOutDir
)

$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
if (-not $onWindows) {
    Write-Error "Questa GUI richiede Windows (Windows Forms non e' disponibile su questo sistema operativo). Su Linux/macOS usa compare-video-quality.sh da terminale."
    exit 1
}

# Windows Forms richiede il thread in modalita' STA. PowerShell 5.1 (powershell.exe)
# di norma parte gia' in STA, ma PowerShell 7+ (pwsh.exe) puo' partire in MTA: in
# quel caso i dialoghi (es. la scelta della cartella) lancerebbero un'eccezione.
# Se non siamo in STA, ci rilanciamo da soli con -STA e usciamo dal processo corrente.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $exeName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $psExe = Join-Path $PSHOME $exeName
    $relaunchArgs = @('-NoProfile', '-STA', '-File', "`"$PSCommandPath`"")
    if ($SmokeTest) {
        $relaunchArgs += @('-SmokeTest', '-SmokeTestDirA', "`"$SmokeTestDirA`"", '-SmokeTestDirB', "`"$SmokeTestDirB`"", '-SmokeTestOutDir', "`"$SmokeTestOutDir`"")
    }
    $proc = Start-Process -FilePath $psExe -ArgumentList $relaunchArgs -PassThru -Wait
    exit $proc.ExitCode
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}
catch {
    Write-Error "Impossibile caricare Windows Forms: $($_.Exception.Message)"
    exit 1
}

Import-Module (Join-Path $PSScriptRoot "VideoQualityCompareCore.psm1") -Force

# ---- stato condiviso tra GUI e worker in background ----
$script:CancelRequested = $false
$script:IsRunning = $false

##---------------------------- COSTRUZIONE FINESTRA --------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "Confronto qualita' video"
$form.Size = New-Object System.Drawing.Size(760, 620)
$form.MinimumSize = New-Object System.Drawing.Size(600, 450)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = "Fill"
$layout.ColumnCount = 3
$layout.Padding = New-Object System.Windows.Forms.Padding(10)
$layout.RowCount = 7
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 22)))
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 68)))
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 10)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 32)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$form.Controls.Add($layout)

function New-Label($text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.TextAlign = "MiddleLeft"
    $l.Dock = "Fill"
    return $l
}
function New-BrowseButton {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = "Sfoglia..."
    $b.Dock = "Fill"
    return $b
}

# --- riga 0: Cartella A ---
$layout.Controls.Add((New-Label "Cartella A (sorgente 1):"), 0, 0)
$txtDirA = New-Object System.Windows.Forms.TextBox
$txtDirA.Dock = "Fill"
$layout.Controls.Add($txtDirA, 1, 0)
$btnDirA = New-BrowseButton
$layout.Controls.Add($btnDirA, 2, 0)

# --- riga 1: Cartella B ---
$layout.Controls.Add((New-Label "Cartella B (sorgente 2):"), 0, 1)
$txtDirB = New-Object System.Windows.Forms.TextBox
$txtDirB.Dock = "Fill"
$layout.Controls.Add($txtDirB, 1, 1)
$btnDirB = New-BrowseButton
$layout.Controls.Add($btnDirB, 2, 1)

# --- riga 2: Cartella output ---
$layout.Controls.Add((New-Label "Cartella report/output:"), 0, 2)
$txtOutDir = New-Object System.Windows.Forms.TextBox
$txtOutDir.Dock = "Fill"
$txtOutDir.Text = Join-Path (Get-Location) "video-quality-report"
$layout.Controls.Add($txtOutDir, 1, 2)
$btnOutDir = New-BrowseButton
$layout.Controls.Add($btnOutDir, 2, 2)

# --- riga 3: parametri (campioni) ---
$paramPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$paramPanel.Dock = "Fill"
$paramPanel.FlowDirection = "LeftToRight"
$paramPanel.WrapContents = $false
$lblSamples = New-Object System.Windows.Forms.Label
$lblSamples.Text = "Campioni per video:"
$lblSamples.AutoSize = $true
$lblSamples.Margin = New-Object System.Windows.Forms.Padding(0, 8, 6, 0)
$numSamples = New-Object System.Windows.Forms.NumericUpDown
$numSamples.Minimum = 1
$numSamples.Maximum = 30
$numSamples.Value = 5
$numSamples.Width = 60
$paramPanel.Controls.Add($lblSamples)
$paramPanel.Controls.Add($numSamples)
$layout.Controls.Add($paramPanel, 0, 3)
$layout.SetColumnSpan($paramPanel, 3)

# --- riga 4: pulsanti azione ---
$actionPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$actionPanel.Dock = "Fill"
$actionPanel.FlowDirection = "LeftToRight"
$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "Avvia confronto"
$btnStart.Width = 130
$btnStart.Height = 30
$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "Annulla"
$btnCancel.Width = 90
$btnCancel.Height = 30
$btnCancel.Enabled = $false
$btnOpenReport = New-Object System.Windows.Forms.Button
$btnOpenReport.Text = "Apri cartella report"
$btnOpenReport.Width = 150
$btnOpenReport.Height = 30
$btnOpenReport.Enabled = $false
$actionPanel.Controls.Add($btnStart)
$actionPanel.Controls.Add($btnCancel)
$actionPanel.Controls.Add($btnOpenReport)
$layout.Controls.Add($actionPanel, 0, 4)
$layout.SetColumnSpan($actionPanel, 3)

# --- riga 5: barra di avanzamento + stato ---
$statusPanel = New-Object System.Windows.Forms.TableLayoutPanel
$statusPanel.Dock = "Fill"
$statusPanel.ColumnCount = 2
[void]$statusPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 40)))
[void]$statusPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 60)))
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Dock = "Fill"
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Dock = "Fill"
$lblStatus.TextAlign = "MiddleLeft"
$lblStatus.Text = "Pronto."
$statusPanel.Controls.Add($progressBar, 0, 0)
$statusPanel.Controls.Add($lblStatus, 1, 0)
$layout.Controls.Add($statusPanel, 0, 5)
$layout.SetColumnSpan($statusPanel, 3)

# --- riga 6: log ---
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Dock = "Fill"
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$layout.Controls.Add($txtLog, 0, 6)
$layout.SetColumnSpan($txtLog, 3)

##---------------------------- FUNZIONI DI SUPPORTO ---------------------------

function Select-Folder {
    param([string]$InitialPath)
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath)) { $dlg.SelectedPath = $InitialPath }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

function Append-Log {
    param([string]$Message)
    $txtLog.AppendText("$Message`r`n")
}

function Set-RunningState {
    param([bool]$Running)
    $script:IsRunning = $Running
    $btnStart.Enabled = -not $Running
    $btnCancel.Enabled = $Running
    $txtDirA.Enabled = -not $Running
    $txtDirB.Enabled = -not $Running
    $txtOutDir.Enabled = -not $Running
    $numSamples.Enabled = -not $Running
    $btnDirA.Enabled = -not $Running
    $btnDirB.Enabled = -not $Running
    $btnOutDir.Enabled = -not $Running
}

##---------------------------- EVENTI ------------------------------------

$btnDirA.Add_Click({
    $sel = Select-Folder -InitialPath $txtDirA.Text
    if ($sel) { $txtDirA.Text = $sel }
})
$btnDirB.Add_Click({
    $sel = Select-Folder -InitialPath $txtDirB.Text
    if ($sel) { $txtDirB.Text = $sel }
})
$btnOutDir.Add_Click({
    $sel = Select-Folder -InitialPath $txtOutDir.Text
    if ($sel) { $txtOutDir.Text = $sel }
})

$btnCancel.Add_Click({
    $script:CancelRequested = $true
    $lblStatus.Text = "Annullamento in corso..."
})

$btnOpenReport.Add_Click({
    if ($script:LastOutDir -and (Test-Path -LiteralPath $script:LastOutDir)) {
        Start-Process explorer.exe -ArgumentList "`"$($script:LastOutDir)`""
    }
})

$btnStart.Add_Click({
    if ($script:IsRunning) { return }

    if ([string]::IsNullOrWhiteSpace($txtDirA.Text) -or [string]::IsNullOrWhiteSpace($txtDirB.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Seleziona sia la cartella A sia la cartella B.", "Parametri mancanti", "OK", "Warning") | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $txtDirA.Text -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("La cartella A non esiste:`n$($txtDirA.Text)", "Errore", "OK", "Error") | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $txtDirB.Text -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("La cartella B non esiste:`n$($txtDirB.Text)", "Errore", "OK", "Error") | Out-Null
        return
    }

    $txtLog.Clear()
    $progressBar.Value = 0
    $lblStatus.Text = "Ricerca dei file in corso..."
    $btnOpenReport.Enabled = $false
    $script:CancelRequested = $false
    Set-RunningState $true
    [System.Windows.Forms.Application]::DoEvents()

    $logAction = {
        param($Message)
        Append-Log $Message
        [System.Windows.Forms.Application]::DoEvents()
    }
    $progressCallback = {
        param($Current, $Total, $Label)
        if ($Total -gt 0) {
            $pct = [int](100 * $Current / $Total)
            if ($pct -gt 100) { $pct = 100 }
            $progressBar.Value = $pct
        }
        $lblStatus.Text = "Coppia $Current/$Total`: $Label"
        [System.Windows.Forms.Application]::DoEvents()
    }
    $shouldCancel = { return $script:CancelRequested }

    try {
        $result = Invoke-VideoQualityComparison `
            -DirA $txtDirA.Text -DirB $txtDirB.Text -OutDir $txtOutDir.Text `
            -NumSamples ([int]$numSamples.Value) `
            -LogAction $logAction -ProgressCallback $progressCallback -ShouldCancel $shouldCancel

        $script:LastOutDir = $result.OutDir
        $script:LastResult = $result
        if ($result.PairsFound -eq 0) {
            $lblStatus.Text = "Nessun file corrispondente trovato."
        } elseif ($result.Cancelled) {
            $lblStatus.Text = "Annullato: elaborate $($result.PairsProcessed) di $($result.PairsFound) coppie."
            $btnOpenReport.Enabled = $true
        } else {
            $progressBar.Value = 100
            $lblStatus.Text = "Completato: $($result.PairsFound) coppie analizzate."
            $btnOpenReport.Enabled = $true
            if (-not $SmokeTest) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Confronto completato.`n$($result.PairsFound) coppie analizzate.`n`nReport: $($result.ReportMd)",
                    "Fatto", "OK", "Information") | Out-Null
            }
        }
    }
    catch {
        $lblStatus.Text = "Errore."
        $script:LastError = $_.Exception.Message
        Append-Log "ERRORE: $($_.Exception.Message)"
        if (-not $SmokeTest) {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Errore", "OK", "Error") | Out-Null
        }
    }
    finally {
        Set-RunningState $false
    }
})

if ($SmokeTest) {
    # test automatico non interattivo (CI): compila i campi, simula il click
    # sul pulsante reale (stesso percorso di codice dell'uso normale) e chiude
    # la finestra da sola, senza bisogno di un utente davanti allo schermo
    $form.Add_Shown({
        $txtDirA.Text = $SmokeTestDirA
        $txtDirB.Text = $SmokeTestDirB
        $txtOutDir.Text = $SmokeTestOutDir
        $btnStart.PerformClick()
        $form.Close()
    })
    [void]$form.ShowDialog()

    if ($script:LastError) {
        Write-Host "SMOKE TEST FALLITO: $($script:LastError)"
        exit 1
    }
    if (-not $script:LastResult -or $script:LastResult.PairsFound -eq 0) {
        Write-Host "SMOKE TEST FALLITO: nessuna coppia trovata/elaborata."
        exit 1
    }
    Write-Host "SMOKE TEST OK: $($script:LastResult.PairsFound) coppie, report in $($script:LastResult.ReportMd)"
    exit 0
}

$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()

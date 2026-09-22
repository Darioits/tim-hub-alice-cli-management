<#
.SYNOPSIS
    Confronta la qualita' dei video con lo stesso nome (o release diverse
    dello stesso titolo) presenti in due cartelle diverse, comprese le
    sottocartelle, e aiuta a decidere quale copia tenere.

.DESCRIPTION
    La ricerca dei file e' RICORSIVA in entrambe le cartelle, e l'abbinamento
    avviene sul nome normalizzato (minuscolo, senza tag tecnici comuni come
    risoluzione/source/codec/audio/lingua/release group): "Il Film (2020).mkv"
    e "Il.Film.2020.1080p.BluRay.x264-GROUP.mp4" vengono riconosciuti come lo
    stesso video. E' un confronto volutamente prudente (solo match esatto dopo
    la normalizzazione, niente somiglianza approssimata) per ridurre il rischio
    di abbinare per errore due video diversi.

    Per ogni coppia di file corrispondenti:
      - legge risoluzione, bitrate e codec con ffprobe
      - estrae N fotogrammi campione (agli stessi istanti relativi) e ne
        misura la nitidezza reale con il filtro ffmpeg "blurdetect"
      - genera screenshot affiancati A/B per il confronto visivo
      - calcola un punteggio orientativo e propone quale file tenere

    La decisione finale resta dell'utente: lo script NON cancella e NON
    sposta nulla, produce solo un report (report.md, report.csv) e uno
    script di supporto (move-losers.ps1) con i comandi "Move-Item" GIA'
    COMMENTATI, da rivedere ed eseguire manualmente.

    E' disponibile anche una GUI equivalente: compare-video-quality-gui.ps1
    (nella stessa cartella di questo script).

.PARAMETER DirA
    Prima cartella da confrontare.

.PARAMETER DirB
    Seconda cartella da confrontare (stessi nomi file = stesso video).

.PARAMETER OutDir
    Dove salvare report e screenshot (default: .\video-quality-report).

.PARAMETER NumSamples
    Quanti punti nel video campionare (default: 5).

.EXAMPLE
    .\compare-video-quality.ps1 "D:\Serie_v1" "E:\Serie_v2"

.EXAMPLE
    .\compare-video-quality.ps1 -DirA "D:\A" -DirB "D:\B" -OutDir ".\report" -NumSamples 7

.NOTES
    Dipendenze: ffmpeg e ffprobe devono essere installati e presenti nel PATH.
    Download: https://www.gyan.dev/ffmpeg/builds/ (build "essentials", aggiungi
    la cartella bin al PATH di Windows).

    Se l'esecuzione dello script e' bloccata da Windows, avvialo cosi':
        powershell -ExecutionPolicy Bypass -File .\compare-video-quality.ps1 <dirA> <dirB>
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$DirA,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$DirB,

    [Parameter(Position = 2)]
    [string]$OutDir = ".\video-quality-report",

    [Parameter(Position = 3)]
    [int]$NumSamples = 5
)

Import-Module (Join-Path $PSScriptRoot "VideoQualityCompareCore.psm1") -Force

try {
    Invoke-VideoQualityComparison -DirA $DirA -DirB $DirB -OutDir $OutDir -NumSamples $NumSamples | Out-Null
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

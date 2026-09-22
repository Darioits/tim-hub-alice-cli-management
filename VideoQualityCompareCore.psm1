<#
    VideoQualityCompareCore.psm1

    Logica condivisa di confronto qualita' video, usata sia da
    compare-video-quality.ps1 (CLI) sia da compare-video-quality-gui.ps1 (GUI).
    Vedi i commenti in compare-video-quality.ps1 per la descrizione completa
    del funzionamento (normalizzazione nomi, punteggio, ecc).
#>

function Invoke-VideoQualityComparison {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirA,

        [Parameter(Mandatory = $true)]
        [string]$DirB,

        [string]$OutDir = ".\video-quality-report",

        [int]$NumSamples = 5,

        # invocata con un singolo parametro stringa per ogni riga di log
        [scriptblock]$LogAction = { param($Message) Write-Host $Message },

        # invocata con (Current, Total, Label) prima di elaborare ogni coppia
        # nome diverso da "ProgressAction" apposta: da PowerShell 7.4 e' un
        # parametro comune riservato su ogni funzione con [CmdletBinding()]
        [scriptblock]$ProgressCallback = $null,

        # invocata senza parametri prima di ogni coppia; se restituisce $true
        # l'elaborazione si interrompe (il report parziale viene comunque scritto)
        [scriptblock]$ShouldCancel = $null
    )

    $ErrorActionPreference = "Stop"
    $InvCulture = [System.Globalization.CultureInfo]::InvariantCulture

    function Log { param($Message) & $LogAction $Message }
    function Report-Progress {
        param($Current, $Total, $Label)
        if ($ProgressCallback) { & $ProgressCallback $Current $Total $Label }
    }

    ##---------------------------- CONFIG -----------------------------------
    $ShotW = 480                  # dimensioni tela screenshot di confronto
    $ShotH = 270
    $DurToleranceParam = 5        # oltre questa differenza % di durata, viene segnalato

    # Pesi del punteggio orientativo (somma = 1): risoluzione, nitidezza, bit/pixel
    $W_RES = 0.35
    $W_SHARP = 0.45
    $W_BPP = 0.20
    ##-------------------------- END CONFIG ----------------------------------

    # ---- controlli iniziali ----
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        throw "ffmpeg non trovato nel PATH. Installalo (https://www.gyan.dev/ffmpeg/builds/) e riprova."
    }
    if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
        throw "ffprobe non trovato nel PATH. Fa parte dello stesso pacchetto di ffmpeg."
    }
    if (-not (Test-Path -LiteralPath $DirA -PathType Container)) {
        throw "'$DirA' non e' una cartella valida."
    }
    if (-not (Test-Path -LiteralPath $DirB -PathType Container)) {
        throw "'$DirB' non e' una cartella valida."
    }
    $fullA = (Resolve-Path -LiteralPath $DirA).ProviderPath
    $fullB = (Resolve-Path -LiteralPath $DirB).ProviderPath
    if ($fullA -ieq $fullB) {
        throw "DirA e DirB puntano alla stessa cartella."
    }
    if ($NumSamples -lt 1) { $NumSamples = 1 }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $OutDir = (Resolve-Path -LiteralPath $OutDir).ProviderPath

    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
    if ($onWindows) {
        $WorkTmp = Join-Path $env:TEMP ("vqcmp_" + [guid]::NewGuid().ToString("N"))
    } else {
        $WorkTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("vqcmp_" + [guid]::NewGuid().ToString("N"))
    }
    New-Item -ItemType Directory -Force -Path $WorkTmp | Out-Null

    try {
        $ReportMd = Join-Path $OutDir "report.md"
        $ReportCsv = Join-Path $OutDir "report.csv"
        $MoveScript = Join-Path $OutDir "move-losers.ps1"

        # font per le etichette A/B sugli screenshot (best-effort, opzionale)
        $fontCandidates = @(
            "$env:WINDIR\Fonts\arial.ttf",
            "$env:WINDIR\Fonts\segoeui.ttf",
            "$env:WINDIR\Fonts\calibri.ttf",
            "$env:WINDIR\Fonts\consola.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
            "/System/Library/Fonts/Helvetica.ttc",
            "/Library/Fonts/Arial.ttf"
        )
        $LabelFont = $null
        foreach ($f in $fontCandidates) {
            if ($f -and (Test-Path -LiteralPath $f -PathType Leaf)) { $LabelFont = $f; break }
        }

        ##--------------------------- FUNZIONI --------------------------------

        function ConvertTo-Double {
            param([string]$Value, [double]$Default = 0.0)
            if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
            $result = 0.0
            if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, $InvCulture, [ref]$result)) {
                return $result
            }
            return $Default
        }

        function Fmt {
            param([double]$Value, [string]$Format = "0.000000")
            return $Value.ToString($Format, $InvCulture)
        }

        function ConvertTo-SafeFileName {
            param([string]$Name)
            # elenco fisso dei caratteri non ammessi nei nomi file/cartella su
            # Windows (non si usa [IO.Path]::GetInvalidFileNameChars(): riflette
            # l'OS di esecuzione, non quello di destinazione)
            return ($Name -replace '[\\/:*?"<>|]', '_')
        }

        function Format-Time {
            param([double]$Seconds)
            $s = [int]$Seconds
            return "{0:D2}:{1:D2}" -f [int]($s / 60), ($s % 60)
        }

        function Format-Size {
            param([double]$Bytes)
            if ($Bytes -le 0) { return "n/d" }
            $gb = $Bytes / 1GB
            $mb = $Bytes / 1MB
            if ($gb -ge 1) { return (Fmt $gb "0.00") + " GB" }
            return (Fmt $mb "0.0") + " MB"
        }

        function Get-ProbeInfo {
            param([string]$Path)
            $ffArgs = @(
                '-v', 'error', '-select_streams', 'v:0',
                '-show_entries', 'stream=width,height,codec_name,bit_rate,r_frame_rate',
                '-show_entries', 'format=duration,size,bit_rate',
                '-of', 'json', '--', $Path
            )
            $json = & ffprobe @ffArgs 2>$null | Out-String
            if ([string]::IsNullOrWhiteSpace($json)) { return $null }
            try { return $json | ConvertFrom-Json } catch { return $null }
        }

        function Get-FpsFromRate {
            param([string]$Rate)
            if ([string]::IsNullOrWhiteSpace($Rate)) { return 25.0 }
            $parts = $Rate -split '/'
            if ($parts.Count -eq 2) {
                $den = ConvertTo-Double $parts[1]
                if ($den -gt 0) { return (ConvertTo-Double $parts[0]) / $den }
            }
            return 25.0
        }

        function ConvertTo-FfmpegFontPath {
            param([string]$Path)
            $p = $Path -replace '\\', '/'
            $p = $p -replace ':', '\:'
            return $p
        }

        # normalizza un nome file (senza estensione) per riconoscere release
        # diverse dello stesso video: minuscolo, separatori uniformati, tag
        # tecnici comuni (risoluzione/source/codec/audio/lingua/release group)
        # rimossi. es: "Il.Film.2020.1080p.BluRay.x264-GROUP" e
        # "Il Film (2020)" -> "il film 2020"
        $TechTagPattern = '\b(2160p|1080p|720p|480p|360p|4k|uhd|hdr|hd|sd|' +
            'bluray|blu-ray|bdrip|brrip|bdremux|remux|web-?dl|webrip|hdtv|dvdrip|dvdscr|dvd|dsnp|amzn|nf|hmax|atvp|' +
            'x264|x265|h264|h265|hevc|avc|xvid|divx|10bit|8bit|' +
            'aac|ac3|dts|dd5 1|dd\+|eac3|flac|mp3|5 1|7 1|2 0|' +
            'ita|eng|engita|itaeng|multi|sub|subs|subbed|dual|dl|' +
            'repack|proper|extended|uncut|remastered|complete|internal|limited)\b'

        function Get-NormalizedName {
            param([string]$Name)
            $yearMatch = [Regex]::Match($Name, '(19[0-9]{2}|20[0-9]{2})')
            $year = $null
            if ($yearMatch.Success) { $year = $yearMatch.Value }

            $s = $Name.ToLowerInvariant()
            $s = $s -replace '[._]+', ' '
            $s = $s -replace '\[[^\]]*\]', ''
            $s = $s -replace '\{[^\}]*\}', ''
            $s = $s -replace $TechTagPattern, ''
            $s = $s -replace '-[a-z0-9]+$', ''
            $s = $s -replace "['""(),!:;]", ''

            if ($year -and ($s -notlike "*$year*")) { $s = "$s $year" }

            $s = ($s -replace '\s+', ' ').Trim()
            return $s
        }

        # estrae in un'unica passata ffmpeg: nitidezza (blurdetect, risoluzione
        # nativa) + miniatura in tela fissa ShotW x ShotH (per il confronto
        # affiancato)
        function Get-SampleFrame {
            param([double]$Ts, [string]$Video, [string]$ThumbPath)
            $log = Join-Path $WorkTmp "blur.log"
            $tsStr = Fmt $Ts "0.000000"
            $filter = "[0:v]split=2[v1][v2];[v1]blurdetect=block_width=32:block_height=32[vb];" +
                      "[v2]scale=${ShotW}:${ShotH}:force_original_aspect_ratio=decrease,pad=${ShotW}:${ShotH}:(ow-iw)/2:(oh-ih)/2[vt]"
            $ffArgs = @(
                '-y', '-ss', $tsStr, '-i', $Video, '-hide_banner', '-loglevel', 'info',
                '-filter_complex', $filter,
                '-map', '[vb]', '-frames:v', '1', '-f', 'null', '-',
                '-map', '[vt]', '-frames:v', '1', '-q:v', '3', $ThumbPath
            )
            & ffmpeg @ffArgs 1>$null 2>$log
            if (Test-Path -LiteralPath $ThumbPath -PathType Leaf) {
                $match = Select-String -LiteralPath $log -Pattern 'blur mean:\s*([0-9.]+)' | Select-Object -First 1
                if ($match) { return ConvertTo-Double $match.Matches[0].Groups[1].Value }
            }
            return $null
        }

        # combina due miniature gia' pronte in un unico jpg affiancato con
        # etichette A/B
        function Merge-SideBySide {
            param([string]$ImgA, [string]$ImgB, [string]$Out)
            if ($LabelFont) {
                $fontPath = ConvertTo-FfmpegFontPath $LabelFont
                $vfA = "drawtext=fontfile='$fontPath':text='A':fontcolor=yellow:fontsize=20:x=8:y=8:box=1:boxcolor=black@0.5"
                $vfB = "drawtext=fontfile='$fontPath':text='B':fontcolor=yellow:fontsize=20:x=8:y=8:box=1:boxcolor=black@0.5"
                $filter = "[0:v]$vfA[a];[1:v]$vfB[b];[a][b]hstack=inputs=2[out]"
                $ffArgs = @('-y', '-hide_banner', '-loglevel', 'error', '-i', $ImgA, '-i', $ImgB,
                            '-filter_complex', $filter, '-map', '[out]', '-frames:v', '1', $Out)
                & ffmpeg @ffArgs 2>$null
                if (Test-Path -LiteralPath $Out -PathType Leaf) { return }
            }
            $ffArgs = @('-y', '-hide_banner', '-loglevel', 'error', '-i', $ImgA, '-i', $ImgB,
                        '-filter_complex', 'hstack=inputs=2', '-frames:v', '1', $Out)
            & ffmpeg @ffArgs 2>$null
        }

        ##---------------------------- MATCHING FILE --------------------------

        $filesA = @{}
        foreach ($f in Get-ChildItem -LiteralPath $fullA -File -Recurse) {
            $key = Get-NormalizedName ([IO.Path]::GetFileNameWithoutExtension($f.Name))
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            if ($filesA.ContainsKey($key) -and $filesA[$key] -ne $f.FullName) {
                Log "Attenzione: in '$fullA' '$($f.FullName)' si normalizza come '$($filesA[$key])' (stesso nome dopo la pulizia dei tag). Tengo solo il secondo trovato."
            }
            $filesA[$key] = $f.FullName
        }
        $filesB = @{}
        foreach ($f in Get-ChildItem -LiteralPath $fullB -File -Recurse) {
            $key = Get-NormalizedName ([IO.Path]::GetFileNameWithoutExtension($f.Name))
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            if ($filesB.ContainsKey($key) -and $filesB[$key] -ne $f.FullName) {
                Log "Attenzione: in '$fullB' '$($f.FullName)' si normalizza come '$($filesB[$key])' (stesso nome dopo la pulizia dei tag). Tengo solo il secondo trovato."
            }
            $filesB[$key] = $f.FullName
        }
        $commonKeys = $filesA.Keys | Where-Object { $filesB.ContainsKey($_) } | Sort-Object

        if (-not $commonKeys -or $commonKeys.Count -eq 0) {
            Log "Nessun file con lo stesso nome trovato tra le due cartelle."
            return [PSCustomObject]@{
                PairsFound = 0
                PairsProcessed = 0
                Cancelled  = $false
                ReportMd   = $null
                ReportCsv  = $null
                MoveScript = $null
                OutDir     = $OutDir
            }
        }

        Log "Trovate $($commonKeys.Count) coppie di file con lo stesso nome. Avvio analisi..."
        Log ""

        ##---------------------------- INTESTAZIONI REPORT --------------------

        $mdLines = New-Object System.Collections.Generic.List[string]
        $mdLines.Add("# Report confronto qualita' video")
        $mdLines.Add("")
        $mdLines.Add("- Cartella A: ``$fullA``")
        $mdLines.Add("- Cartella B: ``$fullB``")
        $mdLines.Add("- Generato il: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $mdLines.Add("- Campioni per video: $NumSamples")
        $mdLines.Add("")
        $mdLines.Add("Ogni riga ""compare_XX.jpg"" e' uno screenshot affiancato **A | B** preso allo")
        $mdLines.Add("stesso istante relativo nei due file: apri le immagini per la verifica")
        $mdLines.Add("visiva finale, il punteggio qui sotto e' solo un aiuto orientativo.")
        $mdLines.Add("")

        $csvRows = New-Object System.Collections.Generic.List[object]
        $moveLines = New-Object System.Collections.Generic.List[string]
        $moveLines.Add('# Comandi suggeriti per spostare le copie "perdenti" in una cartella di')
        $moveLines.Add('# quarantena, cosi'' puoi controllarle prima di cancellarle davvero.')
        $moveLines.Add('# RIVEDI e DECOMMENTA solo le righe che vuoi eseguire.')
        $moveLines.Add('$Quarantine = ".\scartati"')
        $moveLines.Add('New-Item -ItemType Directory -Force -Path $Quarantine | Out-Null')
        $moveLines.Add('')

        ##---------------------------- LOOP SULLE COPPIE -----------------------

        $pairNum = 0
        $cancelled = $false
        foreach ($key in $commonKeys) {
            $pairNum++

            if ($ShouldCancel -and (& $ShouldCancel)) {
                Log "Annullato dall'utente dopo $($pairNum - 1) di $($commonKeys.Count) coppie."
                $cancelled = $true
                break
            }

            $fA = $filesA[$key]
            $fB = $filesB[$key]
            $pairLabel = "$([IO.Path]::GetFileName($fA)) <-> $([IO.Path]::GetFileName($fB))"
            Report-Progress $pairNum $commonKeys.Count $pairLabel
            Log "[$pairNum/$($commonKeys.Count)] $pairLabel"

            $infoA = Get-ProbeInfo $fA
            $infoB = Get-ProbeInfo $fB

            $wA = $null; $hA = $null; $wB = $null; $hB = $null
            if ($infoA -and $infoA.streams -and $infoA.streams.Count -gt 0) {
                $wA = $infoA.streams[0].width; $hA = $infoA.streams[0].height
            }
            if ($infoB -and $infoB.streams -and $infoB.streams.Count -gt 0) {
                $wB = $infoB.streams[0].width; $hB = $infoB.streams[0].height
            }

            if (-not $wA -or -not $hA -or -not $wB -or -not $hB) {
                Log "  -> Skip: impossibile leggere lo stream video (file non valido/corrotto?)."
                Log ""
                continue
            }

            $codecA = $infoA.streams[0].codec_name; if (-not $codecA) { $codecA = "n/d" }
            $codecB = $infoB.streams[0].codec_name; if (-not $codecB) { $codecB = "n/d" }
            $fpsA = Get-FpsFromRate $infoA.streams[0].r_frame_rate
            $fpsB = Get-FpsFromRate $infoB.streams[0].r_frame_rate

            $durA = ConvertTo-Double $infoA.format.duration
            $durB = ConvertTo-Double $infoB.format.duration
            $sizeA = ConvertTo-Double $infoA.format.size
            $sizeB = ConvertTo-Double $infoB.format.size

            $brA = ConvertTo-Double $infoA.streams[0].bit_rate
            if ($brA -le 0) { $brA = ConvertTo-Double $infoA.format.bit_rate }
            if ($brA -le 0 -and $durA -gt 0) { $brA = $sizeA * 8 / $durA }

            $brB = ConvertTo-Double $infoB.streams[0].bit_rate
            if ($brB -le 0) { $brB = ConvertTo-Double $infoB.format.bit_rate }
            if ($brB -le 0 -and $durB -gt 0) { $brB = $sizeB * 8 / $durB }

            if ($durA -le 0 -or $durB -le 0) {
                Log "  -> Skip: durata non disponibile per uno dei due file."
                Log ""
                continue
            }

            $maxDur = [Math]::Max($durA, $durB)
            $durDiffPct = [Math]::Abs($durA - $durB) / $maxDur * 100
            $durNote = ""
            if ($durDiffPct -gt $DurToleranceParam) {
                $durNote = " (ATTENZIONE: durate diverse, A=$(Format-Time $durA) B=$(Format-Time $durB), potrebbero non essere la stessa edizione)"
            }

            $refDur = [Math]::Min($durA, $durB)

            $safeName = ConvertTo-SafeFileName ([IO.Path]::GetFileNameWithoutExtension($fA))
            $pairDir = Join-Path $OutDir ("{0:D3}_{1}" -f $pairNum, $safeName)
            New-Item -ItemType Directory -Force -Path $pairDir | Out-Null

            $blurSumA = 0.0; $blurSumB = 0.0; $nBlur = 0
            for ($i = 1; $i -le $NumSamples; $i++) {
                $frac = $i / ($NumSamples + 1)
                $ts = $refDur * $frac

                $thumbA = Join-Path $WorkTmp "a_$i.jpg"
                $thumbB = Join-Path $WorkTmp "b_$i.jpg"
                if (Test-Path -LiteralPath $thumbA) { Remove-Item -LiteralPath $thumbA -Force }
                if (Test-Path -LiteralPath $thumbB) { Remove-Item -LiteralPath $thumbB -Force }

                $blurA = Get-SampleFrame -Ts $ts -Video $fA -ThumbPath $thumbA
                $blurB = Get-SampleFrame -Ts $ts -Video $fB -ThumbPath $thumbB

                if ($null -ne $blurA -and $null -ne $blurB) {
                    $blurSumA += $blurA
                    $blurSumB += $blurB
                    $nBlur++
                    $shotName = "compare_{0:D2}_{1}s.jpg" -f $i, (Format-Time $ts).Replace(':', 'm')
                    Merge-SideBySide -ImgA $thumbA -ImgB $thumbB -Out (Join-Path $pairDir $shotName)
                }
            }

            if ($nBlur -eq 0) {
                Log "  -> Skip: impossibile estrarre fotogrammi campione da uno dei due file."
                Log ""
                continue
            }
            $blurAAvg = $blurSumA / $nBlur
            $blurBAvg = $blurSumB / $nBlur

            # --- punteggio orientativo ---
            $mpA = $wA * $hA / 1000000.0
            $mpB = $wB * $hB / 1000000.0
            $bppA = 0.0; if ($fpsA -gt 0 -and $wA -gt 0 -and $hA -gt 0) { $bppA = $brA / ($wA * $hA * $fpsA) }
            $bppB = 0.0; if ($fpsB -gt 0 -and $wB -gt 0 -and $hB -gt 0) { $bppB = $brB / ($wB * $hB * $fpsB) }

            if ($mpA -ge $mpB) { $resRatioA = 1.0 } else { $resRatioA = $mpA / $mpB }
            if ($mpB -ge $mpA) { $resRatioB = 1.0 } else { $resRatioB = $mpB / $mpA }

            $bppRatioA = 0.0; if ($bppA -ge $bppB) { $bppRatioA = 1.0 } elseif ($bppB -gt 0) { $bppRatioA = $bppA / $bppB }
            $bppRatioB = 0.0; if ($bppB -ge $bppA) { $bppRatioB = 1.0 } elseif ($bppA -gt 0) { $bppRatioB = $bppB / $bppA }

            $sharpRatioA = 0.0; if ($blurAAvg -le $blurBAvg) { $sharpRatioA = 1.0 } elseif ($blurAAvg -gt 0) { $sharpRatioA = $blurBAvg / $blurAAvg }
            $sharpRatioB = 0.0; if ($blurBAvg -le $blurAAvg) { $sharpRatioB = 1.0 } elseif ($blurBAvg -gt 0) { $sharpRatioB = $blurAAvg / $blurBAvg }

            $scoreA = $W_RES * $resRatioA + $W_SHARP * $sharpRatioA + $W_BPP * $bppRatioA
            $scoreB = $W_RES * $resRatioB + $W_SHARP * $sharpRatioB + $W_BPP * $bppRatioB

            $maxScore = [Math]::Max($scoreA, $scoreB)
            $gapPct = 0.0
            if ($maxScore -gt 0) { $gapPct = [Math]::Abs($scoreA - $scoreB) / $maxScore * 100 }

            $loserFile = $null
            if ($gapPct -lt 5) {
                $verdict = "Qualita' molto simile: controlla gli screenshot in '$pairDir'"
            } elseif ($scoreA -gt $scoreB) {
                $verdict = "Consigliato: A ($([IO.Path]::GetFileName($fA)))"
                $loserFile = $fB
            } else {
                $verdict = "Consigliato: B ($([IO.Path]::GetFileName($fB)))"
                $loserFile = $fA
            }

            $brAk = [int][Math]::Round($brA / 1000)
            $brBk = [int][Math]::Round($brB / 1000)

            Log "  A: ${wA}x${hA} $codecA $brAk kbps  nitidezza(blur)=$(Fmt $blurAAvg '0.00')  punteggio=$(Fmt $scoreA '0.000')"
            Log "  B: ${wB}x${hB} $codecB $brBk kbps  nitidezza(blur)=$(Fmt $blurBAvg '0.00')  punteggio=$(Fmt $scoreB '0.000')"
            Log "  -> $verdict$durNote"
            Log "  screenshot: $pairDir"
            Log ""

            $mdLines.Add("## $pairLabel")
            $mdLines.Add("")
            $mdLines.Add("| | A | B |")
            $mdLines.Add("|---|---|---|")
            $mdLines.Add("| file | ``$([IO.Path]::GetFileName($fA))`` | ``$([IO.Path]::GetFileName($fB))`` |")
            $mdLines.Add("| risoluzione | ${wA}x${hA} | ${wB}x${hB} |")
            $mdLines.Add("| codec | $codecA | $codecB |")
            $mdLines.Add("| bitrate | $brAk kbps | $brBk kbps |")
            $mdLines.Add("| durata | $(Format-Time $durA) | $(Format-Time $durB) |")
            $mdLines.Add("| dimensione | $(Format-Size $sizeA) | $(Format-Size $sizeB) |")
            $mdLines.Add("| nitidezza (blur, piu' basso = meglio) | $(Fmt $blurAAvg '0.00') | $(Fmt $blurBAvg '0.00') |")
            $mdLines.Add("| punteggio orientativo | $(Fmt $scoreA '0.000') | $(Fmt $scoreB '0.000') |")
            $mdLines.Add("")
            $mdLines.Add("**Verdetto: $verdict**$durNote")
            $mdLines.Add("")
            $mdLines.Add("Screenshot di confronto (A a sinistra, B a destra): ``$pairDir``")
            $mdLines.Add("")

            $csvRows.Add([PSCustomObject]@{
                coppia         = $pairLabel
                file_A         = $fA
                file_B         = $fB
                risoluzione_A  = "${wA}x${hA}"
                risoluzione_B  = "${wB}x${hB}"
                bitrate_A_kbps = $brAk
                bitrate_B_kbps = $brBk
                codec_A        = $codecA
                codec_B        = $codecB
                nitidezza_A    = Fmt $blurAAvg '0.00'
                nitidezza_B    = Fmt $blurBAvg '0.00'
                punteggio_A    = Fmt $scoreA '0.000'
                punteggio_B    = Fmt $scoreB '0.000'
                consigliato    = $verdict
            })

            if ($loserFile) {
                $moveLines.Add("# $pairLabel -> perdente: $([IO.Path]::GetFileName($loserFile))")
                $escaped = $loserFile -replace "'", "''"
                $moveLines.Add("# Move-Item -LiteralPath '$escaped' -Destination `$Quarantine")
                $moveLines.Add("")
            }
        }

        $mdLines | Set-Content -LiteralPath $ReportMd -Encoding UTF8
        $csvRows | Export-Csv -LiteralPath $ReportCsv -NoTypeInformation -Encoding UTF8
        $moveLines | Set-Content -LiteralPath $MoveScript -Encoding UTF8

        Report-Progress $commonKeys.Count $commonKeys.Count "completato"
        Log "Fatto. Report in: $ReportMd (e $ReportCsv)"
        Log "Comandi di spostamento suggeriti (commentati, da rivedere): $MoveScript"

        return [PSCustomObject]@{
            PairsFound      = $commonKeys.Count
            PairsProcessed  = $pairNum - $(if ($cancelled) { 1 } else { 0 })
            Cancelled       = $cancelled
            ReportMd        = $ReportMd
            ReportCsv       = $ReportCsv
            MoveScript      = $MoveScript
            OutDir          = $OutDir
        }
    }
    finally {
        Remove-Item -Recurse -Force -LiteralPath $WorkTmp -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Invoke-VideoQualityComparison

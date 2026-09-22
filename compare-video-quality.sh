#!/bin/bash
#
# compare-video-quality.sh
#
# Confronta la qualita' dei video con lo stesso nome (o release diverse
# dello stesso titolo) presenti in due directory diverse, comprese le
# sottocartelle (es. stesso film/episodio scaricato in momenti differenti,
# magari con tag di release diversi) e aiuta a decidere quale copia tenere.
#
# La ricerca dei file e' RICORSIVA in entrambe le cartelle, e l'abbinamento
# avviene sul nome normalizzato (minuscolo, senza tag tecnici comuni come
# risoluzione/source/codec/audio/lingua/release group): "Il Film (2020).mkv"
# e "Il.Film.2020.1080p.BluRay.x264-GROUP.mp4" vengono riconosciuti come lo
# stesso video. E' un confronto volutamente prudente (solo match esatto dopo
# la normalizzazione, niente somiglianza approssimata) per ridurre il rischio
# di abbinare per errore due video diversi.
#
# Per ogni coppia di file corrispondenti:
#  - legge risoluzione, bitrate e codec con ffprobe
#  - estrae N fotogrammi campione (agli stessi istanti relativi) e ne
#    misura la nitidezza reale con il filtro ffmpeg "blurdetect"
#  - genera screenshot affiancati A/B per il confronto visivo
#  - calcola un punteggio orientativo e propone quale file tenere
#
# La decisione finale resta dell'utente: lo script NON cancella e NON
# sposta nulla, produce solo un report (report.md, report.csv) e uno
# script di supporto (move-losers.sh) con i comandi "mv" GIA' COMMENTATI,
# da rivedere ed eseguire manualmente.
#
# Uso:
#   ./compare-video-quality.sh <dir_A> <dir_B> [output_dir] [num_campioni]
#
# Esempio:
#   ./compare-video-quality.sh ~/Download/serie_v1 ~/Download/serie_v2
#   ./compare-video-quality.sh ~/A ~/B ./report 7
#
# Dipendenze: ffmpeg, ffprobe, jq, awk
#   Debian/Ubuntu: sudo apt install ffmpeg jq

set -uo pipefail

##---------------------------- CONFIG -------------------------------------
DIR_A="${1:-}"
DIR_B="${2:-}"
OUT_DIR="${3:-./video-quality-report}"
NUM_SAMPLES="${4:-5}"        # punti di campionamento (screenshot + nitidezza)

SHOT_W=480                    # dimensioni tela screenshot di confronto
SHOT_H=270
DUR_TOLERANCE_PCT=5           # oltre questa differenza % di durata, viene segnalato

# Pesi del punteggio orientativo (somma = 1): risoluzione, nitidezza, bit/pixel
W_RES=0.35
W_SHARP=0.45
W_BPP=0.20
##-------------------------- END CONFIG ------------------------------------

usage() {
	cat <<EOF
-------------- Confronto qualita' video tra due cartelle -----------------
Uso: $0 <dir_A> <dir_B> [output_dir] [num_campioni]

  dir_A, dir_B    cartelle da confrontare (stessi nomi file = stesso video)
  output_dir      dove salvare report e screenshot (default: ./video-quality-report)
  num_campioni    quanti punti nel video campionare (default: 5)

Dipendenze: ffmpeg, ffprobe, jq, awk
----------------------------------------------------------------------------
EOF
}

if [ -z "$DIR_A" ] || [ -z "$DIR_B" ]; then
	usage
	exit 1
fi
if [ ! -d "$DIR_A" ]; then echo "Errore: '$DIR_A' non e' una directory."; exit 1; fi
if [ ! -d "$DIR_B" ]; then echo "Errore: '$DIR_B' non e' una directory."; exit 1; fi
if [ "$(cd "$DIR_A" && pwd)" = "$(cd "$DIR_B" && pwd)" ]; then
	echo "Errore: dir_A e dir_B sono la stessa cartella."; exit 1
fi

for bin in ffmpeg ffprobe jq awk; do
	command -v "$bin" >/dev/null 2>&1 || { echo "Errore: '$bin' non trovato. Installa le dipendenze (vedi -h)."; exit 1; }
done

mkdir -p "$OUT_DIR" || { echo "Errore: impossibile creare '$OUT_DIR'"; exit 1; }
WORKTMP="$(mktemp -d)"
trap 'rm -rf "$WORKTMP"' EXIT

REPORT_MD="$OUT_DIR/report.md"
REPORT_CSV="$OUT_DIR/report.csv"
MOVE_SCRIPT="$OUT_DIR/move-losers.sh"

# font per le etichette A/B sugli screenshot (best-effort, opzionale)
LABEL_FONT=""
for f in \
	/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf \
	/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf \
	/System/Library/Fonts/Helvetica.ttc \
	/Library/Fonts/Arial.ttf; do
	[ -f "$f" ] && LABEL_FONT="$f" && break
done

##--------------------------- FUNZIONI --------------------------------------

# stampa un valore ffprobe (stream video) o vuoto
probe_json() {
	ffprobe -v error -select_streams v:0 \
		-show_entries stream=width,height,codec_name,bit_rate,r_frame_rate \
		-show_entries format=duration,size,bit_rate \
		-of json -- "$1" 2>/dev/null
}

# converte "25/1" -> 25.0 ; "0/0" o vuoto -> 25 (fallback prudente)
fps_from_rate() {
	awk -F'/' -v r="$1" 'BEGIN{
		split(r,a,"/");
		if (a[2]+0>0) printf "%.6f", a[1]/a[2]; else print "25"
	}'
}

# valuta un'espressione numerica con awk (evita dipendenza da bc)
calc() { awk "BEGIN{ printf \"%.6f\", ($1) }"; }

# valuta una condizione booleana con awk, restituisce "1" o "0" (mai "1.000000")
cond() { awk "BEGIN{ print (($1) ? 1 : 0) }"; }

# normalizza un nome file (senza estensione) per riconoscere release diverse
# dello stesso video: minuscolo, separatori uniformati, tag tecnici comuni
# (risoluzione/source/codec/audio/lingua/release group) rimossi.
# es: "Il.Film.2020.1080p.BluRay.x264-GROUP" e "Il Film (2020)" -> "il film 2020"
normalize_name() {
	local s year
	# preserva un eventuale anno (19xx/20xx) anche se e' tra parentesi/graffe,
	# cosi' "Titolo [2019]" e "Titolo 2019" restano riconosciuti come uguali
	year="$(printf '%s' "$1" | grep -Eo '(19[0-9]{2}|20[0-9]{2})' | head -1)"
	s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
	s="$(printf '%s' "$s" | sed -E 's/[._]+/ /g')"
	s="$(printf '%s' "$s" | sed -E 's/\[[^]]*\]//g; s/\{[^}]*\}//g')"
	s="$(printf '%s' "$s" | sed -E '
		s/\b(2160p|1080p|720p|480p|360p|4k|uhd|hdr|hd|sd)\b//g;
		s/\b(bluray|blu-ray|bdrip|brrip|bdremux|remux|web-?dl|webrip|hdtv|dvdrip|dvdscr|dvd|dsnp|amzn|nf|hmax|atvp)\b//g;
		s/\b(x264|x265|h264|h265|hevc|avc|xvid|divx|10bit|8bit)\b//g;
		s/\b(aac|ac3|dts|dd5 1|dd\+|eac3|flac|mp3|5 1|7 1|2 0)\b//g;
		s/\b(ita|eng|engita|itaeng|multi|sub|subs|subbed|dual|dl)\b//g;
		s/\b(repack|proper|extended|uncut|remastered|complete|internal|limited)\b//g
	')"
	s="$(printf '%s' "$s" | sed -E 's/-[a-z0-9]+$//')"
	s="$(printf '%s' "$s" | sed -E "s/['\"(),!:;]//g")"
	if [ -n "$year" ] && [[ "$s" != *"$year"* ]]; then
		s="$s $year"
	fi
	s="$(printf '%s' "$s" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
	printf '%s' "$s"
}

# secondi -> mm:ss
fmt_time() { awk -v s="$1" 'BEGIN{ printf "%02d:%02d", int(s/60), int(s)%60 }'; }

# bytes -> "X.XX GB/MB"
fmt_size() {
	awk -v b="$1" 'BEGIN{
		if (b<=0){print "n/d"; exit}
		g=b/1073741824; m=b/1048576
		if (g>=1) printf "%.2f GB", g; else printf "%.1f MB", m
	}'
}

# estrae in un'unica passata ffmpeg: nitidezza (blurdetect, risoluzione nativa)
# + miniatura in tela fissa SHOT_W x SHOT_H (per il confronto affiancato)
# ts=$1 video=$2 out_thumb=$3 -> stampa il valore di blur su stdout (o niente se fallisce)
sample_frame() {
	local ts="$1" video="$2" thumb="$3" log
	log="$WORKTMP/blur.log"
	ffmpeg -y -ss "$ts" -i "$video" -hide_banner -loglevel info \
		-filter_complex "[0:v]split=2[v1][v2];[v1]blurdetect=block_width=32:block_height=32[vb];[v2]scale=${SHOT_W}:${SHOT_H}:force_original_aspect_ratio=decrease,pad=${SHOT_W}:${SHOT_H}:(ow-iw)/2:(oh-ih)/2[vt]" \
		-map "[vb]" -frames:v 1 -f null - \
		-map "[vt]" -frames:v 1 -q:v 3 "$thumb" >/dev/null 2>"$log"
	if [ -s "$thumb" ]; then
		grep -o "blur mean: [0-9.]*" "$log" | awk '{print $3}'
	fi
}

# combina due miniature gia' pronte in un unico jpg affiancato con etichette A/B
combine_side_by_side() {
	local imgA="$1" imgB="$2" out="$3"
	local vfA vfB
	if [ -n "$LABEL_FONT" ]; then
		vfA="drawtext=fontfile='${LABEL_FONT}':text='A':fontcolor=yellow:fontsize=20:x=8:y=8:box=1:boxcolor=black@0.5"
		vfB="drawtext=fontfile='${LABEL_FONT}':text='B':fontcolor=yellow:fontsize=20:x=8:y=8:box=1:boxcolor=black@0.5"
		ffmpeg -y -hide_banner -loglevel error -i "$imgA" -i "$imgB" \
			-filter_complex "[0:v]${vfA}[a];[1:v]${vfB}[b];[a][b]hstack=inputs=2[out]" \
			-map "[out]" -frames:v 1 "$out" 2>/dev/null && return 0
	fi
	# fallback senza etichette (nessun font disponibile o drawtext fallito)
	ffmpeg -y -hide_banner -loglevel error -i "$imgA" -i "$imgB" \
		-filter_complex "hstack=inputs=2" -frames:v 1 "$out" 2>/dev/null
}

##---------------------------- INTESTAZIONI REPORT ---------------------------

cat > "$REPORT_MD" <<EOF
# Report confronto qualita' video

- Cartella A: \`$DIR_A\`
- Cartella B: \`$DIR_B\`
- Generato il: $(date '+%Y-%m-%d %H:%M:%S')
- Campioni per video: $NUM_SAMPLES

Ogni riga "compare_XX.jpg" e' uno screenshot affiancato **A | B** preso allo
stesso istante relativo nei due file: apri le immagini per la verifica
visiva finale, il punteggio qui sotto e' solo un aiuto orientativo.

EOF

echo "coppia,file_A,file_B,risoluzione_A,risoluzione_B,bitrate_A_kbps,bitrate_B_kbps,codec_A,codec_B,nitidezza_A,nitidezza_B,punteggio_A,punteggio_B,consigliato" > "$REPORT_CSV"

cat > "$MOVE_SCRIPT" <<'EOF'
#!/bin/bash
# Comandi suggeriti per spostare le copie "perdenti" in una cartella di
# quarantena, cosi' puoi controllarle prima di cancellarle davvero.
# RIVEDI e DECOMMENTA solo le righe che vuoi eseguire.
set -euo pipefail
QUARANTINE="./scartati"
mkdir -p "$QUARANTINE"

EOF
chmod +x "$MOVE_SCRIPT"

##---------------------------- MATCHING FILE ---------------------------------

declare -A PATH_A PATH_B
while IFS= read -r -d '' f; do
	bn="$(basename "$f")"; name="${bn%.*}"
	key="$(normalize_name "$name")"
	[ -z "$key" ] && continue
	if [ -n "${PATH_A[$key]+x}" ] && [ "${PATH_A[$key]}" != "$f" ]; then
		echo "Attenzione: in '$DIR_A' '$f' si normalizza come '${PATH_A[$key]}' (stesso nome dopo la pulizia dei tag). Tengo solo il secondo trovato."
	fi
	PATH_A["$key"]="$f"
done < <(find "$DIR_A" -type f -print0)

while IFS= read -r -d '' f; do
	bn="$(basename "$f")"; name="${bn%.*}"
	key="$(normalize_name "$name")"
	[ -z "$key" ] && continue
	if [ -n "${PATH_B[$key]+x}" ] && [ "${PATH_B[$key]}" != "$f" ]; then
		echo "Attenzione: in '$DIR_B' '$f' si normalizza come '${PATH_B[$key]}' (stesso nome dopo la pulizia dei tag). Tengo solo il secondo trovato."
	fi
	PATH_B["$key"]="$f"
done < <(find "$DIR_B" -type f -print0)

mapfile -t COMMON_KEYS < <(for k in "${!PATH_A[@]}"; do [ -n "${PATH_B[$k]+x}" ] && echo "$k"; done | sort)

if [ "${#COMMON_KEYS[@]}" -eq 0 ]; then
	echo "Nessun file con lo stesso nome trovato tra le due cartelle."
	exit 0
fi

echo "Trovate ${#COMMON_KEYS[@]} coppie di file con lo stesso nome. Avvio analisi..."
echo

##---------------------------- LOOP SULLE COPPIE ------------------------------

pair_num=0
for key in "${COMMON_KEYS[@]}"; do
	pair_num=$((pair_num + 1))
	fA="${PATH_A[$key]}"; fB="${PATH_B[$key]}"
	pair_label="$(basename "$fA") <-> $(basename "$fB")"
	echo "[$pair_num/${#COMMON_KEYS[@]}] $pair_label"

	jsonA="$(probe_json "$fA")"; jsonB="$(probe_json "$fB")"

	wA=$(jq -r '.streams[0].width // empty' <<<"$jsonA")
	hA=$(jq -r '.streams[0].height // empty' <<<"$jsonA")
	wB=$(jq -r '.streams[0].width // empty' <<<"$jsonB")
	hB=$(jq -r '.streams[0].height // empty' <<<"$jsonB")

	if [ -z "$wA" ] || [ -z "$hA" ] || [ -z "$wB" ] || [ -z "$hB" ]; then
		echo "  -> Skip: impossibile leggere lo stream video (file non valido/corrotto?)."
		echo
		continue
	fi

	codecA=$(jq -r '.streams[0].codec_name // "n/d"' <<<"$jsonA")
	codecB=$(jq -r '.streams[0].codec_name // "n/d"' <<<"$jsonB")
	rateA=$(jq -r '.streams[0].r_frame_rate // "25/1"' <<<"$jsonA")
	rateB=$(jq -r '.streams[0].r_frame_rate // "25/1"' <<<"$jsonB")
	fpsA=$(fps_from_rate "$rateA"); fpsB=$(fps_from_rate "$rateB")

	durA=$(jq -r '.format.duration // .streams[0].duration // 0' <<<"$jsonA")
	durB=$(jq -r '.format.duration // .streams[0].duration // 0' <<<"$jsonB")
	sizeA=$(jq -r '.format.size // 0' <<<"$jsonA")
	sizeB=$(jq -r '.format.size // 0' <<<"$jsonB")

	brA=$(jq -r '.streams[0].bit_rate // .format.bit_rate // 0' <<<"$jsonA")
	brB=$(jq -r '.streams[0].bit_rate // .format.bit_rate // 0' <<<"$jsonB")
	[ "$brA" = "0" ] && [ "$(cond "$durA>0")" = "1" ] && brA=$(calc "$sizeA*8/$durA")
	[ "$brB" = "0" ] && [ "$(cond "$durB>0")" = "1" ] && brB=$(calc "$sizeB*8/$durB")

	if [ "$(cond "$durA<=0 || $durB<=0")" = "1" ]; then
		echo "  -> Skip: durata non disponibile per uno dei due file."
		echo
		continue
	fi

	dur_diff_pct=$(calc "( ($durA>$durB)?($durA-$durB):($durB-$durA) ) / (($durA>$durB)?$durA:$durB) * 100")
	dur_note=""
	if [ "$(cond "$dur_diff_pct > $DUR_TOLERANCE_PCT")" = "1" ]; then
		dur_note=" (ATTENZIONE: durate diverse, A=$(fmt_time "$durA") B=$(fmt_time "$durB"), potrebbero non essere la stessa edizione)"
	fi

	ref_dur=$(calc "($durA<$durB)?$durA:$durB")

	pair_dir="$OUT_DIR/$(printf '%03d' "$pair_num")_$(basename "${fA%.*}" | tr ' /' '__')"
	mkdir -p "$pair_dir"

	blur_sum_A=0; blur_sum_B=0; n_blur=0
	shot_num=0
	for i in $(seq 1 "$NUM_SAMPLES"); do
		frac=$(calc "$i/($NUM_SAMPLES+1)")
		ts=$(calc "$ref_dur*$frac")
		shot_num=$((shot_num + 1))

		thumbA="$WORKTMP/a_$shot_num.jpg"
		thumbB="$WORKTMP/b_$shot_num.jpg"
		blurA=$(sample_frame "$ts" "$fA" "$thumbA")
		blurB=$(sample_frame "$ts" "$fB" "$thumbB")

		if [ -n "$blurA" ] && [ -n "$blurB" ]; then
			blur_sum_A=$(calc "$blur_sum_A+$blurA")
			blur_sum_B=$(calc "$blur_sum_B+$blurB")
			n_blur=$((n_blur + 1))
			combine_side_by_side "$thumbA" "$thumbB" "$pair_dir/compare_$(printf '%02d' "$shot_num")_$(fmt_time "$ts" | tr ':' 'm')s.jpg"
		fi
	done

	if [ "$n_blur" -eq 0 ]; then
		echo "  -> Skip: impossibile estrarre fotogrammi campione da uno dei due file."
		echo
		continue
	fi
	blurA_avg=$(calc "$blur_sum_A/$n_blur")
	blurB_avg=$(calc "$blur_sum_B/$n_blur")

	# --- punteggio orientativo ---
	mpA=$(calc "$wA*$hA/1000000"); mpB=$(calc "$wB*$hB/1000000")
	bppA=$(calc "($fpsA>0 && $wA>0 && $hA>0)?$brA/($wA*$hA*$fpsA):0")
	bppB=$(calc "($fpsB>0 && $wB>0 && $hB>0)?$brB/($wB*$hB*$fpsB):0")

	res_ratio_A=$(calc "($mpA>=$mpB)?1:$mpA/$mpB"); res_ratio_B=$(calc "($mpB>=$mpA)?1:$mpB/$mpA")
	bpp_ratio_A=$(calc "($bppA>=$bppB)?1:(($bppB>0)?$bppA/$bppB:0)"); bpp_ratio_B=$(calc "($bppB>=$bppA)?1:(($bppA>0)?$bppB/$bppA:0)")
	# nitidezza: valore di blur PIU' BASSO = PIU' nitido -> vince chi ha blur minore
	sharp_ratio_A=$(calc "($blurA_avg<=$blurB_avg)?1:(($blurA_avg>0)?$blurB_avg/$blurA_avg:0)")
	sharp_ratio_B=$(calc "($blurB_avg<=$blurA_avg)?1:(($blurB_avg>0)?$blurA_avg/$blurB_avg:0)")

	scoreA=$(calc "$W_RES*$res_ratio_A + $W_SHARP*$sharp_ratio_A + $W_BPP*$bpp_ratio_A")
	scoreB=$(calc "$W_RES*$res_ratio_B + $W_SHARP*$sharp_ratio_B + $W_BPP*$bpp_ratio_B")

	gap_pct=$(calc "(($scoreA>$scoreB)?($scoreA-$scoreB):($scoreB-$scoreA)) / (($scoreA>$scoreB)?$scoreA:$scoreB) * 100")
	if [ "$(cond "$gap_pct < 5")" = "1" ]; then
		verdict="Qualita' molto simile: controlla gli screenshot in '$pair_dir'"
		loser_file=""
	elif [ "$(cond "$scoreA>$scoreB")" = "1" ]; then
		verdict="Consigliato: A ($(basename "$fA"))"
		loser_file="$fB"
	else
		verdict="Consigliato: B ($(basename "$fB"))"
		loser_file="$fA"
	fi

	echo "  A: ${wA}x${hA} ${codecA} $(printf '%.0f' "$(calc "$brA/1000")") kbps  nitidezza(blur)=$(printf '%.2f' "$blurA_avg")  punteggio=$(printf '%.3f' "$scoreA")"
	echo "  B: ${wB}x${hB} ${codecB} $(printf '%.0f' "$(calc "$brB/1000")") kbps  nitidezza(blur)=$(printf '%.2f' "$blurB_avg")  punteggio=$(printf '%.3f' "$scoreB")"
	echo "  -> $verdict$dur_note"
	echo "  screenshot: $pair_dir"
	echo

	{
		echo "## $pair_label"
		echo
		echo "| | A | B |"
		echo "|---|---|---|"
		echo "| file | \`$(basename "$fA")\` | \`$(basename "$fB")\` |"
		echo "| risoluzione | ${wA}x${hA} | ${wB}x${hB} |"
		echo "| codec | $codecA | $codecB |"
		echo "| bitrate | $(printf '%.0f' "$(calc "$brA/1000")") kbps | $(printf '%.0f' "$(calc "$brB/1000")") kbps |"
		echo "| durata | $(fmt_time "$durA") | $(fmt_time "$durB") |"
		echo "| dimensione | $(fmt_size "$sizeA") | $(fmt_size "$sizeB") |"
		echo "| nitidezza (blur, piu' basso = meglio) | $(printf '%.2f' "$blurA_avg") | $(printf '%.2f' "$blurB_avg") |"
		echo "| punteggio orientativo | $(printf '%.3f' "$scoreA") | $(printf '%.3f' "$scoreB") |"
		echo
		echo "**Verdetto: $verdict**$dur_note"
		echo
		echo "Screenshot di confronto (A a sinistra, B a destra): \`$pair_dir\`"
		echo
	} >> "$REPORT_MD"

	echo "\"$pair_label\",\"$fA\",\"$fB\",${wA}x${hA},${wB}x${hB},$(printf '%.0f' "$(calc "$brA/1000")"),$(printf '%.0f' "$(calc "$brB/1000")"),$codecA,$codecB,$(printf '%.2f' "$blurA_avg"),$(printf '%.2f' "$blurB_avg"),$(printf '%.3f' "$scoreA"),$(printf '%.3f' "$scoreB"),\"$verdict\"" >> "$REPORT_CSV"

	if [ -n "$loser_file" ]; then
		printf '# %s -> perdente: %s\n# mv %q "$QUARANTINE/"\n\n' "$pair_label" "$(basename "$loser_file")" "$loser_file" >> "$MOVE_SCRIPT"
	fi
done

echo "Fatto. Report in: $REPORT_MD (e $REPORT_CSV)"
echo "Comandi di spostamento suggeriti (commentati, da rivedere): $MOVE_SCRIPT"

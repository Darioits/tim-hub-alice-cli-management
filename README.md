# UPDATE 22/09/2026: aggiunta versione Windows (compare-video-quality.ps1) dello script di confronto qualita' video
# UPDATE 22/09/2026: aggiunto script compare-video-quality.sh (confronto qualita' video tra due cartelle)
# UPDATE 16/11/2021: aggiunto script modem poste italiane (H2640 PMZHP_1.0.1_001)
# UPDATE 06/10/2021: aggiunto script tim hub+ (H388X AGZHP_1.2.0)

# tim-hub-alice-cli-management
Script per la gestione da command line linux del modem alice di telecom italia.
Per ora sono implementate le funzioni di base "wifilist", "reboot", "info" e "stats" ma è semplice aggiungerne altre con la struttura di login al modem funzionante.

Non so come si comporta con modem senza password impostata, fate sapere :)

# info
* Editare i parametri di configurazione in testa allo script
* Software necessari: md5sum, php (modem alice) - jq, sha256sum (modem timhub / modem poste italiane)
* Testato su: AGVTF_5.3.3 - modem alice adsl/vdsl (modemalice.sh)
* Testato su: TIM HUB+ - H388X AGZHP_1.2.0 - modem tim hub+ fibra/vdsl2 (modemtimhub.sh)
* Testato su: H2640 PMZHP_1.0.1_001 - modem poste italiane adsl/vdsl (h2640.sh)

# compare-video-quality.sh

Confronta la qualita' dei video con lo stesso nome presenti in due cartelle diverse
(es. stesso film/episodio scaricato in momenti differenti) e aiuta a decidere quale
copia tenere, indipendentemente dalla dimensione del file.

Per ogni coppia analizza risoluzione, bitrate e codec (ffprobe), misura la nitidezza
reale su alcuni fotogrammi campione con il filtro ffmpeg `blurdetect` e genera
screenshot affiancati A/B per la verifica visiva. Produce un report (report.md,
report.csv) con un punteggio orientativo, e uno script `move-losers.sh` con comandi
`mv` gia' commentati per mettere in quarantena le copie perdenti (nulla viene
cancellato o spostato automaticamente, decidi tu dopo aver controllato gli screenshot).

Disponibile in due versioni equivalenti, stesso comportamento e stesso formato di report:

**Linux/macOS - `compare-video-quality.sh`**
* Software necessari: ffmpeg, ffprobe, jq
* Uso: `./compare-video-quality.sh <dir_A> <dir_B> [output_dir] [num_campioni]`
* Esempio: `./compare-video-quality.sh ~/Download/serie_v1 ~/Download/serie_v2 ./report 7`

**Windows - `compare-video-quality.ps1`**
* Software necessari: ffmpeg e ffprobe nel PATH di Windows (build "essentials" da https://www.gyan.dev/ffmpeg/builds/, poi aggiungi la cartella `bin` al PATH)
* Uso: `.\compare-video-quality.ps1 <dir_A> <dir_B> [output_dir] [num_campioni]`
* Esempio: `.\compare-video-quality.ps1 "D:\Download\serie_v1" "D:\Download\serie_v2" .\report 7`
* Se Windows blocca l'esecuzione dello script (execution policy), avvialo con:
  `powershell -ExecutionPolicy Bypass -File .\compare-video-quality.ps1 <dir_A> <dir_B>`
* Genera `move-losers.ps1` (equivalente Windows di `move-losers.sh`, con comandi `Move-Item` commentati)

#esempi

Uso: ./modemalice.sh {wifilist|reboot|info|stats}

Uso: ./h2640.sh {wlandhcp|wlanstatus|dnshostnames|dslstatus|wanstatus|ddnsstatus|reboot}

Client connessi: **./modemalice.sh wifilist|grep "Nessun"|wc -l**

Se il risultato è 2 nessun host è connesso, se è 1 o 0 ci sono client

Riavvio modem: **./modemalice.sh reboot**

#crontab
**59      4       3       *       *       /usr/bin/me/alice_fibra/modemalice.sh reboot**

riavvio mensile alle 4 e 59, ogni giorno 3 del mese


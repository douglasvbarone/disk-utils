#!/usr/bin/env bash
#
# verificar-hd.sh — verificação de HD usado antes de colocá-lo em serviço
#
# Etapas:
#   1. Identificação, checagens de segurança e leitura inicial do SMART
#   2. Autoteste SMART curto (alguns minutos)
#   3. Opcional e DESTRUTIVO: grava e relê o disco inteiro com badblocks
#   4. Autoteste SMART longo (o próprio disco lê toda a superfície)
#   5. Nova leitura do SMART, comparação antes/depois e veredito
#
# A única pergunta (s/N, padrão Não) é feita logo no início; depois disso o
# script roda sozinho. Os testes levam horas: rode dentro de tmux ou screen.
#
# O script se recusa a trabalhar com discos em uso: montados, swap, LVM/RAID
# ou membros de um pool ZFS importado. Relatórios ficam em /root/verificacao-hd/.
#
# Códigos de saída: 0 aprovado, 2 aprovado com ressalvas, 3 reprovado, 1 erro.
# Requisitos: smartmontools e e2fsprogs (no Proxmox, ambos já vêm instalados).

set -u

DIR_LOG=/root/verificacao-hd
LIMITE_HORAS=40000   # a partir daqui, alerta de uso intenso
# Lista parcial de modelos de 2,5" sabidamente SMR
MODELOS_SMR='ST1000LM048|ST2000LM015|WD10SPZX|WD20SPZX|MQ04ABF100'

uso() {
  cat <<'EOF'
Uso: verificar-hd.sh [-d tipo] [-r disco_referência] [-c] <disco>

  -d tipo   tipo de dispositivo para o smartctl (ex.: sat, comum em docks USB)
  -r disco  confere se o disco tem pelo menos o tamanho do disco de referência
            (ex.: um membro do pool que ele vai substituir)
  -c        teste destrutivo completo, com 4 padrões em vez de 1
            (cerca de 4x mais demorado)

Exemplo:
  verificar-hd.sh -r /dev/disk/by-id/ata-ST1000LM049-2GH172_WGS1TW16 \
                  /dev/disk/by-id/ata-ST1000LM049-2GH172_XXXXXXXX
EOF
}

# ------------------------------------------------------------------- funções

morrer()   { printf 'ERRO: %b\n' "$*" >&2; exit 1; }
log()      { printf '%s\n' "$*"; if [[ -n ${LOG:-} ]]; then printf '%s\n' "$*" >>"$LOG"; fi; }
titulo()   { log ""; log "=== $* ==="; }
reprovar() { REPROVACOES+=("$1"); }
alertar()  { ALERTAS+=("$1"); }

# smartctl no disco-alvo, sempre pelo caminho by-id (que acompanha o serial)
sc() { smartctl ${SC_OPTS[@]+"${SC_OPTS[@]}"} "$@" "$ALVO"; }

# Parte numérica inicial do valor bruto de um atributo SMART
atributo() {  # atributo <saída de smartctl -A> <id>
  awk -v id="$2" '$1 == id { print $10; exit }' <<<"$1" | grep -oE '^[0-9]+'
}

# Guarda os atributos de interesse num array associativo
# shellcheck disable=SC2004,SC2034  # nameref para array associativo
coletar() {  # coletar <nome do array>
  local -n destino=$1
  local saida erros id
  saida=$(sc -A 2>/dev/null)
  for id in 5 9 10 187 197 198 199; do
    destino[$id]=$(atributo "$saida" "$id")
  done
  erros=$(sc -l error 2>/dev/null)
  if grep -q 'No Errors Logged' <<<"$erros"; then
    destino[erros]=0
  else
    destino[erros]=$(awk '/ATA Error Count:/ { print $4; exit }' <<<"$erros")
  fi
}

# Imprime os motivos pelos quais o disco está em uso; retorna 0 se estiver
em_uso() {
  local motivos=() p real pai h
  while read -r p; do
    [[ -n $p ]] && motivos+=("montado em $p")
  done < <(lsblk -nro MOUNTPOINT "$DEV" 2>/dev/null)
  for h in /sys/block/"$NAME"/holders/* /sys/block/"$NAME"/"$NAME"*/holders/*; do
    [[ -e $h ]] && motivos+=("usado por ${h##*/} (LVM, RAID ou device-mapper; desative antes, ex.: vgchange -an)")
  done
  if command -v zpool >/dev/null; then
    while read -r p; do
      [[ $p == /dev/* ]] || continue
      real=$(readlink -f "$p") || continue
      [[ -b $real ]] || continue
      pai=$(lsblk -dno PKNAME "$real" 2>/dev/null)
      [[ ${pai:-${real##*/}} == "$NAME" ]] && motivos+=("membro de um pool ZFS importado ($p)")
    done < <(zpool status -P 2>/dev/null | awk '{ print $1 }')
  fi
  (( ${#motivos[@]} )) || return 1
  printf '  - %s\n' "${motivos[@]}"
}

estado_autoteste() { sc -c 2>/dev/null | grep -A1 'Self-test execution status'; }

# autoteste short|long → 0 passou, 1 falhou, 2 não concluído
autoteste() {
  local tipo=$1 esperado saida estado pct linha
  if [[ $tipo == short ]]; then esperado='Short offline'; else esperado='Extended offline'; fi
  while estado=$(estado_autoteste); [[ $estado == *'in progress'* ]]; do
    printf '\r  Aguardando um autoteste que já estava em andamento...'
    sleep 30
  done
  saida=$(sc -t "$tipo" 2>&1)
  if ! grep -q 'Testing has begun' <<<"$saida"; then
    log "  Não foi possível iniciar o autoteste:"
    log "$saida"
    return 2
  fi
  AUTOTESTE_RODANDO=1
  sleep 20
  while estado=$(estado_autoteste); [[ $estado == *'in progress'* ]]; do
    pct=$(grep -oE '[0-9]+%' <<<"$estado" | head -n1)
    printf '\r  Em andamento: %s restante (%s)   ' "${pct:-?}" "$(date +%H:%M)"
    sleep 60
  done
  AUTOTESTE_RODANDO=0
  printf '\r%70s\r' ''
  linha=$(sc -l selftest 2>/dev/null | grep -m1 -E '^# *1 ')
  log "  Resultado: ${linha:-não encontrado no log do disco}"
  [[ $linha == *"$esperado"* ]] || return 2
  case $linha in
    *'Completed without error'*) return 0 ;;
    *Aborted*|*Interrupted*)     return 2 ;;
    *)                           return 1 ;;
  esac
}

# Remove tabela de partições e assinaturas (inclusive rótulos de pools ZFS antigos)
limpar_assinaturas() {
  local p tipo fs
  log "Removendo partições e assinaturas antigas..."
  while read -r p tipo fs; do
    if [[ ${fs:-} == zfs_member ]] && command -v zpool >/dev/null; then
      zpool labelclear -f "$p" >/dev/null 2>&1 && log "  rótulo ZFS removido de $p"
    fi
    [[ $tipo == part ]] && wipefs -a "$p" >/dev/null 2>&1
  done < <(lsblk -lnpo NAME,TYPE,FSTYPE "$DEV")
  wipefs -a "$DEV" >/dev/null 2>&1
  blockdev --rereadpt "$DEV" >/dev/null 2>&1
  LIMPO=1
}

txt_resultado() {
  case ${1:-} in
    0) echo "ok" ;;
    1) echo "FALHOU" ;;
    2) echo "não concluído" ;;
    *) echo "não executado" ;;
  esac
}

# shellcheck disable=SC2329  # chamada pelo trap
interromper() {
  trap - INT TERM
  echo
  if (( AUTOTESTE_RODANDO )); then
    sc -X >/dev/null 2>&1
    log "Autoteste SMART abortado."
  fi
  (( BADBLOCKS_RODANDO )) && log "O teste destrutivo foi interrompido: o disco já foi parcialmente sobrescrito."
  log "Verificação interrompida pelo usuário."
  exit 1
}

finalizar() {
  local id m veredito codigo cresceu5=0
  coletar FIM
  { echo; echo "===== smartctl -x (fim) ====="; sc -x; } >>"$LOG" 2>&1

  # --- avaliação
  if [[ -n ${INI[9]:-}${INI[5]:-} && -z ${FIM[9]:-}${FIM[5]:-} ]]; then
    reprovar "o SMART não pôde ser lido no final: o disco parou de responder?"
  fi
  for id in 5 197 198; do
    if (( ${FIM[$id]:-0} > ${INI[$id]:-0} )); then
      reprovar "${NOMES[$id]} ($id) aumentaram durante o teste: ${INI[$id]:-0} → ${FIM[$id]:-0}"
      [[ $id == 5 ]] && cresceu5=1
    fi
  done
  if (( ${FIM[197]:-0} > 0 )); then
    m="${FIM[197]} setor(es) pendente(s)"
    (( BB_EXECUTADO )) || m+=" (o teste destrutivo pode esclarecer: pendentes que somem sem virar realocados eram só gravações interrompidas)"
    reprovar "$m"
  fi
  if (( ${INI[197]:-0} > 0 && ${FIM[197]:-0} == 0 && ! cresceu5 )); then
    INFOS+=("os ${INI[197]} setor(es) pendente(s) do início foram regravados sem realocação (gravações interrompidas no passado, não defeito)")
  fi
  (( ${FIM[198]:-0} > 0 )) && reprovar "${FIM[198]} setor(es) incorrigível(is) offline"
  (( ${FIM[5]:-0} > 0 && ! cresceu5 )) && alertar "${FIM[5]} setor(es) realocado(s), estável durante o teste"
  (( ${FIM[187]:-0} > 0 )) && alertar "${FIM[187]} erro(s) incorrigível(is) no histórico do disco (187)"
  (( ${FIM[10]:-0} > 0 )) && alertar "${FIM[10]} tentativa(s) repetida(s) de partida do motor (10): possível problema mecânico ou de alimentação"
  (( ${FIM[199]:-0} > ${INI[199]:-0} )) && alertar "erros de CRC aumentaram durante o teste: confira cabo, porta ou dock (não é necessariamente o disco)"
  if (( ${FIM[erros]:-0} > ${INI[erros]:-0} )); then
    reprovar "o disco registrou novos erros no log ATA durante o teste (${INI[erros]:-0} → ${FIM[erros]:-0})"
  elif (( ${FIM[erros]:-0} > 0 )); then
    alertar "${FIM[erros]} erro(s) antigo(s) no log ATA (podem ser da vida anterior; detalhes no relatório)"
  fi
  (( ${FIM[9]:-0} >= LIMITE_HORAS )) && alertar "uso intenso: ${FIM[9]} horas ligado"
  [[ -n $SMR ]] && alertar "SMR $SMR: não recomendado para ZFS (resilver muito lento, risco de timeouts)"
  (( TEM_ZFS && ! LIMPO )) && alertar "o disco tem rótulos de um pool ZFS antigo: limpe antes de instalar num servidor com ZFS (zpool labelclear -f nas partições + wipefs -a), para não confundir a importação do pool no boot"

  if (( ${#REPROVACOES[@]} )); then veredito="REPROVADO"; codigo=3
  elif (( ${#ALERTAS[@]} )); then veredito="APROVADO COM RESSALVAS"; codigo=2
  else veredito="APROVADO"; codigo=0
  fi

  # --- relatório
  titulo "Comparação"
  log "$(printf '%10s %10s   %s' antes depois atributo)"
  for id in 5 197 198 187 10 199 9; do
    log "$(printf '%10s %10s   %s (%s)' "${INI[$id]:-n/d}" "${FIM[$id]:-n/d}" "${NOMES[$id]}" "$id")"
  done
  log "$(printf '%10s %10s   %s' "${INI[erros]:-n/d}" "${FIM[erros]:-n/d}" 'erros no log ATA')"

  titulo "Resultado: $veredito"
  log "Autoteste curto:  $(txt_resultado "$R_CURTO")"
  if (( BB_EXECUTADO )); then
    log "Teste destrutivo: $BB_RUINS bloco(s) ruim(ns)"
  else
    log "Teste destrutivo: não executado"
  fi
  log "Autoteste longo:  $(txt_resultado "$R_LONGO")"
  log ""
  for m in "${REPROVACOES[@]}"; do log "  [reprovado] $m"; done
  for m in "${ALERTAS[@]}"; do log "  [atenção]   $m"; done
  (( ${#REPROVACOES[@]} + ${#ALERTAS[@]} )) || log "  Nenhum problema encontrado."
  for m in "${INFOS[@]}"; do log "  [info]      $m"; done
  if (( BB_EXECUTADO && codigo != 3 )); then
    log ""
    log "O disco foi todo sobrescrito e está sem partições: pronto para entrar no pool."
  fi
  log ""
  log "Etiqueta: ${SERIAL:-?} | $veredito | $(date +%d/%m/%Y) | ${FIM[9]:-?} h | realocados: ${FIM[5]:-?} | $( (( BB_EXECUTADO )) && echo 'gravação+leitura' || echo 'só leitura')"
  log "Relatório completo: $LOG"
  exit "$codigo"
}

# ---------------------------------------------------------------- argumentos

SC_OPTS=()
REF=""
PADROES=1
while getopts ':d:r:ch' opt; do
  case $opt in
    d) SC_OPTS=(-d "$OPTARG") ;;
    r) REF=$OPTARG ;;
    c) PADROES=4 ;;
    h) uso; exit 0 ;;
    :) echo "A opção -$OPTARG precisa de um valor." >&2; uso; exit 1 ;;
    *) echo "Opção inválida: -$OPTARG" >&2; uso; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -eq 1 ]] || { uso; exit 1; }
ENTRADA=$1

[[ $EUID -eq 0 ]] || morrer "execute como root."
for cmd in smartctl badblocks lsblk blockdev wipefs awk; do
  command -v "$cmd" >/dev/null || morrer "comando necessário não encontrado: $cmd"
done

declare -A INI=() FIM=()
declare -A NOMES=(
  [5]="setores realocados"
  [9]="horas ligado"
  [10]="tentativas repetidas de partida do motor"
  [187]="erros incorrigíveis reportados"
  [197]="setores pendentes"
  [198]="setores incorrigíveis offline"
  [199]="erros de CRC na interface"
)
REPROVACOES=()
ALERTAS=()
INFOS=()
AUTOTESTE_RODANDO=0
BADBLOCKS_RODANDO=0
DESTRUTIVO=0
BB_EXECUTADO=0
BB_RUINS=0
LIMPO=0
LOG=""
R_CURTO=""
R_LONGO=""
trap interromper INT TERM

# ---------------------------------------------- disco e checagens de segurança

DEV=$(readlink -f "$ENTRADA")
[[ -b $DEV ]] || morrer "$ENTRADA não é um dispositivo de bloco."
NAME=${DEV##*/}
[[ $NAME == sd* ]] || morrer "$DEV não parece um HD SATA/SAS (este script trabalha com /dev/sdX)."
[[ -e /sys/block/$NAME ]] || morrer "$ENTRADA é uma partição; informe o disco inteiro."
POR_ID=$(find /dev/disk/by-id/ -lname "*/$NAME" ! -name 'wwn-*' 2>/dev/null | sort | head -n1)
ALVO=${POR_ID:-$DEV}

if MOTIVOS=$(em_uso); then
  morrer "$DEV está em uso:\n$MOTIVOS\nEste script só trabalha com discos livres."
fi

if [[ -n $REF ]]; then
  REF_DEV=$(readlink -f "$REF")
  [[ -b $REF_DEV ]] || morrer "disco de referência inválido: $REF"
  [[ $REF_DEV != "$DEV" ]] || morrer "o disco de referência é o próprio disco a testar."
  REF_BYTES=$(blockdev --getsize64 "$REF_DEV")
fi

INFO=$(sc -i 2>&1)
if ! grep -q 'SMART support is: *Enabled' <<<"$INFO" && grep -q 'SMART support is: *Available' <<<"$INFO"; then
  sc -s on >/dev/null 2>&1
  INFO=$(sc -i 2>&1)
fi
grep -q 'SMART support is: *Enabled' <<<"$INFO" ||
  morrer "não consegui acessar o SMART de $DEV.\nSe o disco estiver num dock USB, tente a opção -d sat.\n\n$INFO"

campo() { awk -F': +' -v k="$1" '$1 == k { sub(/[[:space:]]+$/, "", $2); print $2; exit }' <<<"$INFO"; }
MODELO=$(campo 'Device Model')
[[ -n $MODELO ]] || MODELO=$(lsblk -dno MODEL "$DEV" | sed 's/[[:space:]]*$//')
SERIAL_SMART=$(campo 'Serial Number')
SERIAL=${SERIAL_SMART:-$(lsblk -dno SERIAL "$DEV")}
FIRMWARE=$(campo 'Firmware Version')
ROTACAO=$(campo 'Rotation Rate')
SETORES=$(campo 'Sector Sizes')
[[ -n $SETORES ]] || SETORES=$(campo 'Sector Size')
BYTES=$(blockdev --getsize64 "$DEV")
TAMANHO=$(lsblk -dno SIZE "$DEV" | tr -d ' ')
ROTA=$(lsblk -dno ROTA "$DEV" | tr -d ' ')

mkdir -p "$DIR_LOG" || morrer "não consegui criar $DIR_LOG."
ROTULO=$(printf '%s_%s' "${MODELO:-disco}" "${SERIAL:-sem-serial}" | tr -c 'A-Za-z0-9._-' '_')
INICIO=$(date +%Y%m%d-%H%M)
LOG="$DIR_LOG/${ROTULO}_${INICIO}.log"

titulo "Disco"
log "Dispositivo:  $ALVO"
[[ $ALVO != "$DEV" ]] && log "              ($DEV)"
log "Modelo:       ${MODELO:-?}"
log "Serial:       ${SERIAL:-?}"
log "Firmware:     ${FIRMWARE:-?}"
log "Tamanho:      $TAMANHO ($BYTES bytes)"
log "Rotação:      ${ROTACAO:-?}"
log "Setores:      ${SETORES:-?}"

# SMR: zonas declaradas pelo disco, modelo conhecido ou disco rotacional com TRIM
SMR=""
ZONED=$(cat "/sys/block/$NAME/queue/zoned" 2>/dev/null)
DISC=$(lsblk -dbno DISC-GRAN "$DEV" 2>/dev/null | tr -d ' ')
if [[ $ZONED == host-* ]]; then
  SMR="confirmado ($ZONED)"
elif [[ $MODELO =~ $MODELOS_SMR ]]; then
  SMR="confirmado (modelo SMR conhecido)"
elif [[ $ROTA == 1 && ${DISC:-0} != 0 ]]; then
  SMR="provável (disco rotacional com suporte a TRIM)"
fi
log "SMR:          ${SMR:-não detectado}"

if [[ -n $REF ]]; then
  if (( BYTES >= REF_BYTES )); then
    log "Referência:   $REF_BYTES bytes, tamanho OK"
  else
    log "Referência:   $REF_BYTES bytes, disco MENOR que a referência"
    reprovar "o disco é menor que a referência ($BYTES < $REF_BYTES bytes): não serve como substituto"
  fi
fi

TEM_ZFS=0
lsblk -nro FSTYPE "$DEV" 2>/dev/null | grep -qx zfs_member && TEM_ZFS=1
(( TEM_ZFS )) && log "Atenção:      o disco tem rótulos de um pool ZFS antigo (não importado)."
[[ $ROTA == 0 ]] && log "Atenção:      o disco não é rotacional; o teste destrutivo gasta ciclos de gravação de SSD."

# ------------------------------------------------------------- SMART inicial

{ echo "===== smartctl -x (início) ====="; sc -x; } >>"$LOG" 2>&1
SAUDE=$(sc -H 2>/dev/null | awk -F': +' '/overall-health|Health Status/ { print $2; exit }')
coletar INI

titulo "SMART inicial"
log "Autoavaliação do disco:   ${SAUDE:-indisponível}"
log "Horas ligado:             ${INI[9]:-n/d}"
log "Setores realocados:       ${INI[5]:-n/d}"
log "Setores pendentes:        ${INI[197]:-n/d}"
log "Incorrigíveis offline:    ${INI[198]:-n/d}"
log "Erros de CRC:             ${INI[199]:-n/d}"
log "Erros no log ATA:         ${INI[erros]:-n/d}"

CAPACIDADES=$(sc -c 2>/dev/null)
SUPORTA_AUTOTESTE=0
grep -qE '^[[:space:]]*Self-test supported' <<<"$CAPACIDADES" && SUPORTA_AUTOTESTE=1
MIN_LONGO=$(grep -A1 'Extended self-test routine' <<<"$CAPACIDADES" | grep -oE '\( *[0-9]+\)' | grep -oE '[0-9]+')
BS=4096
while (( BYTES / BS > 4294967295 )); do BS=$(( BS * 2 )); done
HORAS_BB=$(awk -v b="$BYTES" -v p="$PADROES" 'BEGIN { printf "%.0f", b * 2 * p / 100e6 / 3600 }')
if (( PADROES == 1 )); then TXT_PADROES="1 padrão"; else TXT_PADROES="4 padrões"; fi

titulo "Plano"
if (( SUPORTA_AUTOTESTE )); then
  log "1. Autoteste curto: ~2 min"
  log "2. Teste destrutivo, se autorizado: ~$HORAS_BB h ($TXT_PADROES; estimativa a ~100 MB/s)"
  log "3. Autoteste longo: ~${MIN_LONGO:-?} min (estimativa do próprio disco)"
else
  log "O disco não informa suporte a autotestes SMART."
  log "Só o teste destrutivo, se autorizado: ~$HORAS_BB h ($TXT_PADROES; estimativa a ~100 MB/s)"
  alertar "o disco não suporta autotestes SMART"
fi
if [[ -z ${TMUX:-} && -z ${STY:-} ]]; then
  log ""
  log "Aviso: você não está dentro de tmux/screen. Se a sessão cair, o teste é interrompido."
fi

if [[ $SAUDE == *FAILED* ]]; then
  reprovar "a autoavaliação SMART do próprio disco indica falha ($SAUDE)"
  finalizar
fi

# --------------------------------------------- pergunta (única interação)

titulo "Teste destrutivo (opcional)"
log "Grava e relê o disco inteiro. Força o disco a lidar com setores fracos e revela"
log "problemas que só a leitura não mostra. APAGA TODOS OS DADOS DO DISCO."
log "Disco: ${MODELO:-?}, serial ${SERIAL:-?}, $TAMANHO ($ALVO)"
RESPOSTA=""
read -r -p "Executar o teste destrutivo neste disco? [s/N] " RESPOSTA
case $RESPOSTA in
  [sS]|[sS][iI][mM]) DESTRUTIVO=1; log "Resposta: sim. O teste destrutivo roda depois do autoteste curto." ;;
  *)                 DESTRUTIVO=0; log "Resposta: não. Só testes de leitura." ;;
esac

# ----------------------------------------------------------- autoteste curto

if (( SUPORTA_AUTOTESTE )); then
  titulo "Autoteste curto"
  autoteste short; R_CURTO=$?
  if (( R_CURTO == 1 )); then
    reprovar "o autoteste curto falhou"
    finalizar
  fi
  (( R_CURTO == 2 )) && alertar "o autoteste curto não foi concluído"
fi

# ---------------------------------------------------------- teste destrutivo

if (( DESTRUTIVO )); then
  titulo "Teste destrutivo"
  # Confere de novo identidade e uso: o nome sdX pode ter mudado desde o início
  DEV=$(readlink -f "$ALVO"); NAME=${DEV##*/}
  if [[ -n $SERIAL_SMART ]]; then
    SERIAL_AGORA=$(sc -i 2>/dev/null | awk -F': +' '$1 == "Serial Number" { print $2; exit }')
    [[ $SERIAL_AGORA == "$SERIAL_SMART" ]] ||
      morrer "o número de série do dispositivo mudou ($SERIAL_SMART → ${SERIAL_AGORA:-?}). Nada foi gravado."
  fi
  if MOTIVOS=$(em_uso); then
    morrer "$DEV passou a estar em uso:\n$MOTIVOS\nNada foi gravado."
  fi
  limpar_assinaturas
  BB_LISTA="$DIR_LOG/${ROTULO}_${INICIO}_badblocks.txt"
  ARGS=(-b "$BS" -c 1024 -w -s -v -o "$BB_LISTA")
  (( PADROES == 1 )) && ARGS+=(-t random)
  log "Início: $(date '+%d/%m %H:%M'), estimativa: ~$HORAS_BB h"
  BADBLOCKS_RODANDO=1
  badblocks "${ARGS[@]}" "$ALVO"
  BB_STATUS=$?
  BADBLOCKS_RODANDO=0
  BB_EXECUTADO=1
  BB_RUINS=$(grep -c . "$BB_LISTA" 2>/dev/null)
  BB_RUINS=${BB_RUINS:-0}
  log "Fim: $(date '+%d/%m %H:%M'), $BB_RUINS bloco(s) ruim(ns), código de saída $BB_STATUS"
  if (( BB_RUINS > 0 )); then
    reprovar "o badblocks encontrou $BB_RUINS bloco(s) ruim(ns) (lista em $BB_LISTA)"
  elif (( BB_STATUS != 0 )); then
    reprovar "o badblocks terminou com erro (código $BB_STATUS)"
  fi
fi

# ----------------------------------------------------------- autoteste longo

if (( SUPORTA_AUTOTESTE )); then
  titulo "Autoteste longo"
  log "Início: $(date '+%d/%m %H:%M'), estimativa do disco: ~${MIN_LONGO:-?} min"
  autoteste long; R_LONGO=$?
  (( R_LONGO == 1 )) && reprovar "o autoteste longo falhou"
  (( R_LONGO == 2 )) && alertar "o autoteste longo não foi concluído"
fi

finalizar

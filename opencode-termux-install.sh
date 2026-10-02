#!/data/data/com.termux/files/usr/bin/bash
# Instalador do OpenCode para Termux (aarch64) — sem npm, sem proot, sem root
# Uso: curl -fsSL <url> | bash   ou   bash opencode-termux.sh
set -Eeuo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; NC='\033[0m'
err()  { echo -e "${RED}[ERRO]${NC} $*" >&2; exit 1; }
ok()   { echo -e "${GRN}[OK]${NC} $*"; }
info() { echo "[...] $*"; }
warn() { echo -e "${YLW}[AVISO]${NC} $*" >&2; }

# Só instala em aarch64
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) err "Somente aarch64 (arm64). Use 'uname -m' para conferir." ;;
esac

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="$HOME"
BIN_DIR="$HOME_DIR/.opencode/bin"
RUN_DIR="$HOME_DIR/.opencode/run"
BIN_FILE="$RUN_DIR/opencode"
WORK_DIR="$HOME_DIR/tmp/opencode-install"
MUSL_DIR="$RUN_DIR/musl"
RESOLV_DST="/sdcard/r.conf"
RESOLV_REL="/etc/resolv.conf"
trap 'rm -rf "$WORK_DIR"' EXIT

ALPINE_REPO="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_VER="latest-stable"
APK_PKGS="musl libgcc libstdc++"
OPENCODE_URL="https://github.com/anomalyco/opencode/releases/latest/download/opencode-linux-arm64-musl.tar.gz"

# --- Pré-requisitos ---
[ -n "${PREFIX:-}" ] || err "Isso deve rodar dentro do Termux"

pkg_install() {
  pkg install -y "$1" 2>/dev/null || { pkg update -y >/dev/null 2>&1; pkg install -y "$1"; }
}
command -v curl    >/dev/null || pkg_install curl
command -v tar     >/dev/null || pkg_install tar
command -v grep    >/dev/null || pkg_install grep
command -v sed     >/dev/null || pkg_install sed
command -v dd      >/dev/null || pkg_install coreutils
command -v stat    >/dev/null || pkg_install coreutils

# --- Layout ---
mkdir -p "$BIN_DIR" "$WORK_DIR" "$RUN_DIR"

# ============================================================================
# 1. Índice do Alpine: resolve versões + tamanhos dos pacotes
# ============================================================================
info "1/6 Índice do Alpine ($ALPINE_VER)"
APKINDEX="$WORK_DIR/APKINDEX"
if [ ! -s "$APKINDEX" ]; then
  curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$WORK_DIR/APKINDEX.tar.gz" \
    "$ALPINE_REPO/$ALPINE_VER/main/aarch64/APKINDEX.tar.gz" || err "falha ao baixar APKINDEX"
  tar -xzf "$WORK_DIR/APKINDEX.tar.gz" -C "$WORK_DIR" APKINDEX 2>/dev/null || \
    tar -xzf "$WORK_DIR/APKINDEX.tar.gz" -C "$WORK_DIR"
  rm -f "$WORK_DIR/APKINDEX.tar.gz"
fi
[ -s "$APKINDEX" ] || err "APKINDEX inválido"

apk_field() { # apk_field <pkg> <campo>
  grep -a -A20 "^P:$1\$" "$APKINDEX" | grep -a -m1 "^$2:" | cut -d: -f2- | tr -d '\r' || true
}
download() { # download <url> <dest> <tamanho-esperado>
  local url="$1" dest="$2" want="${3:-}"
  if [ -s "$dest" ]; then
    info "já baixado: $(basename "$dest")"
  else
    info "baixando $(basename "$dest")..."
    curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$dest" "$url" || err "falha ao baixar $url"
  fi
  if [ -n "$want" ]; then
    local got
    got=$(stat -c %s "$dest")
    [ "$got" = "$want" ] || err "tamanho divergente em $(basename "$dest"): esperado $want, obtido $got"
  fi
}

# ============================================================================
# 2. Binário do OpenCode (build musl — roda no Android)
# ============================================================================
info "2/6 OpenCode (musl)"
if [ -x "$BIN_FILE" ]; then
  ok "binário já instalado ($(stat -c %s "$BIN_FILE") bytes)"
else
  download "$OPENCODE_URL" "$WORK_DIR/oc-musl.tar.gz"
  tar -xzf "$WORK_DIR/oc-musl.tar.gz" -C "$WORK_DIR" || err "falha ao extrair opencode"
  mv -f "$WORK_DIR/opencode" "$BIN_FILE"
  chmod 755 "$BIN_FILE"
  rm -f "$WORK_DIR/oc-musl.tar.gz"
  ok "binário extraído"
fi

# ============================================================================
# 3. Runtime musl + libs (100% Alpine — sem dpkg, sem mixar glibc/musl)
# ============================================================================
info "3/6 runtime musl + libstdc++/libgcc (Alpine)"
LIBC="$MUSL_DIR/lib/libc.musl-aarch64.so.1"
LOADER="$MUSL_DIR/lib/ld-musl-aarch64.so.1"
if [ -f "$LIBC" ] && [ -f "$MUSL_DIR/usr/lib/libstdc++.so.6" ] && [ -f "$MUSL_DIR/usr/lib/libgcc_s.so.1" ]; then
  ok "runtime já instalado"
else
  mkdir -p "$MUSL_DIR"
  for pkg in $APK_PKGS; do
    ver=$(apk_field "$pkg" V)
    size=$(apk_field "$pkg" S)
    [ -n "$ver" ] || err "versão de $pkg não encontrada no APKINDEX"
    download "$ALPINE_REPO/$ALPINE_VER/main/aarch64/$pkg-$ver.apk" "$WORK_DIR/$pkg.apk" "$size"
    tar -xzf "$WORK_DIR/$pkg.apk" -C "$MUSL_DIR" 2>/dev/null || \
      tar -xzf "$WORK_DIR/$pkg.apk" -C "$MUSL_DIR"
    rm -f "$WORK_DIR/$pkg.apk"
  done
  # Limpa metadados do formato .apk que nao servem para nada aqui.
  rm -f "$MUSL_DIR"/.SIGN.* "$MUSL_DIR/.PKGINFO"
  [ -f "$LIBC" ]    || err "libc musl não encontrada após extração"
  [ -f "$LOADER" ]  || err "loader musl não encontrado após extração"
  ok "runtime musl instalado"
fi

# ============================================================================
# 4. Patch de DNS — musl lê /etc/resolv.conf (não existe no Android)
# ============================================================================
info "4/6 patch de DNS no musl"
# O musl lê /etc/resolv.conf, que não existe no Android. Patchamos a string
# para /sdcard/r.conf (14 bytes <= 16 do original, cabe no mesmo espaco).
# Caminho relativo seria mais bonito, mas resolveria a partir do CWD e o
# opencode passaria a tratar o diretorio do r.conf como projeto.
if grep -q -a -F "$RESOLV_DST" "$LIBC" 2>/dev/null; then
  ok "patch já aplicado"
else
  OFF=$(grep -a -m1 -abo "$RESOLV_REL" "$LIBC" | cut -d: -f1)
  [ -n "$OFF" ] || err "string $RESOLV_REL não encontrada em libc musl"
  cp -f "$LIBC" "$LIBC.bak"
  printf '%s\0' "$RESOLV_DST" | dd of="$LIBC" bs=1 seek="$OFF" conv=notrunc status=none
  grep -q -a -F "$RESOLV_DST" "$LIBC" || err "patch de DNS falhou"
  ok "patch aplicado em offset $OFF -> $RESOLV_DST"
fi

# --- Permissão de armazenamento (necessária para escrever em /sdcard) ---
check_storage() { touch /sdcard/.oc_wtest 2>/dev/null && rm -f /sdcard/.oc_wtest; }
if ! check_storage; then
  info "Permissão de armazenamento necessária — solicitando..."
  info "ACEITE o diálogo do Android que vai aparecer."
  command -v termux-setup-storage >/dev/null && termux-setup-storage
  for _ in $(seq 1 30); do check_storage && break; sleep 2; done
  check_storage || err "Sem acesso a /sdcard. Rode: termux-setup-storage, aceite a permissão e execute este script de novo."
fi

SRC_RESOLV="$PREFIX/etc/resolv.conf"
if [ -s "$SRC_RESOLV" ]; then
  cp -f "$SRC_RESOLV" "$RESOLV_DST" || err "não conseguiu escrever $RESOLV_DST"
else
  printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' > "$RESOLV_DST" || err "não conseguiu escrever $RESOLV_DST"
fi
ok "resolv.conf copiado para $RESOLV_DST"

# ============================================================================
# 5. Wrapper + PATH
# ============================================================================
info "5/6 wrapper e PATH"
cat > "$BIN_DIR/opencode" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
set -e
R="$RUN_DIR"
# Desliga o autoupdate: ele baixaria o build glibc, que nao roda no Android.
export OPENCODE_DISABLE_AUTOUPDATE=1
exec env -u LD_PRELOAD "\$R/musl/lib/ld-musl-aarch64.so.1" \
  --library-path "\$R/musl/usr/lib" "\$R/opencode" "\$@"
EOF
chmod 755 "$BIN_DIR/opencode"
ok "wrapper criado em $BIN_DIR/opencode"

BASHRC="$HOME_DIR/.bashrc"
if ! grep -q '.opencode/bin' "$BASHRC" 2>/dev/null; then
  printf '\n# opencode\nexport PATH="$HOME/.opencode/bin:$PATH"\n' >> "$BASHRC"
  ok "PATH adicionado ao ~/.bashrc (source ~/.bashrc ou abra novo shell)"
else
  ok "PATH já configurado"
fi

# ============================================================================
# 6. Script de atualização (musl) + desinstalador
# ============================================================================
info "6/6 opencode-update e opencode-uninstall"
cat > "$BIN_DIR/opencode-update" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
set -e
R="$RUN_DIR"
# Baixa o JSON inteiro para um arquivo: evita o curl reclamar (erro 23) quando
# o grep -m1 fecha o pipe antes de ele terminar de escrever.
JSON=\$(mktemp)
curl -fsSL -o "\$JSON" https://api.github.com/repos/anomalyco/opencode/releases/latest
LATEST=\$(grep -m1 '"tag_name"' "\$JSON" | sed 's/.*"v\([^\"]*\)".*/\1/')
rm -f "\$JSON"
CURRENT=\$("$BIN_DIR/opencode" --version 2>/dev/null || echo "nenhuma")
echo "Atual: \$CURRENT | Latest: \${LATEST:-<falha na api>}"
[ -n "\${LATEST:-}" ] || { echo "Nao foi possivel consultar a API do GitHub."; exit 1; }
if [ "\$CURRENT" = "\$LATEST" ]; then echo "Ja esta atualizado."; exit 0; fi
W=\$(mktemp -d); trap 'rm -rf "\$W"' EXIT
echo "Baixando opencode \$LATEST (musl)..."
curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "\$W/oc.tar.gz" \
  "https://github.com/anomalyco/opencode/releases/download/v\$LATEST/opencode-linux-arm64-musl.tar.gz"
tar -xzf "\$W/oc.tar.gz" -C "\$W"
[ -x "\$W/opencode" ] || { echo "Binario invalido no tarball."; exit 1; }
cp -f "\$W/opencode" "\$R/opencode.new"
chmod 755 "\$R/opencode.new"
mv -f "\$R/opencode.new" "\$R/opencode"
echo "Atualizado para \$("$BIN_DIR/opencode" --version)"
EOF
chmod 755 "$BIN_DIR/opencode-update"

cat > "$BIN_DIR/opencode-uninstall" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
set -e
R="$RUN_DIR"
echo "Removendo \$R e $BIN_DIR ..."
rm -rf "\$R" "$BIN_DIR"
if grep -q '.opencode/bin' "\$HOME/.bashrc" 2>/dev/null; then
  sed -i '/# opencode/d;/\.opencode\/bin/d' "\$HOME/.bashrc"
  echo "PATH removido do ~/.bashrc"
fi
echo "Concluido. Dados de sessao em ~/.local/share/opencode foram preservados."
EOF
chmod 755 "$BIN_DIR/opencode-uninstall"

# O autoupdate e desligado por OPENCODE_DISABLE_AUTOUPDATE no wrapper, para
# nunca baixar o build glibc. Nao tocamos no seu opencode.json.
ok "autoupdate desativado via env var (config do usuario preservada)"

# ============================================================================
# Teste final
# ============================================================================
echo
"$BIN_DIR/opencode" --version >/dev/null 2>&1 || err "wrapper nao funcionou"
ok "OpenCode $("$BIN_DIR/opencode" --version) instalado"
echo
echo "Uso:    cd <projeto> && opencode"
echo "Update: opencode-update"
echo "Remove: opencode-uninstall"

# ============================================================================
# 7) Reinício do Termux — fecha o app e reabre em seguida
# ============================================================================
# O Termux roda o instalador no processo "servidor" (bash sem tty), que é
# separado do processo do app. Matar só o app derruba a UI e as sessões
# antigas, mas deixa este shell vivo — por isso dá para reabrir na sequencia.
TERMUX_PKG="com.termux"
TERMUX_ACT="$TERMUX_PKG/.app.TermuxActivity"

open_termux() {
  am start --activity-clear-task --activity-new-task -n "$TERMUX_ACT" >/dev/null 2>&1 ||
    am start -n "$TERMUX_ACT" >/dev/null 2>&1 ||
    warn "nao consegui reabrir o Termux — abra o app pelo menu"
}

restart_termux() {
  local app_pid
  app_pid=$(pidof "$TERMUX_PKG" 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+$') || true

  # Rede de seguranca: se o Android derrubar este shell junto com o app, o
  # processo solto abaixo ainda reabre o Termux 3s depois.
  setsid sh -c 'sleep 3; am start --activity-clear-task --activity-new-task -n "$1" >/dev/null 2>&1 || am start -n "$1" >/dev/null 2>&1' _ "$TERMUX_ACT" </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true

  if [ -n "$app_pid" ] && [ "$app_pid" != "$$" ]; then
    kill -9 "$app_pid" 2>/dev/null || true
    sleep 1
  fi
  open_termux
}

echo
if [ "${OPENCODE_NO_RESTART:-0}" = "1" ]; then
  info "reinicio do Termux pulado (OPENCODE_NO_RESTART=1)"
else
  warn "O Termux sera FECHADO e REABERTO em 10s — o app fecha e volta em seguida."
  warn "Ctrl+C cancela o reinicio."
  for i in 10 9 8 7 6 5 4 3 2 1; do
    printf '\r  reiniciando em %2ds... ' "$i"
    sleep 1
  done
  printf '\r'
  ok "reiniciando o Termux agora"
  restart_termux
fi

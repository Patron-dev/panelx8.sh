#!/usr/bin/env bash
# ============================================================
#  Conexion BHTTP  |  Panel Profesional
#  Desarrollado por: Felix & Jalmer
#  Telegram: @null_ptr_404  |  @Nica505J
# ============================================================
set -uo pipefail
# -------------------- COLORES --------------------
R='\033[0;31m'      # Rojo
G='\033[0;32m'      # Verde
Y='\033[1;33m'      # Amarillo
B='\033[0;34m'      # Azul
C='\033[0;36m'      # Cyan
M='\033[0;35m'      # Magenta
W='\033[1;37m'      # Blanco
D='\033[0;90m'      # Gris
N='\033[0m'         # Reset
BG='\033[42m'       # Fondo verde
BC='\033[46m'       # Fondo cyan
# -------------------- RUTAS --------------------
DESTDIR="/usr/local/lib/bhttp"
SERVER_PY="$DESTDIR/bhttp-server.py"
UNIT="/etc/systemd/system/bhttp.service"
SERVICE="bhttp"
CONFIG="/etc/bhttp/nullcore.conf"
CANDIDATOS=(8080 80 8443 443 2082 2095 8880 2052 3128)
# -------------------- VARIABLES --------------------
PUERTO=""
SSHPORT=22
VERSION="1.0.0"
# -------------------- FUNCIONES BASE --------------------
rojo()  { printf "${R}%s${N}\n" "$*"; }
verde() { printf "${G}%s${N}\n" "$*"; }
info()  { printf "  ${D}%s${N}\n" "$*"; }
paso()  { printf "\n${C}[%s]${N} ${W}%s${N}\n" "$1" "$2"; }
linea() { printf "${D}────────────────────────────────────────────────────────${N}\n"; }
# -------------------- BANNER --------------------
banner() {
  clear
  echo -e "${C}"
  cat << 'EOF'
░░      ░░░░      ░░░       ░░░        ░░       ░░░        ░
▒  ▒▒▒▒▒▒▒▒  ▒▒▒▒  ▒▒  ▒▒▒▒  ▒▒▒▒▒  ▒▒▒▒▒  ▒▒▒▒  ▒▒▒▒▒  ▒▒▒▒
▓▓      ▓▓▓  ▓▓▓▓▓▓▓▓       ▓▓▓▓▓▓  ▓▓▓▓▓       ▓▓▓▓▓▓  ▓▓▓▓
███████  ██  ████  ██  ███  ██████  █████  ███████████  ████
██      ████      ███  ████  ██        ██  ███████████  ████
EOF
  echo -e "${N}"
  echo -e "          ${W}B H T T P   P R O T O C O L${N}  ${D}v${VERSION}${N}"
  echo -e "          ${G}Felix${N} ${D}&${N} ${C}Jalmer${N}  ${D}|  Panel Version${N}"
  linea
}
# -------------------- VERIFICAR ROOT --------------------
check_root() {
  if [ "$(id -u 2>/dev/null || echo 0)" != 0 ]; then
    rojo "Ejecuta como root:  sudo bash $0"
    exit 2
  fi
}
# -------------------- CARGAR CONFIG --------------------
cargar_config() {
  mkdir -p /etc/bhttp
  if [ -f "$CONFIG" ]; then
    source "$CONFIG"
  fi
  [ -z "${PUERTO:-}" ] && PUERTO=""
  [ -z "${SSHPORT:-}" ] && SSHPORT=22
}
guardar_config() {
  mkdir -p /etc/bhttp
  cat > "$CONFIG" <<EOF
PUERTO=${PUERTO}
SSHPORT=${SSHPORT}
EOF
}
# -------------------- CREAR USUARIO --------------------
crear_usuario() {
  local u="$1" p="$2"
  if id "$u" >/dev/null 2>&1; then
    info "El usuario '$u' ya existe. Actualizando clave..."
  else
    useradd -M -s /bin/bash "$u" || { rojo "No se pudo crear el usuario '$u'"; return 1; }
    info "Usuario '$u' creado (shell /bin/bash)"
  fi
  if [ -z "$p" ]; then
    p="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 12)"
    [ -z "$p" ] && p="$(date +%s | tail -c 7)"
    info "Clave generada automáticamente"
  fi
  echo "$u:$p" | chpasswd || { rojo "Error al establecer la clave"; return 1; }
  USER_FINAL="$u"
  PASS_FINAL="$p"
  return 0
}
# -------------------- DIAGNÓSTICO --------------------
diagnostico_ssh() {
  paso "DIAG" "Comprobando entorno SSH / red"
  local cfg="/etc/ssh/sshd_config" fwd=""
  [ -r "$cfg" ] && fwd="$(grep -iE '^[[:space:]]*AllowTcpForwarding' "$cfg" | tail -1 | awk '{print tolower($2)}')"
  if [ "$fwd" = "no" ]; then
    rojo "  AllowTcpForwarding = no  →  El túnel NO podrá salir"
    echo "     Solución: sed -i 's/^[[:space:]]*AllowTcpForwarding.*/AllowTcpForwarding yes/' $cfg && systemctl restart ssh"
  else
    info "AllowTcpForwarding: ${fwd:-yes (por defecto)} → OK"
  fi
  if timeout 5 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53' 2>/dev/null; then
    info "Salida TCP a 8.8.8.8:53 (DNS): OK"
  else
    rojo "  La VPS no alcanza 8.8.8.8:53 → Problema de salida de red"
  fi
  if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -qE ":$SSHPORT\b"; then
    info "sshd escuchando en puerto $SSHPORT: OK"
  else
    rojo "  No se detecta sshd en el puerto $SSHPORT"
  fi
}
# -------------------- PUERTOS --------------------
ocupados() {
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | tail -n +2 | awk '{print $4}' | sed 's/.*://'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '/^tcp/ {print $4}' | sed 's/.*://'
  fi | grep -E '^[0-9]+$' | sort -u
}
libre() { ! ocupados | grep -qx "$1"; }
# -------------------- INSTALAR SERVIDOR --------------------
instalar_servidor() {
  banner
  echo -e "${W}  Instalando conexión BHTTP...${N}"
  linea
  command -v python3 >/dev/null 2>&1 || { rojo "Falta python3. Instálalo: apt install -y python3"; return 1; }
  paso "1/4" "Selección de puerto"
  local primer_libre=""
  for p in "${CANDIDATOS[@]}"; do libre "$p" && { primer_libre="$p"; break; }; done
  if [ -z "$PUERTO" ]; then
    read -r -p "  Puerto BHTTP [${primer_libre:-8080}]: " PUERTO
    [ -z "$PUERTO" ] && PUERTO="${primer_libre:-8080}"
  fi
  if ! [[ "$PUERTO" =~ ^[0-9]+$ ]] || [ "$PUERTO" -lt 1 ] || [ "$PUERTO" -gt 65535 ]; then
    rojo "Puerto inválido: $PUERTO"; return 1
  fi
  if ! libre "$PUERTO"; then
    rojo "El puerto $PUERTO está ocupado"; return 1
  fi
  info "Puerto seleccionado: $PUERTO  |  Backend SSH: 127.0.0.1:$SSHPORT"
  paso "2/4" "Escribiendo servidor Python"
  mkdir -p "$DESTDIR"
  cat > "$SERVER_PY" << 'PYEOF'
#!/usr/bin/env python3
# Servidor BHTTP autónomo (Null) - asyncio
import argparse, asyncio, hashlib, struct, sys
MAGIC = b"BHP1"
LONGPOLL = 2.0
def log(msg):
    sys.stderr.write("[bhttp] %s\n" % msg); sys.stderr.flush()
def keystream(sess, mode, seq, d, n):
    base = hashlib.sha256(sess + bytes([mode]) + seq.to_bytes(8, "big") + bytes([d]))
    out = bytearray(); c = 0
    while len(out) < n:
        h = base.copy(); h.update(c.to_bytes(4, "big")); out += h.digest(); c += 1
    return bytes(out[:n])
def mask(data, sess, mode, seq, d):
    return bytes(a ^ b for a, b in zip(data, keystream(sess, mode, seq, d, len(data))))
def probe_reply(mode, size):
    n = size if (mode == 2 and size >= 10) else 10
    out = bytearray(MAGIC + bytes([1, mode]) + size.to_bytes(4, "big"))
    for i in range(10, n):
        out.append((i * 31) & 255)
    return bytes(out)
class Session:
    def __init__(self, sess, backend):
        self.sess = sess
        self.backend = backend
        self.cond = asyncio.Condition()
        self.up_next = 0
        self.up_pending = {}
        self.down_raw = bytearray()
        self.down_chunks = {}
        self.down_assign = 0
        self.eof = False
        self.closed = False
        self.br = None
        self.bw = None
    async def connect(self):
        host, port = self.backend
        self.br, self.bw = await asyncio.open_connection(host, port)
        log("sesion %s: conectada al backend %s:%d" % (self.sess.hex()[:8], host, port))
        asyncio.create_task(self._reader())
    async def _reader(self):
        total = 0
        try:
            while True:
                data = await self.br.read(65536)
                if not data: break
                total += len(data)
                async with self.cond:
                    self.down_raw += data
                    self.cond.notify_all()
        except Exception as e:
            log("sesion %s: error leyendo del backend: %s" % (self.sess.hex()[:8], e))
        finally:
            log("sesion %s: el backend cerro (recibidos %d B)" % (self.sess.hex()[:8], total))
            async with self.cond:
                self.eof = True
                self.cond.notify_all()
    async def upload(self, seq, data):
        async with self.cond:
            if data:
                self.up_pending[seq] = data
            while self.up_next in self.up_pending:
                chunk = self.up_pending.pop(self.up_next)
                try:
                    self.bw.write(chunk)
                    await self.bw.drain()
                except Exception:
                    self.closed = True
                self.up_next += 1
    async def download(self, seq, maxlen, deadline):
        if maxlen <= 0: maxlen = 1399
        loop = asyncio.get_running_loop()
        async with self.cond:
            while True:
                if seq < self.down_assign:
                    return self.down_chunks.get(seq, b"")
                if seq == self.down_assign:
                    if self.down_raw:
                        take = bytes(self.down_raw[:maxlen]); del self.down_raw[:maxlen]
                        self.down_chunks[self.down_assign] = take
                        self.down_assign += 1
                        self.cond.notify_all()
                        return take
                    if self.eof:
                        self.down_assign += 1
                        self.cond.notify_all()
                        return b""
                if not self.eof and loop.time() < deadline:
                    try:
                        await asyncio.wait_for(self.cond.wait(), timeout=max(0.01, deadline - loop.time()))
                    except asyncio.TimeoutError:
                        pass
                    continue
                while self.down_assign <= seq:
                    self.down_assign += 1
                self.cond.notify_all()
                return b""
    async def ack(self, seq):
        async with self.cond:
            for k in [k for k in self.down_chunks if k <= seq]:
                del self.down_chunks[k]
    async def close(self):
        async with self.cond:
            self.closed = True
            self.cond.notify_all()
        try: self.bw.close()
        except Exception: pass
class Server:
    def __init__(self, host, port, backend):
        self.host, self.port, self.backend = host, port, backend
        self.sessions = {}
        self.slock = asyncio.Lock()
    async def get_session(self, sess):
        async with self.slock:
            s = self.sessions.get(sess)
            if s is None or s.closed:
                for old_sid, old in list(self.sessions.items()):
                    if old_sid != sess:
                        await old.close()
                        del self.sessions[old_sid]
                s = Session(sess, self.backend)
                await s.connect()
                self.sessions[sess] = s
                log("sesion %s: registrada (vivas: %d)" % (sess.hex()[:8], len(self.sessions)))
            return s
    async def handle(self, reader, writer):
        try:
            while True:
                hdr = await reader.readexactly(29)
                mode = hdr[0]
                sess = hdr[1:17]
                seq = int.from_bytes(hdr[17:25], "big")
                ln = int.from_bytes(hdr[25:29], "big")
                payload = b""
                if ln and mode in (0, 1, 2, 3):
                    raw = await reader.readexactly(ln)
                    payload = mask(raw, sess, mode, seq, 0)
                if payload[:4] == MAGIC:
                    size = int.from_bytes(payload[6:10], "big") if len(payload) >= 10 else 0
                    pmode = payload[5] if len(payload) >= 6 else mode
                    body = mask(probe_reply(pmode, size), sess, mode, seq, 1)
                    writer.write(bytes([0]) + len(body).to_bytes(4, "big") + body)
                    await writer.drain()
                    continue
                s = await self.get_session(sess)
                if mode == 1:
                    await s.upload(seq, payload)
                    writer.write(bytes([0]) + (0).to_bytes(4, "big"))
                    await writer.drain()
                elif mode == 2:
                    chunk = await s.download(seq, ln if ln > 0 else 1399, asyncio.get_running_loop().time() + LONGPOLL)
                    self._send_data(writer, sess, mode, seq, chunk)
                    await writer.drain()
                elif mode == 3:
                    if len(payload) >= 6:
                        chunk_size = int.from_bytes(payload[0:4], "big"); count = payload[5]
                    else:
                        chunk_size, count = 1399, 1
                    if chunk_size <= 0: chunk_size = 1399
                    if count <= 0: count = 1
                    deadline = asyncio.get_running_loop().time() + LONGPOLL
                    for i in range(count):
                        chunk = await s.download(seq + i, chunk_size, deadline)
                        self._send_data(writer, sess, mode, seq + i, chunk)
                    await writer.drain()
                elif mode == 4:
                    await s.ack(seq)
                    writer.write(bytes([0]) + (0).to_bytes(4, "big"))
                    await writer.drain()
                else:
                    return
        except (asyncio.IncompleteReadError, ConnectionError, OSError):
            pass
        except Exception as e:
            log("handle: %r" % e)
        finally:
            try: writer.close()
            except Exception: pass
    def _send_data(self, writer, sess, mode, seq, data):
        real = len(data)
        masked = mask(data, sess, mode, seq, 1) if data else b""
        body = real.to_bytes(4, "big") + masked
        writer.write(bytes([2]) + len(body).to_bytes(4, "big") + body)
    async def serve(self):
        srv = await asyncio.start_server(self.handle, self.host, self.port, backlog=512)
        print("BHTTP escuchando en %s:%d -> backend %s:%d" % (self.host, self.port, self.backend[0], self.backend[1]), flush=True)
        async with srv:
            await srv.serve_forever()
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--backend-host", default="127.0.0.1")
    ap.add_argument("--backend-port", type=int, default=22)
    a = ap.parse_args()
    asyncio.run(Server(a.host, a.port, (a.backend_host, a.backend_port)).serve())
if __name__ == "__main__":
    main()
PYEOF
  chmod +x "$SERVER_PY"
  if ! python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SERVER_PY"; then
    rojo "Error al escribir el servidor Python"; return 1
  fi
  info "Servidor instalado en $SERVER_PY"
  paso "3/4" "Creando servicio systemd"
  PYBIN="$(command -v python3)"
  cat > "$UNIT" <<EOF
[Unit]
Description=BHTTP Server (puerto $PUERTO)
After=network.target
[Service]
Type=simple
ExecStart=$PYBIN $SERVER_PY --host 0.0.0.0 --port $PUERTO --backend-host 127.0.0.1 --backend-port $SSHPORT
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1
  systemctl restart "$SERVICE"
  paso "4/4" "Verificando servicio"
  sleep 2
  if systemctl is-active --quiet "$SERVICE"; then
    verde "Servicio activo y escuchando en el puerto $PUERTO"
    guardar_config
  else
    rojo "El servicio no arrancó correctamente"
    journalctl -u "$SERVICE" -n 15 --no-pager
    return 1
  fi
  local IP
  IP="$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
  echo
  verde "=== INSTALACIÓN COMPLETADA ==="
  echo -e "  Host      : ${W}${IP}${N}"
  echo -e "  Puerto    : ${W}${PUERTO}${N}"
  echo -e "  Protocolo : ${W}bhttp${N}"
  echo -e "  Backend   : ${W}127.0.0.1:${SSHPORT}${N}"
  echo
  read -p "  Presiona Enter para continuar..."
}
# -------------------- DESINSTALAR --------------------
desinstalar() {
  banner
  echo -e "${Y}  ¿Seguro que deseas desinstalar el panel BHTTP? (s/N)${N}"
  read -r conf
  [[ "$conf" =~ ^[sS] ]] || return
  systemctl stop "$SERVICE" 2>/dev/null
  systemctl disable "$SERVICE" 2>/dev/null
  rm -f "$UNIT"
  rm -rf "$DESTDIR"
  rm -f "$CONFIG"
  systemctl daemon-reload 2>/dev/null
  verde "Panel BHTTP desinstalado correctamente."
  sleep 2
}
# -------------------- GESTIÓN DE USUARIOS --------------------
menu_usuarios() {
  while true; do
    banner
    echo -e "  ${W}GESTIÓN DE USUARIOS${N}"
    linea
    echo -e "  ${G}[1]${N}  Crear usuario para túnel"
    echo -e "  ${G}[2]${N}  Listar usuarios del sistema"
    echo -e "  ${G}[3]${N}  Cambiar clave de usuario"
    echo -e "  ${G}[4]${N}  Eliminar usuario"
    echo -e "  ${R}[0]${N}  Volver al menú principal"
    linea
    read -r -p "  Selecciona una opción: " op
    case $op in
      1)
        echo
        read -r -p "  Nombre de usuario: " nu
        read -r -p "  Clave (dejar vacío = generar): " np
        if crear_usuario "$nu" "$np"; then
          verde "Usuario listo:"
          echo -e "    Usuario : ${W}${USER_FINAL}${N}"
          echo -e "    Clave   : ${W}${PASS_FINAL}${N}"
        fi
        read -p "  Enter para continuar..."
        ;;
      2)
        echo
        echo -e "${W}  Usuarios del sistema (UID >= 1000):${N}"
        linea
        awk -F: '$3 >= 1000 && $1 != "nobody" {print "  → " $1}' /etc/passwd
        echo
        read -p "  Enter para continuar..."
        ;;
      3)
        echo
        read -r -p "  Usuario: " nu
        read -r -p "  Nueva clave: " np
        if id "$nu" >/dev/null 2>&1; then
          echo "$nu:$np" | chpasswd && verde "Clave actualizada"
        else
          rojo "Usuario no existe"
        fi
        read -p "  Enter para continuar..."
        ;;
      4)
        echo
        read -r -p "  Usuario a eliminar: " nu
        if id "$nu" >/dev/null 2>&1; then
          userdel -r "$nu" 2>/dev/null && verde "Usuario eliminado" || rojo "Error al eliminar"
        else
          rojo "Usuario no existe"
        fi
        read -p "  Enter para continuar..."
        ;;
      0) return ;;
      *) rojo "Opción inválida" ;;
    esac
  done
}
# -------------------- CONTROL DE SERVICIO --------------------
menu_servicio() {
  while true; do
    banner
    local estado
    estado=$(systemctl is-active "$SERVICE" 2>/dev/null || echo "inactive")
    echo -e "  ${W}CONTROL DEL SERVICIO${N}   Estado: ${estado}"
    linea
    echo -e "  ${G}[1]${N}  Iniciar servicio"
    echo -e "  ${G}[2]${N}  Detener servicio"
    echo -e "  ${G}[3]${N}  Reiniciar servicio"
    echo -e "  ${G}[4]${N}  Ver estado detallado"
    echo -e "  ${G}[5]${N}  Ver logs en vivo"
    echo -e "  ${R}[0]${N}  Volver"
    linea
    read -r -p "  Opción: " op
    case $op in
      1) systemctl start "$SERVICE" && verde "Servicio iniciado" || rojo "Error"; sleep 1 ;;
      2) systemctl stop "$SERVICE" && verde "Servicio detenido" || rojo "Error"; sleep 1 ;;
      3) systemctl restart "$SERVICE" && verde "Servicio reiniciado" || rojo "Error"; sleep 1 ;;
      4) systemctl status "$SERVICE" --no-pager; read -p "Enter..." ;;
      5) echo -e "${Y}Ctrl+C para salir de los logs${N}"; sleep 1; journalctl -u "$SERVICE" -f ;;
      0) return ;;
    esac
  done
}
# -------------------- INFORMACIÓN --------------------
info_sistema() {
  banner
  echo -e "  ${W}INFORMACIÓN DEL SISTEMA${N}"
  linea
  local IP
  IP="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
  echo -e "  IP Pública     : ${G}${IP}${N}"
  echo -e "  Puerto BHTTP   : ${G}${PUERTO:-No instalado}${N}"
  echo -e "  Puerto SSH     : ${G}${SSHPORT}${N}"
  echo -e "  Estado servicio: $(systemctl is-active $SERVICE 2>/dev/null || echo 'no instalado')"
  echo -e "  Sistema        : $(uname -srm)"
  echo -e "  Uptime         : $(uptime -p 2>/dev/null || uptime)"
  echo
  diagnostico_ssh
  echo
  read -p "  Enter para volver..."
}
# -------------------- CRÉDITOS --------------------
creditos() {
  banner
  echo -e "  ${W}CRÉDITOS${N}"
  linea
  echo -e "  ${G}Panel BHTTP${N}  v${VERSION}"
  echo
  echo -e "  Desarrollado por:"
  echo -e "    ${W}Felix${N}   →  ${C}https://t.me/null_ptr_404${N}"
  echo -e "    ${W}Jalmer${N}  →  ${C}https://t.me/Nica505J${N}"
  echo
  echo -e "  ${D}Protocolo BHTTP optimizado + Panel de gestión profesional${N}"
  echo
  linea
  read -p "  Enter para volver..."
}
# -------------------- MENÚ PRINCIPAL --------------------
menu_principal() {
  while true; do
    banner
    local estado
    estado=$(systemctl is-active "$SERVICE" 2>/dev/null || echo "no instalado")
    echo -e "  Estado actual: ${estado}   |   Puerto: ${PUERTO:-—}"
    linea
    echo -e "  ${G}[1]${N}  Instalar / Reinstalar"
    echo -e "  ${G}[2]${N}  Gestión de Usuarios"
    echo -e "  ${G}[3]${N}  Control del Servicio"
    echo -e "  ${G}[4]${N}  Información y Diagnóstico"
    echo -e "  ${G}[5]${N}  Cambiar puerto SSH backend"
    echo -e "  ${G}[6]${N}  Créditos"
    echo -e "  ${R}[7]${N}  Desinstalar"
    echo -e "  ${R}[0]${N}  Salir"
    linea
    read -r -p "  Selecciona una opción: " opcion
    case $opcion in
      1) instalar_servidor ;;
      2) menu_usuarios ;;
      3) menu_servicio ;;
      4) info_sistema ;;
      5)
        read -r -p "  Nuevo puerto SSH backend [${SSHPORT}]: " nuevo
        [ -n "$nuevo" ] && SSHPORT="$nuevo" && guardar_config && verde "Puerto SSH actualizado a $SSHPORT"
        sleep 1
        ;;
      6) creditos ;;
      7) desinstalar ;;
      0) echo -e "\n  ${D}Panel BHTTP finalizado.${N}\n"; exit 0 ;;
      *) rojo "Opción no válida" ;;
    esac
  done
}
# -------------------- INICIO --------------------
check_root
cargar_config
menu_principal


#!/bin/bash
### Deploy Automático - Praça de Pedágio SorveSys (Captura) ###
#
# Uso:
#   sudo DB_PASSWORD='sua_senha' ./setup_pedagio.sh     (sem perguntas)
#   sudo ./setup_pedagio.sh                             (pergunta a senha)
#
# Variáveis opcionais:
#   DB_HOST   IP do banco            (padrão: 35.171.71.79; na mesma VPC use o IP PRIVADO)
#   DB_USER   usuário do banco       (padrão: agente_pedagio)
#   DB_NAME   base de dados          (padrão: sorvesys_db)
#   HOST_IP   IP desta máquina cadastrado no site (padrão: detectado)
#   TZ        fuso dos registros     (padrão: America/Sao_Paulo)
#
# Log da instalação: /var/log/sorvesys-coleta.log

REPO_CAPTURA="https://github.com/SorveSys/CODIGOS_CAPTURAS.git"
PASTA_CAPTURA="/opt/sorvesys-captura"
PASTA_CONFIG="/etc/sorvesys"
ARQUIVO_ENV="$PASTA_CONFIG/captura.env"
IMAGEM="sorvesys-captura:3.0"
LOG="/var/log/sorvesys-coleta.log"

DB_HOST="${DB_HOST:-35.171.71.79}"
DB_USER="${DB_USER:-agente_pedagio}"
DB_NAME="${DB_NAME:-sorvesys_db}"
DB_PORT=3306
TZ="${TZ:-America/Sao_Paulo}"

falhar() {
    echo "[ERRO] $1"
    exit 1
}

# Roda um comando guardando a saída no log; se falhar, mostra o final do log.
# Uso: executar "mensagem de erro" comando args...
executar() {
    local msg="$1"
    shift
    echo "--- $(date '+%F %T') \$ $*" >> "$LOG"
    if ! "$@" >> "$LOG" 2>&1; then
        echo "[ERRO] $msg"
        echo "------ últimas linhas de $LOG ------"
        tail -n 20 "$LOG"
        echo "------------------------------------"
        exit 1
    fi
}

clear
echo "======================================================="
echo "       INICIANDO INSTALAÇÃO - SORVESYS CAPTURA         "
echo "======================================================="
echo "Configurando ambiente de monitoramento de hardware..."

if [ "$EUID" -ne 0 ]; then
    echo "Por favor, execute com permissão de administrador: sudo ./setup_pedagio.sh"
    exit 1
fi

touch "$LOG" && chmod 600 "$LOG" || falhar "Não consegui criar o log $LOG."

# --- Senha do banco: variável de ambiente ou pergunta (nunca fica no script) ----
if [ -z "${DB_PASSWORD:-}" ]; then
    if [ -t 0 ]; then
        read -r -s -p "Senha do usuário '$DB_USER' no banco: " DB_PASSWORD
        echo ""
    fi
    [ -n "${DB_PASSWORD:-}" ] || falhar "Defina DB_PASSWORD (ex.: sudo DB_PASSWORD='...' ./setup_pedagio.sh)."
fi

echo "[1/5] Instalando dependências base (git, docker)... (log: $LOG)"
export DEBIAN_FRONTEND=noninteractive
if ! apt-get update -y >> "$LOG" 2>&1; then
    echo "   ⚠️  apt-get update falhou (veja $LOG). Tentando instalar mesmo assim..."
fi
executar "Falha ao instalar pacotes (apt)." apt-get install -y git curl iproute2
if ! command -v docker &> /dev/null; then
    executar "Falha ao instalar o Docker." apt-get install -y docker.io
fi
executar "Não consegui iniciar o Docker." systemctl enable --now docker

echo "[2/5] Baixando os agentes de captura (Java e Python) do GitHub..."
if [ -d "$PASTA_CAPTURA/.git" ]; then
    executar "git pull falhou." git -C "$PASTA_CAPTURA" pull
else
    rm -rf "$PASTA_CAPTURA"
    executar "git clone falhou ($REPO_CAPTURA)." git clone "$REPO_CAPTURA" "$PASTA_CAPTURA"
fi

cd "$PASTA_CAPTURA" || falhar "Pasta $PASTA_CAPTURA não existe."

for arquivo in Dockerfile requirements.txt captura.py coletor.jar; do
    [ -f "$arquivo" ] || falhar "'$arquivo' não está na raiz do repositório $REPO_CAPTURA."
done

echo "[3/5] Descobrindo o IP desta máquina e testando o banco..."
if [ -z "${HOST_IP:-}" ]; then
    # IP de origem que esta máquina usa para chegar ao banco (em EC2 = IP privado)
    DB_IP=$(getent ahostsv4 "$DB_HOST" 2>/dev/null | awk '{print $1; exit}')
    DB_IP="${DB_IP:-$DB_HOST}"
    HOST_IP=$(ip -4 route get "$DB_IP" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    [ -n "$HOST_IP" ] || HOST_IP=$(hostname -I | awk '{print $1}')
fi
[ -n "$HOST_IP" ] || falhar "Não consegui descobrir o IP da máquina. Rode com HOST_IP=<ip>."

echo "   IP desta máquina (HOST_IP): $HOST_IP"
echo "   Banco: $DB_HOST:$DB_PORT (usuário $DB_USER, base $DB_NAME)"

if timeout 5 bash -c "exec 3<>/dev/tcp/$DB_HOST/$DB_PORT" 2>/dev/null; then
    echo "   ✅ Porta $DB_PORT do banco acessível."
else
    echo "   ⚠️  Não consegui abrir $DB_HOST:$DB_PORT. Verifique o Security Group do banco"
    echo "      (entrada TCP 3306 liberada para este servidor) e se o IP está correto."
    echo "      Vou continuar, mas os coletores vão ficar tentando até o banco responder."
fi

# Credenciais em arquivo só do root, e não na linha de comando (visível em 'docker inspect'/'ps')
mkdir -p "$PASTA_CONFIG"
umask 077
cat > "$ARQUIVO_ENV" << EOF
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT
DB_USER=$DB_USER
DB_PASS=$DB_PASSWORD
DB_PASSWORD=$DB_PASSWORD
DB_NAME=$DB_NAME
HOST_IP=$HOST_IP
TZ=$TZ
PYTHONUNBUFFERED=1
EOF
chmod 600 "$ARQUIVO_ENV"
umask 022

echo "[4/5] Construindo a imagem $IMAGEM (usa o Dockerfile do repositório)..."
executar "docker build falhou." docker build -t "$IMAGEM" -f Dockerfile .

echo "[5/5] Iniciando os agentes de monitoramento..."
# remove containers anteriores (é normal dar erro na primeira execução)
docker rm -f sorvesys-captura sorvesys-captura-py sorvesys-captura-java >> "$LOG" 2>&1

docker run -d --name sorvesys-captura-py \
    --net=host --restart unless-stopped \
    --env-file "$ARQUIVO_ENV" \
    "$IMAGEM" python3 -u captura.py >> "$LOG" 2>&1 || falhar "Não consegui iniciar o container Python (veja $LOG)."

docker run -d --name sorvesys-captura-java \
    --net=host --restart unless-stopped \
    --env-file "$ARQUIVO_ENV" \
    "$IMAGEM" java -jar coletor.jar >> "$LOG" 2>&1 || falhar "Não consegui iniciar o container Java (veja $LOG)."

sleep 8

echo "======================================================="
echo "INSTALAÇÃO CONCLUÍDA!"
echo "IP desta máquina: $HOST_IP"
echo ">> O Gestor precisa cadastrar este servidor no site com ESTE IP. <<"
echo ""
echo "Acompanhar:"
echo "  sudo docker logs -f sorvesys-captura-py"
echo "  sudo docker logs -f sorvesys-captura-java"
echo "Log da instalação: $LOG"
echo "======================================================="
echo ""
docker ps --filter "name=sorvesys-captura" --format "table {{.Names}}\t{{.Status}}"
echo ""
echo "--- últimas linhas: python ---"
docker logs --tail 5 sorvesys-captura-py 2>&1
echo "--- últimas linhas: java ---"
docker logs --tail 5 sorvesys-captura-java 2>&1

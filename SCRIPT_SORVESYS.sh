#!/bin/bash
### Deploy - Servidor Central SorveSys (Empresa) ###

clear

echo "======================================================="
echo "       DEPLOY SORVESYS - SERVIDOR CENTRAL (AWS EC2)    "
echo "======================================================="

IP_ELASTICO="IP_SERVER"
DISCO_NOME="nvme1n1"
REPO_SITE="https://github.com/SorveSys/site-instituicional.git"
PASTA_SITE="$PWD/site-instituicional"
LINK_SQL="https://github.com/SorveSys/Banco_SorveSys/raw/refs/heads/main/Script_SorveSys.sql"
PASTA_DISCO="/mnt/dados_banco"
PASTA_DADOS="$PASTA_DISCO/mysql"
PASTA_INIT="/opt/sorvesys-db-init"

if [ "$EUID" -ne 0 ]; then 
    echo "Por favor, execute com permissão de administrador: sudo ./SorveSys"
    exit 1
fi

read -s -p "Defina a senha para o Banco de Dados (MySQL): " SENHA_BANCO
echo "" 
echo "======================================================="

echo "Atualizando sistema e instalando dependências base..."
apt update && apt upgrade -y > /dev/null 2>&1
apt install git wget curl -y > /dev/null 2>&1

if ! command -v docker &> /dev/null; then
    echo "Instalando Docker..."
    apt install docker.io -y > /dev/null 2>&1
    systemctl enable --now docker
fi

echo ""
read -p "Agora será instalado o Banco de Dados com as tabelas. Deseja prosseguir? (S/N) " RESP_DB

read -p "Agora será instalado o Banco de Dados com as tabelas. Deseja prosseguir? (S/N) " RESP_DB
if [[ "$RESP_DB" =~ ^[Ss]$ ]]; then

    echo "Configurando o disco /dev/$DISCO_NOME para o Banco de Dados..."
    mkdir -p "$PASTA_DISCO"
    if lsblk | grep -q "$DISCO_NOME"; then
        if ! blkid /dev/$DISCO_NOME | grep -q "ext4"; then
            mkfs.ext4 -F /dev/$DISCO_NOME
        fi
        if ! mountpoint -q "$PASTA_DISCO"; then
            mount /dev/$DISCO_NOME "$PASTA_DISCO"
        fi
        # fstab pelo UUID, sem duplicar a entrada em reexecuções
        UUID_DISCO=$(blkid -s UUID -o value /dev/$DISCO_NOME)
        if ! grep -q "$UUID_DISCO" /etc/fstab; then
            echo "UUID=$UUID_DISCO $PASTA_DISCO ext4 defaults,nofail 0 2" >> /etc/fstab
        fi
    fi

    # Subpasta dedicada: evita o lost+found na raiz do ext4
    mkdir -p "$PASTA_DADOS"

    echo "Baixando a estrutura do banco de dados (Tabelas)..."
    mkdir -p "$PASTA_INIT"
    wget -q -O "$PASTA_INIT/init.sql" "$LINK_SQL" || { echo "ERRO: falha ao baixar o SQL."; exit 1; }

    docker rm -f sorvesys-db 2>/dev/null

    # Se o diretório de dados não tem um banco válido (sem mysql/), limpa resíduos
    # para o MySQL poder inicializar e executar o init.sql
    if [ ! -d "$PASTA_DADOS/mysql" ]; then
        find "$PASTA_DADOS" -mindepth 1 -delete
    fi

    docker run -d --name sorvesys-db --restart unless-stopped \
        -e MYSQL_ROOT_PASSWORD="$SENHA_BANCO" \
        -e MYSQL_DATABASE=sorvesys_db \
        -p 3306:3306 \
        -v "$PASTA_DADOS":/var/lib/mysql \
        -v "$PASTA_INIT":/docker-entrypoint-initdb.d:ro \
        mysql:8.0

    echo "Aguardando o MySQL iniciar (pode levar alguns minutos)..."
    OK=0
    for i in $(seq 1 100); do
        if docker exec sorvesys-db mysqladmin ping -uroot -p"$SENHA_BANCO" --silent 2>/dev/null; then
            OK=1
            break
        fi
        sleep 3
    done

    if [ "$OK" -eq 1 ]; then
        echo "Banco de dados MySQL operando na porta 3306 com as tabelas criadas."
    else
        echo "ERRO: o MySQL não iniciou. Últimas linhas do log:"
        docker logs sorvesys-db --tail 20
        exit 1
    fi
fi

echo ""
read -p "Agora será instalado o Site Institucional. Deseja prosseguir? (S/N) " RESP_SITE
if [[ "$RESP_SITE" =~ ^[Ss]$ ]]; then
    echo "Baixando e configurando o Site..."
    if [ -d "$PASTA_SITE" ]; then
        git -C "$PASTA_SITE" pull
    else
        git clone "$REPO_SITE" "$PASTA_SITE"
    fi
    
    cd "$PASTA_SITE"
    cat > Dockerfile << 'EOF'
FROM node:20-alpine
WORKDIR /app
COPY . .
RUN npm install
EXPOSE 3333
CMD ["npm", "start"]
EOF
    echo "node_modules" > .dockerignore
    docker rm -f sorvesys-site 2>/dev/null
    docker build -t site-instituicional:1.0 . > /dev/null 2>&1
    docker run -d --name sorvesys-site --restart unless-stopped -p 80:3333 site-instituicional:1.0
    echo "Site acessível em: http://$IP_ELASTICO"
fi

echo ""
echo "🎉 Instalação do Servidor Central finalizada!"

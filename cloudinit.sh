#!/bin/bash
# cloudinit.sh — Oracle 23ai Free + GenAI stack bootstrap (v3 — fully automated)
#
# CHANGES from v2:
#  FIX-1: Podman cgroup manager set to cgroupfs (OL8 early-boot compat)
#  FIX-2: podman run uses --replace (prevents "name in use" on retries)
#  FIX-3: LOCAL_LISTENER set explicitly so FREEPDB1 registers with listener
#  FIX-4: vector user created via ALTER SESSION SET CONTAINER (no listener dependency)
#  FIX-5: JupyterLab installed separately + verified (prevents pip dep clobbering)
#  FIX-6: start_jupyter.sh uses ServerApp (JupyterLab 4 compat)
#  FIX-7: genai-db.sh handles "Database configuration failed" (DB is actually fine)
#  FIX-8: init-genailabs.sh uses set +u before sourcing bashrc (BASHRCSOURCED fix)
#  FIX-9: JupyterLab auto-starts via systemd service (survives reboots)
#  FIX-10: init-genailabs.sh DB operations use ALTER SESSION (no listener wait)

set -Eeuo pipefail

LOGFILE="/var/log/genai_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "===== GenAI OneClick: start $(date -u) ====="

# --------------------------------------------------------------------
# Grow filesystem (best-effort)
# --------------------------------------------------------------------
if command -v /usr/libexec/oci-growfs >/dev/null 2>&1; then
  /usr/libexec/oci-growfs -y || true
fi

# --------------------------------------------------------------------
# PRE: install Podman so the DB unit can run right away
# --------------------------------------------------------------------
echo "[PRE] installing Podman and basics"

dnf config-manager --set-disabled ol8_ksplice || true
dnf config-manager --set-disabled ol8_MySQL84 || true
dnf config-manager --set-disabled ol8_MySQL84_community || true
dnf clean all || true
dnf makecache --refresh || true
dnf config-manager --set-enabled ol8_addons || true
dnf config-manager --set-enabled ol8_appstream || true
dnf config-manager --set-enabled ol8_baseos_latest || true

install_with_retry() {
    local max_attempts=3
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        echo "[PRE] Installation attempt $attempt of $max_attempts"
        if dnf -y install podman curl grep coreutils shadow-utils git unzip; then
            echo "[PRE] Installation successful"
            return 0
        else
            echo "[PRE] Installation attempt $attempt failed, retrying..."
            sleep 10
            attempt=$((attempt + 1))
        fi
    done
    echo "[PRE] All installation attempts failed"
    return 1
}

if ! install_with_retry; then
    echo "[PRE] Critical: Could not install required packages"
    exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
    echo "[PRE] Critical: podman not found after installation"
    exit 1
fi

/usr/bin/podman --version || { echo "[PRE] podman installation verification failed"; exit 1; }
echo "[PRE] Successfully installed Podman and dependencies"

# --------------------------------------------------------------------
# FIX-1: Configure Podman cgroup manager for OL8 compatibility
# Podman 4.9+ defaults to systemd cgroup manager which fails during
# early boot when systemd scopes can't be created yet.
# --------------------------------------------------------------------
mkdir -p /etc/containers
cat > /etc/containers/containers.conf <<CGCONF
[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
CGCONF
echo "[PRE] Configured Podman cgroup manager (cgroupfs)"

# ====================================================================
# genai-setup.sh (MAIN provisioning)
# ====================================================================
cat >/usr/local/bin/genai-setup.sh <<'SCRIPT'
#!/bin/bash
set -uxo pipefail

echo "===== GenAI OneClick systemd: start $(date -u) ====="

MARKER="/var/lib/genai.oneclick.done"
if [[ -f "$MARKER" ]]; then
  echo "[INFO] already provisioned; exiting."
  exit 0
fi

retry() { local max=${1:-5}; shift; local n=1; until "$@"; do rc=$?; [[ $n -ge $max ]] && echo "[RETRY] failed after $n: $*" && return $rc; echo "[RETRY] $n -> retrying in $((n*5))s: $*"; sleep $((n*5)); n=$((n+1)); done; return 0; }

echo "[STEP] enable ol8_addons, pre-populate metadata, and install base pkgs"
retry 5 dnf -y install dnf-plugins-core curl
retry 5 dnf config-manager --set-enabled ol8_addons || true
retry 5 dnf -y makecache --refresh
retry 5 dnf -y install \
  git unzip jq tar make gcc gcc-c++ bzip2 bzip2-devel zlib-devel openssl-devel readline-devel libffi-devel \
  wget curl which xz python3 python3-pip podman firewalld patch ncurses-devel

echo "[STEP] enable firewalld"
systemctl enable --now firewalld || true

echo "[STEP] create /opt/genai and /home/opc/code"
mkdir -p /opt/genai /home/opc/code /home/opc/bin
chown -R opc:opc /opt/genai /home/opc/code /home/opc/bin

echo "[STEP] create /home/opc/code and fetch css-navigator/gen-ai"
CODE_DIR="/home/opc/code"
mkdir -p "$CODE_DIR"

if ! command -v git   >/dev/null 2>&1; then retry 5 dnf -y install git;   fi
if ! command -v curl  >/dev/null 2>&1; then retry 5 dnf -y install curl;  fi
if ! command -v unzip >/dev/null 2>&1; then retry 5 dnf -y install unzip; fi

TMP_DIR="$(mktemp -d)"
REPO_ZIP="/tmp/cssnav.zip"

retry 5 git clone --depth 1 --filter=blob:none --sparse https://github.com/ou-developers/css-navigator.git "$TMP_DIR" || true
retry 5 git -C "$TMP_DIR" sparse-checkout init --cone || true
retry 5 git -C "$TMP_DIR" sparse-checkout set gen-ai || true

if [ -d "$TMP_DIR/gen-ai" ] && [ -n "$(ls -A "$TMP_DIR/gen-ai" 2>/dev/null)" ]; then
  echo "[STEP] copying from sparse-checkout"
  chmod -R a+rx "$TMP_DIR/gen-ai" || true
  cp -a "$TMP_DIR/gen-ai"/. "$CODE_DIR"/
else
  echo "[STEP] sparse-checkout empty; falling back to zip"
  retry 5 curl -L -o "$REPO_ZIP" https://codeload.github.com/ou-developers/css-navigator/zip/refs/heads/main
  TMP_ZIP_DIR="$(mktemp -d)"
  unzip -q -o "$REPO_ZIP" -d "$TMP_ZIP_DIR"
  if [ -d "$TMP_ZIP_DIR/css-navigator-main/gen-ai" ]; then
    chmod -R a+rx "$TMP_ZIP_DIR/css-navigator-main/gen-ai" || true
    cp -a "$TMP_ZIP_DIR/css-navigator-main/gen-ai"/. "$CODE_DIR"/
  else
    echo "[WARN] gen-ai folder not found in zip"
  fi
  rm -rf "$TMP_ZIP_DIR" "$REPO_ZIP"
fi

rm -rf "$TMP_DIR"
chown -R opc:opc "$CODE_DIR" || true
chmod -R a+rX "$CODE_DIR" || true
ln -sfn "$CODE_DIR" /opt/code || true

# ----------------------------------------------------------------
# FIX-8: init-genailabs.sh — use set +u before sourcing bashrc
# and use ALTER SESSION instead of listener-based connections
# ----------------------------------------------------------------
echo "[STEP] embed user's init-genailabs.sh"
cat >/opt/genai/init-genailabs.sh <<'USERSCRIPT'
#!/bin/bash
set -Eeo pipefail

LOGFILE=/var/log/cloud-init-output.log
exec > >(tee -a $LOGFILE) 2>&1

MARKER_FILE="/home/opc/.init_done"
if [ -f "$MARKER_FILE" ]; then
  echo "Init script has already been run. Exiting."
  exit 0
fi

echo "===== Starting Cloud-Init User Script ====="

sudo /usr/libexec/oci-growfs -y || true

sudo dnf config-manager --set-enabled ol8_addons || true
sudo dnf install -y podman git libffi-devel bzip2-devel ncurses-devel readline-devel wget make gcc zlib-devel openssl-devel patch || true

# Install latest SQLite from source
cd /tmp
wget -q https://www.sqlite.org/2023/sqlite-autoconf-3430000.tar.gz || true
if [ -f sqlite-autoconf-3430000.tar.gz ]; then
  tar -xzf sqlite-autoconf-3430000.tar.gz
  cd sqlite-autoconf-3430000
  ./configure --prefix=/usr/local
  make -s
  sudo make install
  /usr/local/bin/sqlite3 --version || true
fi

# PATH/LD for SQLite — use grep to avoid duplicate entries
grep -q '/usr/local/bin' /home/opc/.bashrc 2>/dev/null || {
  echo 'export PATH="/usr/local/bin:$PATH"' >> /home/opc/.bashrc
  echo 'export LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH:-}"' >> /home/opc/.bashrc
  echo 'export CFLAGS="-I/usr/local/include"' >> /home/opc/.bashrc
  echo 'export LDFLAGS="-L/usr/local/lib"' >> /home/opc/.bashrc
}

# FIX-8: set +u before sourcing bashrc (BASHRCSOURCED unbound variable)
set +u
source /home/opc/.bashrc || true
set -u

sudo mkdir -p /home/opc/oradata
sudo chown -R 54321:54321 /home/opc/oradata
sudo chmod -R 755 /home/opc/oradata

# FIX-10: Wait for DB container to be healthy (not just exist)
echo "Waiting for 23ai container to be healthy..."
for i in {1..180}; do
  STATUS=$(sudo /usr/bin/podman inspect --format '{{.State.Health.Status}}' 23ai 2>/dev/null || echo "missing")
  if [ "$STATUS" = "healthy" ]; then
    echo "23ai container is healthy."
    break
  fi
  [ $((i % 12)) -eq 0 ] && echo "  still waiting ($i)... status=$STATUS"
  sleep 5
done

# FIX-10: Use ALTER SESSION instead of connecting via listener
echo "Configuring Oracle database in PDB (FREEPDB1)..."
sudo /usr/bin/podman exec -i 23ai bash -lc '. /home/oracle/.bashrc; sqlplus -S -L / as sysdba <<EOSQL
WHENEVER SQLERROR CONTINUE
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE BIGFILE TABLESPACE tbs2 DATAFILE '\''bigtbs_f2.dbf'\'' SIZE 1G AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT AUTO;
CREATE UNDO TABLESPACE undots2 DATAFILE '\''undotbs_2a.dbf'\'' SIZE 1G AUTOEXTEND ON RETENTION GUARANTEE;
CREATE TEMPORARY TABLESPACE temp_demo TEMPFILE '\''temp02.dbf'\'' SIZE 1G REUSE AUTOEXTEND ON NEXT 32M MAXSIZE UNLIMITED EXTENT MANAGEMENT LOCAL UNIFORM SIZE 1M;
CREATE USER vector IDENTIFIED BY "vector" DEFAULT TABLESPACE tbs2 QUOTA UNLIMITED ON tbs2;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW TO vector;
EXIT
EOSQL' || echo "[WARN] PDB config returned non-zero (objects may already exist)"

echo "Setting vector_memory_size (non-fatal)..."
sudo /usr/bin/podman exec -i 23ai bash -lc '. /home/oracle/.bashrc; sqlplus -S -L / as sysdba <<EOSQL
WHENEVER SQLERROR CONTINUE
CREATE PFILE FROM SPFILE;
ALTER SYSTEM SET vector_memory_size = 512M SCOPE=SPFILE;
EXIT
EOSQL' || echo "[WARN] vector_memory_size setting returned non-zero"

# NOTE: removed SHUTDOWN/STARTUP — too dangerous during cloud-init.
# vector_memory_size takes effect on next container restart.

# pyenv + Python 3.11.9
sudo -u opc -i bash <<'EOF_OPC'
set -ex
# FIX-8: unset problematic variables before sourcing
set +u
export HOME=/home/opc
export PYENV_ROOT="$HOME/.pyenv"

if [ ! -d "$PYENV_ROOT" ]; then
  curl -sS https://pyenv.run | bash
fi

grep -q 'PYENV_ROOT' $HOME/.bashrc 2>/dev/null || {
  cat << EOF >> $HOME/.bashrc
export PYENV_ROOT="\$HOME/.pyenv"
[[ -d "\$PYENV_ROOT/bin" ]] && export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init --path)"
eval "\$(pyenv init -)"
eval "\$(pyenv virtualenv-init -)"
EOF
}

grep -q 'bashrc' $HOME/.bash_profile 2>/dev/null || {
  cat << EOF >> $HOME/.bash_profile
if [ -f ~/.bashrc ]; then
   source ~/.bashrc
fi
EOF
}

source $HOME/.bashrc || true
export PATH="$PYENV_ROOT/bin:$PATH"
set -u

CFLAGS="-I/usr/local/include" LDFLAGS="-L/usr/local/lib" LD_LIBRARY_PATH="/usr/local/lib" pyenv install -s 3.11.9
pyenv rehash
mkdir -p $HOME/labs
cd $HOME/labs
pyenv local 3.11.9
pyenv rehash
python --version
export PYTHONPATH=$HOME/.pyenv/versions/3.11.9/lib/python3.11/site-packages:${PYTHONPATH:-}

$HOME/.pyenv/versions/3.11.9/bin/pip install --no-cache-dir oci==2.129.1 oracledb transformers==4.46.3 sentence-transformers==3.3.1 langchain==0.2.6 langchain-community==0.2.6 langchain-chroma==0.1.2 langchain-core==0.2.11 langchain-text-splitters==0.2.2 langsmith==0.1.83 pypdf==4.2.0 streamlit==1.36.0 python-multipart==0.0.9 chroma-hnswlib==0.7.3 chromadb==0.5.3 torch==2.5.0
python - <<PY
from sentence_transformers import SentenceTransformer
SentenceTransformer('all-MiniLM-L12-v2')
PY

pip install --user jupyterlab
curl -sSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o install.sh
chmod +x install.sh
./install.sh --accept-all-defaults
grep -q '.local/bin' $HOME/.bashrc 2>/dev/null || echo 'export PATH=$PATH:$HOME/.local/bin' >> $HOME/.bashrc

set +u
source $HOME/.bashrc || true
set -u

REPO_URL="https://github.com/ou-developers/ou-generativeai-pro.git"
FINAL_DIR="$HOME/labs"
cd $HOME/labs
git init
git remote add origin $REPO_URL 2>/dev/null || true
git config core.sparseCheckout true
echo "labs/*" >> .git/info/sparse-checkout
git pull origin main || true
mv labs/* . 2>/dev/null || true
rm -rf .git labs 2>/dev/null || true
echo "Files successfully downloaded to $FINAL_DIR"
EOF_OPC

touch "$MARKER_FILE"
echo "===== Cloud-Init User Script Completed Successfully ====="
exit 0
USERSCRIPT
chmod +x /opt/genai/init-genailabs.sh
cp -f /opt/genai/init-genailabs.sh /home/opc/init-genailabs.sh || true
chown opc:opc /home/opc/init-genailabs.sh || true

echo "[STEP] install Python 3.9 for OL8 and create venv"
retry 5 dnf -y module enable python39 || true
retry 5 dnf -y install python39 python39-pip
sudo -u opc bash -lc 'python3.9 -m venv $HOME/.venvs/genai || true; grep -q "venvs/genai" $HOME/.bashrc 2>/dev/null || echo "source $HOME/.venvs/genai/bin/activate" >> $HOME/.bashrc; source $HOME/.venvs/genai/bin/activate; python -m pip install --upgrade pip wheel setuptools'

# FIX-5: Install heavy packages first, then JupyterLab separately
echo "[STEP] install Python libraries (heavy packages)"
sudo -u opc bash -lc 'source $HOME/.venvs/genai/bin/activate; pip install --no-cache-dir torch==2.5.0 transformers==4.46.3 sentence-transformers==3.3.1 chromadb==0.5.3 chroma-hnswlib==0.7.3 oracle-ads oci oracledb streamlit==1.36.0 langchain==0.2.6 langchain-community==0.2.6 langchain-core==0.2.11 langchain-text-splitters==0.2.2 langsmith==0.1.83 pypdf==4.2.0 python-multipart==0.0.9'

echo "[STEP] install JupyterLab (separate to prevent dep conflicts)"
sudo -u opc bash -lc 'source $HOME/.venvs/genai/bin/activate; pip install --no-cache-dir jupyterlab==4.2.5'

echo "[STEP] verify JupyterLab installation"
sudo -u opc bash -lc 'source $HOME/.venvs/genai/bin/activate; jupyter lab --version || { echo "[ERROR] JupyterLab not found, force reinstalling"; pip install --no-cache-dir --force-reinstall jupyterlab==4.2.5; jupyter lab --version; }'

echo "[STEP] register genai venv as default Jupyter kernel"
sudo -u opc bash -lc 'source $HOME/.venvs/genai/bin/activate; python -m ipykernel install --user --name python3 --display-name "Python 3 (ipykernel)"'

echo "[STEP] install OCI CLI to ~/bin/oci and make PATH global"
sudo -u opc bash -lc 'curl -sSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o /tmp/oci-install.sh; bash /tmp/oci-install.sh --accept-all-defaults --exec-dir $HOME/bin --install-dir $HOME/lib/oci-cli --update-path false; grep -q "export PATH=\$HOME/bin" $HOME/.bashrc 2>/dev/null || echo "export PATH=\$HOME/bin:\$PATH" >> $HOME/.bashrc'
cat >/etc/profile.d/genai-path.sh <<'PROF'
export PATH=/home/opc/bin:$PATH
PROF

echo "[STEP] seed /opt/genai content"
cat >/opt/genai/LoadProperties.py <<'PY'
class LoadProperties:
    def __init__(self):
        import json
        with open('config.txt') as f:
            js = json.load(f)
        self.model_name = js.get("model_name")
        self.embedding_model_name = js.get("embedding_model_name")
        self.endpoint = js.get("endpoint")
        self.compartment_ocid = js.get("compartment_ocid")
    def getModelName(self): return self.model_name
    def getEmbeddingModelName(self): return self.embedding_model_name
    def getEndpoint(self): return self.endpoint
    def getCompartment(self): return self.compartment_ocid
PY
cat >/opt/genai/config.txt <<'CFG'
{"model_name":"cohere.command-r-16k","embedding_model_name":"cohere.embed-english-v3.0","endpoint":"https://inference.generativeai.eu-frankfurt-1.oci.oraclecloud.com","compartment_ocid":"ocid1.compartment.oc1....replace_me..."}
CFG
mkdir -p /opt/genai/txt-docs /opt/genai/pdf-docs
echo "faq | What are Always Free services?=====Always Free services are part of Oracle Cloud Free Tier." >/opt/genai/txt-docs/faq.txt
chown -R opc:opc /opt/genai

# FIX-6: Use ServerApp config for JupyterLab 4
echo "[STEP] write start_jupyter.sh"
cat >/home/opc/start_jupyter.sh <<'SH'
#!/bin/bash
set -eux
source $HOME/.venvs/genai/bin/activate
jupyter lab --ServerApp.token='' --ServerApp.password='' --ip=0.0.0.0 --port=8888 --no-browser
SH
chown opc:opc /home/opc/start_jupyter.sh
chmod +x /home/opc/start_jupyter.sh

echo "[STEP] open firewall ports"
for p in 8888 8501 1521; do firewall-cmd --zone=public --add-port=${p}/tcp --permanent || true; done
firewall-cmd --reload || true

echo "[STEP] run user's init-genailabs.sh (non-fatal)"
set +e
bash /opt/genai/init-genailabs.sh
USR_RC=$?
set -e
echo "[STEP] user init script exit code: $USR_RC"

touch "$MARKER"
echo "===== GenAI OneClick systemd: COMPLETE $(date -u) ====="
SCRIPT
chmod +x /usr/local/bin/genai-setup.sh

# ====================================================================
# genai-db.sh — robust bootstrap for 23ai
# FIX-2: --replace flag, FIX-3: LOCAL_LISTENER, FIX-4: ALTER SESSION
# FIX-7: Handle "Database configuration failed" (DB is actually fine)
# ====================================================================
cat >/usr/local/bin/genai-db.sh <<'DBSCR'
#!/bin/bash
set -Euo pipefail

PODMAN="/usr/bin/podman"
log(){ echo "[DB] $*"; }
retry() { local t=${1:-5}; shift; local n=1; until "$@"; do local rc=$?;
  if (( n>=t )); then return "$rc"; fi
  log "retry $n/$t (rc=$rc): $*"; sleep $((n*5)); ((n++));
done; }

ORACLE_PWD="database123"
ORACLE_PDB="FREEPDB1"
ORADATA_DIR="/home/opc/oradata"
IMAGE="container-registry.oracle.com/database/free:latest"
NAME="23ai"

log "start $(date -u)"
mkdir -p "$ORADATA_DIR" && chown -R 54321:54321 "$ORADATA_DIR" || true

retry 5 "$PODMAN" pull "$IMAGE" || true
"$PODMAN" rm -f "$NAME" 2>/dev/null || true

# FIX-2: --replace prevents "name already in use" on retries
retry 5 "$PODMAN" run -d --replace --name "$NAME" --network=host \
  -e ORACLE_PWD="$ORACLE_PWD" \
  -e ORACLE_PDB="$ORACLE_PDB" \
  -e ORACLE_MEMORY='2048' \
  -v "$ORADATA_DIR":/opt/oracle/oradata:z \
  "$IMAGE"

# FIX-7: Wait for DB ready OR container healthy — whichever comes first
# "Database configuration failed" is a known false alarm from DBCA custom scripts.
# The actual DB is fine. So we check BOTH the log message AND container health.
log "waiting for database to be ready..."
for i in {1..180}; do
  # Check if container exited
  RUNNING=$("$PODMAN" inspect --format '{{.State.Running}}' "$NAME" 2>/dev/null || echo "false")
  if [ "$RUNNING" = "false" ]; then
    log "container exited — checking if DB data exists and restarting..."
    if [ -d "$ORADATA_DIR/FREE" ]; then
      log "DB data directory exists — restarting container (DB was created successfully)"
      "$PODMAN" start "$NAME"
      sleep 10
    else
      log "ERROR: container exited and no DB data found"
      "$PODMAN" logs "$NAME" 2>&1 | tail -20
      exit 1
    fi
  fi

  # Check health status (set by Oracle's container healthcheck)
  HEALTH=$("$PODMAN" inspect --format '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo "unknown")
  if [ "$HEALTH" = "healthy" ]; then
    log "container is healthy"
    break
  fi

  # Also check the traditional log message
  if "$PODMAN" logs "$NAME" 2>&1 | grep -q 'DATABASE IS READY TO USE!'; then
    log "DATABASE IS READY TO USE! detected in logs"
    break
  fi

  [ $((i % 12)) -eq 0 ] && log "still waiting ($i/180)... health=$HEALTH running=$RUNNING"
  sleep 5
done

# FIX-3: Set LOCAL_LISTENER and register so FREEPDB1 is discoverable
log "opening PDB and configuring listener..."
"$PODMAN" exec -i "$NAME" bash -lc '
  . /home/oracle/.bashrc
  sqlplus -S -L / as sysdba <<SQL
  WHENEVER SQLERROR CONTINUE
  ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;
  ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;
  ALTER SYSTEM SET LOCAL_LISTENER="(ADDRESS=(PROTOCOL=TCP)(HOST=0.0.0.0)(PORT=1521))" SCOPE=BOTH;
  ALTER SYSTEM REGISTER;
  EXIT
SQL
' || log "WARN: open/save state returned non-zero (may already be open)"

log "waiting for listener to publish FREEPDB1..."
for i in {1..60}; do
  "$PODMAN" exec -i "$NAME" bash -lc '. /home/oracle/.bashrc; lsnrctl status' \
    | grep -qi 'Service "FREEPDB1"' && { log "FREEPDB1 registered"; break; }
  sleep 3
done

# FIX-4: Create vector user via ALTER SESSION (no listener dependency)
log "creating PDB user 'vector' (idempotent)"
"$PODMAN" exec -i "$NAME" bash -lc '
  . /home/oracle/.bashrc
  sqlplus -S -L / as sysdba <<SQL
  ALTER SESSION SET CONTAINER = FREEPDB1;
  SET DEFINE OFF
  WHENEVER SQLERROR CONTINUE
  CREATE USER vector IDENTIFIED BY "vector";
  GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW TO vector;
  ALTER USER vector QUOTA UNLIMITED ON USERS;
  EXIT
SQL
' || log "WARN: vector user create step returned non-zero (may already exist)"

# Verify DB connectivity
log "verifying DB connectivity..."
"$PODMAN" exec -i "$NAME" bash -lc '
  . /home/oracle/.bashrc
  sqlplus -S -L vector/vector@127.0.0.1:1521/FREEPDB1 <<SQL
  SELECT 1 AS CONNECTION_OK FROM DUAL;
  EXIT
SQL
' && log "DB connectivity verified" || log "WARN: DB connectivity check failed (listener may need more time)"

log "done $(date -u)"
DBSCR
chmod +x /usr/local/bin/genai-db.sh

# ====================================================================
# systemd units
# ====================================================================

# DB service — runs first
cat >/etc/systemd/system/genai-23ai.service <<'UNIT_DB'
[Unit]
Description=GenAI oneclick - Oracle 23ai container
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=0
KillMode=process
ExecStart=/bin/bash -lc '/usr/local/bin/genai-db.sh >> /var/log/genai_setup.log 2>&1'
Restart=no

[Install]
WantedBy=multi-user.target
UNIT_DB

# Setup service — runs after DB
cat >/etc/systemd/system/genai-setup.service <<'UNIT_SETUP'
[Unit]
Description=GenAI oneclick post-boot setup
Wants=network-online.target genai-23ai.service
After=network-online.target genai-23ai.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -lc '/usr/local/bin/genai-setup.sh >> /var/log/genai_setup.log 2>&1'
Restart=no

[Install]
WantedBy=multi-user.target
UNIT_SETUP

# FIX-9: JupyterLab systemd service — auto-starts after setup, survives reboots
cat >/etc/systemd/system/genai-jupyter.service <<'UNIT_JUPYTER'
[Unit]
Description=GenAI JupyterLab
After=genai-setup.service network-online.target
Wants=network-online.target

[Service]
Type=simple
User=opc
Group=opc
WorkingDirectory=/home/opc
Environment="HOME=/home/opc"
ExecStartPre=/bin/bash -c 'until [ -f /var/lib/genai.oneclick.done ]; do sleep 5; done'
ExecStart=/bin/bash -lc 'source /home/opc/.venvs/genai/bin/activate && exec jupyter lab --ServerApp.token="" --ServerApp.password="" --ip=0.0.0.0 --port=8888 --no-browser'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT_JUPYTER

systemctl daemon-reload
systemctl enable genai-23ai.service
systemctl enable genai-setup.service
systemctl enable genai-jupyter.service
systemctl start genai-23ai.service      # DB/bootstrap first
systemctl start genai-setup.service     # then app/setup
# genai-jupyter.service starts automatically after setup marker exists

echo "===== GenAI OneClick: cloud-init done $(date -u) ====="

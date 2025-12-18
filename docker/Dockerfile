FROM frappe/bench:latest

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg rsync python3-pip \
 && rm -rf /var/lib/apt/lists/*

# Node + yarn garantidos
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && corepack enable \
 && corepack prepare yarn@1.22.22 --activate \
 && node -v \
 && yarn -v \
 && rm -rf /var/lib/apt/lists/*
 
RUN mkdir -p /home/frappe/frappe-bench \
 && chown -R frappe:frappe /home/frappe \
 && chmod -R 0775 /home/frappe/frappe-bench
 
# garante pymysql (se já vier, ok; se não vier, salva tua vida)
RUN python3 -m pip install --no-cache-dir pymysql

USER frappe
WORKDIR /home/frappe

COPY docker/init.sh /workspace/init.sh
CMD ["bash", "/workspace/init.sh"]


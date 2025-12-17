FROM frappe/bench:latest

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && rm -rf /var/lib/apt/lists/*

# Garante Node 18 + yarn (via corepack)
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && corepack enable \
 && corepack prepare yarn@1.22.22 --activate \
 && node -v \
 && yarn -v \
 && rm -rf /var/lib/apt/lists/*

USER frappe
WORKDIR /home/frappe

COPY docker/init.sh /workspace/init.sh
RUN chmod +x /workspace/init.sh

CMD ["bash", "/workspace/init.sh"]

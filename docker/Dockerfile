FROM frappe/bench:latest

USER root

# Garantias mínimas
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# (Opcional) se você quiser garantir node/yarn e não confiar na base:
# RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
#  && apt-get update \
#  && apt-get install -y --no-install-recommends nodejs \
#  && corepack enable \
#  && rm -rf /var/lib/apt/lists/*

USER frappe

WORKDIR /home/frappe

COPY docker/init.sh /workspace/init.sh
RUN chmod +x /workspace/init.sh

CMD ["bash", "/workspace/init.sh"]

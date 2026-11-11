FROM python:3.13-alpine
WORKDIR /app
COPY pyproject.toml ./
COPY factorio_ha_relay ./factorio_ha_relay
RUN pip install --no-cache-dir . && adduser -D -H relay
USER relay
ENV PYTHONUNBUFFERED=1
CMD ["python", "-m", "factorio_ha_relay"]

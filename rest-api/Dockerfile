# Copyright (c) 2025, Scaleway

# Here, we use the official Python image as a base image as we step in the shoes
# of a customer. However, Scaleway internal images _must_ be built using the
# Scaleway internal registry. See the handbook for more information:
# https://handbook.internal.scaleway.com/build/guidelines/containers
FROM python:3.14.0-slim

RUN apt-get update  --quiet --yes && \
  apt-get upgrade --quiet --yes && \
  apt-get install --no-install-recommends --quiet --yes \
  ca-certificates \
  gcc \
  python3-dev \
  libpq-dev

WORKDIR /app

COPY  --chmod=0644 rest-api/requirements.txt /app/requirements.txt

RUN pip install --no-cache-dir --requirement requirements.txt

RUN apt-get remove -y gcc python3-dev && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

COPY --chmod=0644 rest-api/app.py /app/app.py
COPY --chmod=0755 web/ /app/web/

RUN groupadd -r appuser && useradd -r -g appuser appuser
EXPOSE 8080

USER appuser

ENTRYPOINT [ "uvicorn" ]

CMD [ "app:app", "--host", "0.0.0.0", "--port", "8080", "--log-level", "debug" ]

# ADR-0013 Python CI-parity Dockerfile.
# Pin to match your CI workflow's Python version + tool versions.
#
# Build context MUST be the repo root so COPY can reach requirements.txt:
#   docker build -f .devcontainer/Dockerfile -t my-app-ci .
# or in devcontainer.json:
#   "build": { "context": "..", "dockerfile": "Dockerfile" }
FROM python:3.10-slim

ARG GITLEAKS_VERSION=8.18.0

RUN apt-get update && apt-get install -y --no-install-recommends \
      git bash curl jq ca-certificates gnupg sudo \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
      | tar -xz -C /tmp \
    && mv /tmp/gitleaks /usr/local/bin/gitleaks \
    && chmod +x /usr/local/bin/gitleaks

WORKDIR /workspace

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r /tmp/requirements.txt \
    && pip install --no-cache-dir 'ruff>=0.15' 'pytest>=8' 'pytest-cov>=7' \
    && rm /tmp/requirements.txt

CMD ["bash"]

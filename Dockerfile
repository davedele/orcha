# Use Python 3.11 as base
FROM python:3.11-slim-bookworm

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Bun
ENV BUN_INSTALL="/root/.bun"
ENV PATH="$BUN_INSTALL/bin:$PATH"
RUN curl -fsSL https://bun.sh/install | bash

# Install AI-scripts (Refactor.ts)
WORKDIR /opt
RUN git clone https://github.com/VictorTaelin/AI-scripts.git ai-scripts
# Install dependencies for AI-scripts if any (usually just bun install)
WORKDIR /opt/ai-scripts
RUN bun install

# Install Orcha
WORKDIR /app
# Copy the necessary files from the root context
COPY orchestrator.py scan_and_refactor.py propagate_rename.py setup.py requirements.txt ./
RUN pip install .

# Set working directory for the user
WORKDIR /workspace

# Set default command to help
CMD ["orcha", "--help"]

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ARG USERNAME=devuser
ARG USER_UID=1000
ARG USER_GID=$USER_UID

# 1. Base dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git build-essential ca-certificates gnupg lsb-release \
    software-properties-common python3 python3-pip jq sudo \
    openssh-server net-tools \
    && rm -rf /var/lib/apt/lists/*

# 2. Node.js LTS (required for Claude Code & OpenSpec)
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# 3. Podman & networking stack
RUN apt-get update && apt-get install -y --no-install-recommends \
    podman podman-compose cni-plugins conmon crun \
    && rm -rf /var/lib/apt/lists/*

# 4. Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# 5. OpenSpec
RUN npm install -g @fission-ai/openspec@latest

# 6. Create non-root user
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && mkdir -p /home/$USERNAME/.claude \
    && chown -R $USERNAME:$USERNAME /home/$USERNAME

# 7. Configure Claude Code
# Note: This enables file system access, tool execution, network access, and dangerous commands.
# Use responsibly. You can also pass --dangerously-skip-permissions at runtime.
RUN cat > /home/$USERNAME/.claude/config.json << 'EOF'
{
  "permissions": {
    "allowFileWrite": true,
    "allowToolExecution": true,
    "allowNetworkAccess": true,
    "allowDangerousCommands": true
  }
}
EOF
RUN chown -R $USERNAME:$USERNAME /home/$USERNAME/.claude

USER $USERNAME
WORKDIR /workspace

# 8. Superpowers
RUN claude plugin install superpowers@claude-plugins-official
RUN claude plugin enable superpowers

# Podman socket will be mounted at runtime
ENV PODMAN_SOCKET=unix:///run/user/1000/podman/podman.sock

# Keep container alive
CMD ["tail", "-f", "/dev/null"]


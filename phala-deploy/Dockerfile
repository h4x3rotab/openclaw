FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Layer 1: System packages + openssh-server (Docker binaries mounted from host)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git bash tmux openssh-server unzip \
      lsb-release sudo && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# SSH config: permit root login with keys
RUN mkdir -p /var/run/sshd && \
    sed -i 's/#PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

# Layer 2: Node.js 22 via nodesource
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    corepack enable && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Layer 3: Bun
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# Layer 4: Linuxbrew (Homebrew)
RUN useradd -m -s /bin/bash linuxbrew && \
    echo 'linuxbrew ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
RUN NONINTERACTIVE=1 su - linuxbrew -c \
    'bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
ENV HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
ENV PATH="${HOMEBREW_PREFIX}/bin:${HOMEBREW_PREFIX}/sbin:${PATH}"

# Layer 5: Install build-essential, npm install openclaw, then purge build tools + cache
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential && \
    npm install -g @h4x3rotab/openclaw@latest && \
    apt-get purge -y --auto-remove build-essential && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /root/.npm /tmp/* /usr/include

# Layer 6: Shell environment
RUN echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> /root/.bashrc && \
    echo 'export PATH="/root/.bun/bin:$PATH"' >> /root/.bashrc

COPY phala-deploy/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV NODE_ENV=production

ENTRYPOINT ["/entrypoint.sh"]

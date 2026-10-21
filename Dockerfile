FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

# Buildroot mandatory dependencies + optional/recommended ones
RUN apt-get update && apt-get install -y --no-install-recommends \
    # --- Build tools ---
    debianutils \
    sed \
    make \
    binutils \
    build-essential \
    diffutils \
    gcc \
    g++ \
    bash \
    patch \
    gzip \
    bzip2 \
    perl \
    tar \
    cpio \
    unzip \
    rsync \
    file \
    bc \
    findutils \
    gawk \
    # --- Source fetching tools ---
    wget \
    ca-certificates \
    git \
    mercurial \
    subversion \
    rsync \
    # --- Interface / misc ---
    libncurses-dev \
    pkg-config \
    python3 \
    locales \
    xz-utils \
    # --- Static checks (make check) ---
    shellcheck \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 'which' and 'awk' must resolve; /usr/bin/file is required by Buildroot
RUN which which && which awk && test -x /usr/bin/file

RUN sed -i "s/^# en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Buildroot refuses / is unsupported as root -> build as a normal user
ARG USER=br
ARG UID=1000
ARG GID=1000
RUN groupadd -g $GID $USER && useradd -m -u $UID -g $GID -s /bin/bash $USER

RUN mkdir -p /workspace && chown $UID:$GID /workspace

USER $USER
WORKDIR /workspace
CMD ["/bin/bash"]

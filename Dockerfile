FROM ubuntu:24.04

# tool arguments
ARG TOOL_NAME=""
ARG REPO_LINK=""
ARG EXECUTABLE=""
ARG VERSION=""

# non-interactive mode
ENV DEBIAN_FRONTEND=noninteractive

# install git and apt-get dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends git \
    python3-pip && \
    #dependencies
    rm -rf /var/lib/apt/lists/*

# install pip dependencies
RUN pip3 install --no-cache-dir #dependencies

# Create working directory
WORKDIR /opt/${TOOL_NAME}

# clone the repo and make script executable
RUN git clone --depth 1 --branch "${VERSION}" ${REPO_LINK} . && \
    chmod +x /opt/${TOOL_NAME}/${EXECUTABLE}

# add exectable to path
ENV PATH="/opt/${TOOL_NAME}:${PATH}"

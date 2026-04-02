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
    apt-get install -y git \
    python3-pip && \
    #dependencies
    rm -rf /var/lib/apt/lists/*

# install pip dependencies
RUN pip3 install #dependencies

# clone the repo and make script executable
RUN git clone ${REPO_LINK} /opt/${TOOL_NAME} && \
    chmod +x /opt/${TOOL_NAME}/${EXECUTABLE}

# add exectable to path
ENV PATH="/opt/${TOOL_NAME}:${PATH}"

# set the workdir
WORKDIR "/opt/${TOOL_NAME}"

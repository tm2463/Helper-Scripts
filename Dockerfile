ARG REPO_LINK=""
ARG TOOL_NAME=""

# Minimal Dockerfile
FROM ubuntu:22.04

# Non-interactive frontend
ENV DEBIAN_FRONTEND=noninteractive

# Install git
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# Clone the repository
RUN git clone ${REPO_LINK} /opt/${TOOL_NAME}

# Make the main script executable
RUN chmod +x /opt/dreamcatcher/dreamcatcher

# Add Dreamcatcher to PATH
ENV PATH="/opt/dreamcatcher:${PATH}"

# Set the working directory
WORKDIR /opt/dreamcatcher

# Default command
CMD ["${TOOL_NAME}"]

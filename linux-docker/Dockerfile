FROM debian:buster

# Install packages that we use in our buildkite plugins a lot
RUN apt update && \
    DEBIAN_FRONTEND=noninteractive apt install -y curl wget apt-transport-https openssl gnupg2 python3 git vim jq

# Install buildkite-agent itself
RUN echo 'deb https://apt.buildkite.com/buildkite-agent stable main' >> /etc/apt/sources.list && \
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 32A37959C2FA5C3C99EFBC32A79206696452D198 && \
    apt update && \
    DEBIAN_FRONTEND=noninteractive apt install -y buildkite-agent

COPY secrets /secrets
COPY hooks /hooks

ENTRYPOINT ["buildkite-agent"]
CMD ["start"]

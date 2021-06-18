#!/usr/bin/env julia

docker_compose_path = Sys.which("docker-compose")
if docker_compose_path === nothing
    error("You must install docker-compose")
end

# Read in the agent token, since we need to feed that to the agent
repo_root = dirname(@__DIR__)
buildkite_agent_token = String(chomp(String(read(joinpath(repo_root, "secrets", "buildkite-agent-token")))))

systemd_dir = expanduser("~/.config/systemd/user")
mkpath(systemd_dir)
open(joinpath(systemd_dir, "buildkite-docker@.service"), write=true) do io
    write(io, """
    [Unit]
    Description=Dockerized Buildkite agent %i

    # Because we're running as a user service, we can't directly depend on `docker.service`
    # Too bad, so sad.
    #After=docker.service
    #Requires=docker.service
    #PartOf=docker.service

    StartLimitIntervalSec=60
    StartLimitBurst=5

    [Service]
    Type=simple
    WorkingDirectory=$(@__DIR__)
    TimeoutStartSec=1min
    ExecStartPre=$(docker_compose_path) build --quiet
    ExecStart=$(docker_compose_path) --project-name "%i" up --force-recreate --exit-code-from buildkite
    Environment=AGENT_NAME="%i" BUILDKITE_AGENT_TOKEN="$(buildkite_agent_token)"

    Restart=always
    RestartSec=1s

    [Install]
    WantedBy=multi-user.target
    """)
end

# Inform systemctl that some files on disk may have changed
run(`systemctl --user daemon-reload`)

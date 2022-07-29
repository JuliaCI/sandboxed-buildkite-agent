#!/usr/bin/env julia
#
# Use this script to automatically update all the rootfs images to their latest release.
using Pkg, Pkg.Artifacts, HTTP, JSON3, SHA, Tar, p7zip_jll

latest_release = JSON3.read(HTTP.get("https://api.github.com/repos/JuliaCI/rootfs-images/releases/latest").body).name

artifacts_toml = joinpath(@__DIR__, "..", "Artifacts.toml")
artifacts_dict = Artifacts.load_artifacts_toml(artifacts_toml)

function bind_tarball!(artifacts_toml, name, platform, url)
    mktempdir() do dir
        tarball_path = joinpath(dir, name)
        HTTP.download(url, tarball_path; update_period=Inf)
        tarball_hash = open(io -> bytes2hex(sha256(io)), tarball_path)

        artifact_hash = Pkg.Artifacts.create_artifact() do dir
            Pkg.PlatformEngines.unpack(tarball_path, dir)
        end
        @info("Binding artifact", name, platform, artifact_hash)
        Artifacts.bind_artifact!(
            artifacts_toml,
            name,
            artifact_hash;
            platform,
            download_info = [(url, tarball_hash)],
            force=true,
        )
    end
end

for (name, bindings) in artifacts_dict
    for binding in bindings
        dl_info = get(binding, "download", Dict[])
        if !isempty(dl_info)
            platform = Artifacts.unpack_platform(binding, name, artifacts_toml)
            url = dl_info[1]["url"]
            m = match(r"https://github.com/JuliaCI/rootfs-images/releases/download/v\d+.\d+/(?<tarball>[^ ]+)", url)
            if m !== nothing
                new_url = string("https://github.com/JuliaCI/rootfs-images/releases/download/", latest_release, "/", m[:tarball])
                if new_url != url || true
                    @info("Updating $(name) $(platform)")
                    bind_tarball!(artifacts_toml,  name, platform, new_url)
                end
            end
        end
    end
end

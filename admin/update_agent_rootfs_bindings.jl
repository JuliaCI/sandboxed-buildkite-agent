#!/usr/bin/env julia
#
# Use this script to automatically update all the rootfs images to their latest release.
using Pkg, Pkg.Artifacts, HTTP, JSON3, SHA, Tar, p7zip_jll

function get_latest_release(repo)
    json_data = JSON3.read(HTTP.get("https://api.github.com/repos/$(repo)/releases/latest").body)
    latest_release = get(json_data, :tag_name, "")
    if isempty(latest_release)
        error("Could not determine latest release of $(repo)!")
    end
    return latest_release
end

latest_releases = Dict(repo => get_latest_release(repo) for repo in ("JuliaCI/rootfs-images", "buildkite/agent"))
@info("Updating to releases", latest_releases)
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

            for (repo, latest_release) in latest_releases
                m = match(Regex("https://github.com/$(repo)/releases/download/v(?<version>[\\d\\.]+)/(?<tarball>[^ ]+)"), url)
                if m !== nothing
                    new_url = string("https://github.com/", repo, "/releases/download/", latest_release, "/", replace(m[:tarball], m[:version] => lstrip(latest_release, 'v')))
                    if new_url != url
                        @info("Updating", name, platform, latest_release, new_url)
                        bind_tarball!(artifacts_toml,  name, platform, new_url)
                        break
                    end
                end
            end
        end
    end
end

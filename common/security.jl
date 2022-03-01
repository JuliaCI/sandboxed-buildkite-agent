"""
    check_secret_permissions()

Ensure that secrets are not world-readable.
"""
function check_secret_permissions()
    secrets_dir = joinpath(dirname(@__DIR__), "secrets")
    for (root, dirs, files) in walkdir(secrets_dir)
        for f in vcat(dirs, files)
            f = joinpath(root, f)
            if stat(f).mode & 0x000003 != 0
                error("unsafe permissions on secret $(f); suggest running chmod -R o-rwx $(secrets_dir)")
            end
        end
    end
end

# Always just do this immediately
check_secret_permissions()

function get_coredump_pattern()
    return strip(String(read("/proc/sys/kernel/core_pattern")))
end

function ensure_coredump_pattern(pattern::String = "%e-pid%p-sig%s-ts%t.core")
    pattern = strip(pattern)
    if get_coredump_pattern() != pattern
        @info("Setting coredump pattern, may ask for sudo password...")
        # Set coredump pattern immediately
        run(pipeline(
            `echo "$(pattern)"`,
            pipeline(`sudo tee /proc/sys/kernel/core_pattern`, devnull),
        ))

        # Ensure it gets set by default on next boot
        if isdir("/etc/sysctl.d")
            run(pipeline(
                `echo "kernel.core_pattern=$(pattern)"`,
                pipeline(`sudo tee /etc/sysctl.d/50-coredump.conf`, devnull),
            ))
        end

        # Ensure that the change was effective
        if get_coredump_pattern() != pattern
            error("Unable to set coredump pattern!")
        end
    end
end

function ensure_apport_disabled()
    # Apport messes with our core dump naming, disable it.
    if Sys.which("systemctl") !== nothing
        apport_active = success(`systemctl is-active --quiet apport`)
        apport_enabled = success(`systemctl is-enabled --quiet apport`)
        if apport_active || apport_enabled
            @info("Disabling apport, may ask for sudo password...")
        end

        if apport_active
            run(`sudo systemctl stop apport`)
        end
        if apport_enabled
            run(`sudo systemctl disable apport`)
        end
    end
end

function setup_coredumps()
    ensure_coredump_pattern()
    ensure_apport_disabled()
end


# Helper methods for testing coredump capabilities
mutable struct RLimit
    cur::Int64
    max::Int64
end
function with_coredumps(f::Function)
    # from /usr/include/sys/resource.h
    RLIMIT_CORE = 4
    rlim = Ref(RLimit(0, 0))
    # Get the current core size limit
    rc = ccall(:getrlimit, Cint, (Cint, Ref{RLimit}), RLIMIT_CORE, rlim)
    @assert rc == 0
    current = rlim[].cur
    try
        # Set the new limit to the max
        rlim[].cur = rlim[].max
        ccall(:setrlimit, Cint, (Cint, Ref{RLimit}), RLIMIT_CORE, rlim)
        f()
    finally
        # Reset back to the old limit
        rlim[].cur = current
        ccall(:setrlimit, Cint, (Cint, Ref{RLimit}), RLIMIT_CORE, rlim)
    end
    nothing
end

function test_coredump_pattern()
    # Make sure coredump patterns are correct
    ensure_coredump_pattern()

    # Helper function to run gdb batch commands
    function gdb(core_path, cmd; julia = first(Base.julia_cmd().exec))
        run(`gdb -nh $(julia) $(core_path) -batch -ex "$(cmd)"`)
    end

    mktempdir() do dir; cd(dir) do
        with_coredumps() do
            # Trigger a segfault
            run(ignorestatus(`$(Base.julia_cmd()) -e 'ccall(Ptr{UInt8}(rand(UInt64)), Cint, ())'`))

            # Ensure there is a core file
            core_file_path = only(readdir(dir))

            # Compress core file
            compression_time = @elapsed run(`zstd -z -19 -T0 $(core_file_path)`)

            @info("Core file created",
                path=core_file_path,
                size=Base.format_bytes(filesize(core_file_path)),
                compressed_size=Base.format_bytes(filesize("$(core_file_path).zst")),
                compression_time=compression_time,
            )

            # Backtrace
            @info("Backtrace")
            gdb(core_file_path, "bt")
            
            # Memory mapping dump
            @info("Memory Maps")
            gdb(core_file_path, "info files")
        end
    end; end

end

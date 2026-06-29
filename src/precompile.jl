using PrecompileTools

@setup_workload begin
    # The dominant TTFX cost for the `bk` CLI is inferring and compiling the
    # `main(::Vector{String})` entry point and its command-dispatch tree. Running
    # the argument-free help paths inside the workload forces that compilation to
    # happen at precompile time instead of on every invocation.
    @compile_workload begin
        redirect_stdout(devnull) do
            main(String[])
            main(["--help"])
            main(["-h"])
        end
    end
end

function get_num_gpus()
    if Sys.which("nvidia-smi") === nothing
        return 0
    end
    return length(split(readchomp(`nvidia-smi --list-gpus`), "\n"))
end

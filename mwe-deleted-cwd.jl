dir = mktempdir()
cd(dir)
println("cwd before removal: ", pwd())
rm(dir; recursive=true)
println("directory still exists: ", ispath(dir))
try
    println("readdir(): ", readdir())
catch err
    showerror(stdout, err)
    println()
end
try
    println("readdir(join=true): ", readdir(join=true))
catch err
    showerror(stdout, err)
    println()
end

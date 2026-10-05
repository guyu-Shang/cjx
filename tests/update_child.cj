import std.env.{getStdOut, getStdErr, getWorkingDirectory}
main(args: Array<String>): Int64 {
    getStdOut().write(("CWD=" + getWorkingDirectory().toString() + "\nARGS=" + args[0] + "\n").toArray())
    getStdOut().write(("out" * 100000).toArray())
    getStdErr().write(("err" * 100000).toArray())
    return 7
}

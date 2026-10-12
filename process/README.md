# process

Run a command without a shell. Stdin, stdout, and stderr are byte-exact.

```bend
import bend-kit-process@0.3.0.0/process.bend as Proc
import bend-kit-bytes@0.3.2.0/bytes.bend as Bytes
```

`process.bend` imports `bend-kit-bytes@0.3.2.0`. Use this bytes version for `run` input and output.

`run` takes the executable name or path, arguments, `KEY=VALUE` environment overrides, and stdin as `Bytes`. It returns an `IO` result with the exit status, stdout, and stderr, or an error. It does not pass the command to a shell. Thus, `";"` in an argument is data.

`spawn` returns an `IO` result with the child PID and its stdin, stdout, and stderr as `File` handles. Close stdin to send EOF. Drain both output pipes before you call `wait`. Waiting before you drain them can deadlock on a full pipe.

The exit status is 0 to 255, or 128 plus the signal number. `env` entries override the inherited environment. They do not replace it.

`read_stdin`, `cwd`, `chdir`, `pid`, `exit`, and `signal.poll` are process-level effects. On the JS target, `run` blocks other Bend fibers until the child exits. Use `spawn` when the program must stay responsive. JS signal polling uses Bun's FFI C compiler to install a signal-safe handler.

The effects require macOS or Linux. Proofs do not cover `effs/process.c` or `effs/process.js`. There is no pure hot path to benchmark. See [bench/README.md](bench/README.md) for the scope.

"""
    ProgressBar(total; label = "", width = 32, every = 0.2, io = stderr)

A terminal progress bar for work that takes long enough that someone is waiting on it.

Call it as `bar(n)` to report `n` units done in total, or `step!(bar)` to add one. It rewrites a
single line with a filled bar, a percentage, elapsed time and an estimate of what is left, and prints
a newline when it reaches `total`.

Designed for [`simulate`](@ref)'s `progress` hook and for driving several simulations at once:

  - **It is thread safe.** `step!` increments an atomic counter, so many threads can report into one
    bar and the sum is the total work done rather than whichever thread wrote last.
  - **Redraws are throttled** to one every `every` seconds. A year of simulation calls back 35 040
    times; drawing each one would cost more than it reports on, and would make the terminal the
    bottleneck.
  - **The estimate assumes a uniform rate**, which is what a receding horizon actually does: every
    window is the same size problem. It is honest for this and would not be for work that speeds up
    or slows down as it goes.

Writes to `stderr` by default, so a script's actual output can still be piped somewhere.

# Examples

```julia
bar = ProgressBar(total_windows; label = "simulating")
simulate(system, inputs; progress = (done, _) -> bar(done))
```
"""
struct ProgressBar{IO_t}
    total::Int
    label::String
    width::Int
    every::Float64
    io::IO_t
    done::Threads.Atomic{Int}
    last::Base.RefValue{Float64}
    started::Base.RefValue{Float64}
    lock::ReentrantLock
end

function ProgressBar(
    total::Integer;
    label::AbstractString = "",
    width::Integer = 32,
    every::Real = 0.2,
    io = stderr,
)
    total > 0 || throw(ArgumentError("total must be positive; got $total"))
    width > 0 || throw(ArgumentError("width must be positive; got $width"))
    return ProgressBar(
        Int(total),
        String(label),
        Int(width),
        Float64(every),
        io,
        Threads.Atomic{Int}(0),
        Ref(0.0),
        Ref(time()),
        ReentrantLock(),
    )
end

"""
    step!(bar::ProgressBar, n = 1)

Add `n` units of work and redraw if enough time has passed. Safe to call from several threads.
"""
step!(bar::ProgressBar, n::Integer = 1) = _draw(bar, Threads.atomic_add!(bar.done, Int(n)) + n)

# Reporting an absolute count, which is what `simulate`'s hook gives, is the same bar driven from one
# thread. Keep the atomic in step so a later `step!` does not go backwards.
function (bar::ProgressBar)(done::Integer)
    bar.done[] = Int(done)
    return _draw(bar, Int(done))
end

function _draw(bar::ProgressBar, done::Int)
    now = time()
    # Always draw the last one, whatever the throttle says: a bar that stops at 98% reads as a hang.
    finished = done >= bar.total
    Base.@lock bar.lock begin
        (finished || now - bar.last[] >= bar.every) || return nothing
        bar.last[] = now
        fraction = clamp(done / bar.total, 0.0, 1.0)
        filled = round(Int, fraction * bar.width)
        elapsed = now - bar.started[]
        left = fraction > 0 ? elapsed * (1 - fraction) / fraction : NaN
        print(
            bar.io,
            "\r  ",
            isempty(bar.label) ? "" : bar.label * "  ",
            "[",
            "█"^filled,
            "·"^(bar.width - filled),
            "] ",
            lpad(round(Int, 100fraction), 3),
            "%  ",
            _clock(elapsed),
            finished ? " taken       " : " elapsed, $(_clock(left)) left",
        )
        finished && println(bar.io)
        flush(bar.io)
    end
    return nothing
end

# mm:ss up to an hour, then h:mm:ss. Long enough runs happen here that "312:45" would be unreadable.
function _clock(seconds::Real)
    isfinite(seconds) || return "--:--"
    total = round(Int, max(seconds, 0))
    hours, rest = divrem(total, 3600)
    minutes, secs = divrem(rest, 60)
    hours == 0 && return string(lpad(minutes, 2, '0'), ":", lpad(secs, 2, '0'))
    return string(hours, ":", lpad(minutes, 2, '0'), ":", lpad(secs, 2, '0'))
end

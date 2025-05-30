/++
    Various functions that deal with [core.time.Duration|Duration]s.

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.time;

private:

import std.datetime.systime : SysTime;
import core.time : Duration;

public:


// timeSinceInto
/++
    Express how much time has passed in a [core.time.Duration|Duration], in
    natural (English) language. Overload that writes the result to the passed
    output range `sink`.

    Example:
    ---
    Appender!(char[]) sink;

    immutable then = MonoTime.currTime;
    Thread.sleep(1.seconds);
    immutable now = MonoTime.currTime;

    immutable duration = (now - then);
    immutable inEnglish = duration.timeSinceInto(sink);
    ---

    Params:
        abbreviate = Whether or not to abbreviate the output, using `h` instead
            of `hours`, `m` instead of `minutes`, etc.
        numUnits = Number of units to include in the output text, where such is
            "weeks", "days", "hours", "minutes" and "seconds", a fake approximate
            unit "months", and a fake "years" based on it. Passing a `numUnits`
            of 7 will express the time difference using all units. Passing one
            of 4 will only express it in days, hours, minutes and seconds.
            Passing 1 will express it in only seconds.
        truncateUnits = Number of units to skip from output, going from least
            significant (seconds) to most significant (years).
        roundUp = Whether to round up or floor seconds, minutes and hours.
            Larger units are floored regardless of this setting.
        signedDuration = A period of time.
        sink = Output buffer sink to write to.
 +/
void timeSinceInto(uint numUnits = 7, uint truncateUnits = 0, Sink)
    (const Duration signedDuration,
    auto ref Sink sink,
    const bool abbreviate = false,
    const bool roundUp = true) pure
{
    import lu.conv : toAlphaInto;
    import lu.string : plurality;
    import std.algorithm.comparison : min;
    import std.format : formattedWrite;
    import std.meta : AliasSeq;
    import std.range.primitives : isOutputRange;

    static if (!isOutputRange!(Sink, char[]))
    {
        enum message = "`timeSinceInto` must be passed an output range of `char[]`";
        static assert(0, message);
    }

    static if ((numUnits < 1) || (numUnits > 7))
    {
        import std.format : format;

        enum pattern = "Invalid number of units passed to `timeSinceInto`: " ~
            "expected `1` to `7`, got `%d`";
        enum message = pattern.format(numUnits);
        static assert(0, message);
    }

    static if ((truncateUnits < 0) || (truncateUnits > 6))
    {
        import std.format : format;

        enum pattern = "Invalid number of units to truncate passed to `timeSinceInto`: " ~
            "expected `0` to `6`, got `%d`";
        enum message = pattern.format(truncateUnits);
        static assert(0, message);
    }

    immutable duration = signedDuration < Duration.zero ? -signedDuration : signedDuration;

    alias units = AliasSeq!("weeks", "days", "hours", "minutes", "seconds");
    enum daysInAMonth = 30;  // The real average is 30.42 but we get unintuitive results.

    immutable diff = duration.split!(units[units.length-min(numUnits, 5)..$]);

    bool putSomething;

    static if (numUnits >= 1)
    {
        immutable trailingSeconds = (diff.seconds && (truncateUnits < 1));
    }

    static if (numUnits >= 2)
    {
        immutable trailingMinutes = (diff.minutes && (truncateUnits < 2));
        long minutes = diff.minutes;

        if (roundUp)
        {
            if ((diff.seconds >= 30) && (truncateUnits > 0))
            {
                ++minutes;
            }
        }
    }

    static if (numUnits >= 3)
    {
        immutable trailingHours = (diff.hours && (truncateUnits < 3));
        long hours = diff.hours;

        if (roundUp)
        {
            if (minutes == 60)
            {
                minutes = 0;
                ++hours;
            }
            else if ((minutes >= 30) && (truncateUnits > 1))
            {
                ++hours;
            }
        }
    }

    static if (numUnits >= 4)
    {
        immutable trailingDays = (diff.days && (truncateUnits < 4));
        long days = diff.days;

        if (roundUp)
        {
            if (hours == 24)
            {
                hours = 0;
                ++days;
            }
        }
    }

    static if (numUnits >= 5)
    {
        immutable trailingWeeks = (diff.weeks && (truncateUnits < 5));
        long weeks = diff.weeks;

        if (roundUp)
        {
            if (days == 7)
            {
                days = 0;
                ++weeks;
            }
        }
    }

    static if (numUnits >= 6)
    {
        uint months;

        {
            immutable totalDays = (weeks * 7) + days;
            months = cast(uint) (totalDays / daysInAMonth);
            days = cast(uint) (totalDays % daysInAMonth);
            weeks = (days / 7);
            days %= 7;
        }
    }

    static if (numUnits >= 7)
    {
        uint years;

        if (months >= 12) // && (truncateUnits < 7))
        {
            years = cast(uint) (months / 12);
            months %= 12;
        }
    }

    // -------------------------------------------------------------------------

    if (signedDuration < Duration.zero)
    {
        sink.put('-');
    }

    static if (numUnits >= 7)
    {
        if (years)
        {
            years.toAlphaInto(sink);

            if (abbreviate)
            {
                sink.put('y');
            }
            else
            {
                immutable noun = years.plurality(" year", " years");
                sink.put(noun);
            }

            putSomething = true;
        }
    }

    static if (numUnits >= 6)
    {
        if (months && (!putSomething || (truncateUnits < 6)))
        {
            if (abbreviate)
            {
                static if (numUnits >= 7)
                {
                    if (putSomething) sink.put(' ');
                }

                months.toAlphaInto(sink);
                sink.put('m');
            }
            else
            {
                static if (numUnits >= 7)
                {
                    if (putSomething)
                    {
                        if (trailingSeconds ||
                            trailingMinutes ||
                            trailingHours ||
                            trailingDays ||
                            trailingWeeks)
                        {
                            sink.put(", ");
                        }
                        else
                        {
                            sink.put(" and ");
                        }
                    }
                }

                months.toAlphaInto(sink);
                immutable noun = months.plurality(" month", " months");
                sink.put(noun);
            }

            putSomething = true;
        }
    }

    static if (numUnits >= 5)
    {
        if (weeks && (!putSomething || (truncateUnits < 5)))
        {
            if (abbreviate)
            {
                static if (numUnits >= 6)
                {
                    if (putSomething) sink.put(' ');
                }

                weeks.toAlphaInto(sink);
                sink.put('w');
            }
            else
            {
                static if (numUnits >= 6)
                {
                    if (putSomething)
                    {
                        if (trailingSeconds ||
                            trailingMinutes ||
                            trailingHours ||
                            trailingDays)
                        {
                            sink.put(", ");
                        }
                        else
                        {
                            sink.put(" and ");
                        }
                    }
                }

                weeks.toAlphaInto(sink);
                immutable noun = weeks.plurality(" week", " weeks");
                sink.put(noun);
            }

            putSomething = true;
        }
    }

    static if (numUnits >= 4)
    {
        if (days && (!putSomething || (truncateUnits < 4)))
        {
            if (abbreviate)
            {
                static if (numUnits >= 5)
                {
                    if (putSomething) sink.put(' ');
                }

                days.toAlphaInto(sink);
                sink.put('d');
            }
            else
            {
                static if (numUnits >= 5)
                {
                    if (putSomething)
                    {
                        if (trailingSeconds ||
                            trailingMinutes ||
                            trailingHours)
                        {
                            sink.put(", ");
                        }
                        else
                        {
                            sink.put(" and ");
                        }
                    }
                }

                days.toAlphaInto(sink);
                immutable noun = days.plurality(" day", " days");
                sink.put(noun);
            }

            putSomething = true;
        }
    }

    static if (numUnits >= 3)
    {
        if (hours && (!putSomething || (truncateUnits < 3)))
        {
            if (abbreviate)
            {
                static if (numUnits >= 4)
                {
                    if (putSomething) sink.put(' ');
                }

                hours.toAlphaInto(sink);
                sink.put('h');
            }
            else
            {
                static if (numUnits >= 4)
                {
                    if (putSomething)
                    {
                        if (trailingSeconds ||
                            trailingMinutes)
                        {
                            sink.put(", ");
                        }
                        else
                        {
                            sink.put(" and ");
                        }
                    }
                }

                hours.toAlphaInto(sink);
                immutable noun = hours.plurality(" hour", " hours");
                sink.put(noun);
            }

            putSomething = true;
        }
    }

    static if (numUnits >= 2)
    {
        if (minutes && (!putSomething || (truncateUnits < 2)))
        {
            if (abbreviate)
            {
                static if (numUnits >= 3)
                {
                    if (putSomething) sink.put(' ');
                }

                minutes.toAlphaInto(sink);
                sink.put('m');
            }
            else
            {
                static if (numUnits >= 3)
                {
                    if (putSomething)
                    {
                        if (trailingSeconds)
                        {
                            sink.put(", ");
                        }
                        else
                        {
                            sink.put(" and ");
                        }
                    }
                }

                minutes.toAlphaInto(sink);
                immutable noun = minutes.plurality(" minute", " minutes");
                sink.put(noun);
            }

            putSomething = true;
        }
    }

    if (trailingSeconds || !putSomething)
    {
        if (abbreviate)
        {
            if (putSomething)
            {
                sink.put(' ');
            }

            diff.seconds.toAlphaInto(sink);
            sink.put('s');
        }
        else
        {
            if (putSomething)
            {
                sink.put(" and ");
            }

            diff.seconds.toAlphaInto(sink);
            immutable noun = diff.seconds.plurality(" second", " seconds");
            sink.put(noun);
        }
    }
}

///
unittest
{
    import std.array : Appender;
    import core.time;

    Appender!(char[]) sink;
    sink.reserve(64);

    {
        immutable dur = Duration.zero;
        dur.timeSinceInto(sink);
        assert((sink[] == "0 seconds"), sink[]);
        sink.clear();
        dur.timeSinceInto(sink, abbreviate: true);
        assert((sink[] == "0s"), sink[]);
        sink.clear();
    }
    {
        immutable dur = 3_141_519_265.msecs;
        dur.timeSinceInto!(4, 1)(sink, abbreviate: false,  roundUp: false);
        assert((sink[] == "36 days, 8 hours and 38 minutes"), sink[]);
        sink.clear();
        dur.timeSinceInto!(4, 1)(sink, abbreviate: true,  roundUp: false);
        assert((sink[] == "36d 8h 38m"), sink[]);
        sink.clear();
    }
    {
        immutable dur = 3_141_519_265.msecs;
        dur.timeSinceInto!(4, 1)(sink, abbreviate: false, roundUp: true);
        assert((sink[] == "36 days, 8 hours and 39 minutes"), sink[]);
        sink.clear();
        dur.timeSinceInto!(4, 1)(sink, abbreviate: true, roundUp: true);
        assert((sink[] == "36d 8h 39m"), sink[]);
        sink.clear();
    }
    {
        immutable dur = 3599.seconds;
        dur.timeSinceInto!(2, 1)(sink, abbreviate: false, roundUp: false);
        assert((sink[] == "59 minutes"), sink[]);
        sink.clear();
        dur.timeSinceInto!(2, 1)(sink, abbreviate: true, roundUp: false);
        assert((sink[] == "59m"), sink[]);
        sink.clear();
    }
    {
        immutable dur = 3599.seconds;
        dur.timeSinceInto!(2, 1)(sink, abbreviate: false, roundUp: true);
        assert((sink[] == "60 minutes"), sink[]);
        sink.clear();
        dur.timeSinceInto!(2, 1)(sink, abbreviate: true, roundUp: true);
        assert((sink[] == "60m"), sink[]);
        sink.clear();
    }
    {
        immutable dur = 3599.seconds;
        dur.timeSinceInto!(3, 1)(sink, abbreviate: false, roundUp: true);
        assert((sink[] == "1 hour"), sink[]);
        sink.clear();
        dur.timeSinceInto!(3, 1)(sink, abbreviate: true, roundUp: true);
        assert((sink[] == "1h"), sink[]);
        sink.clear();
    }
    {
        immutable dur = 3.days + 35.minutes;
        dur.timeSinceInto!(4, 1)(sink, abbreviate: false, roundUp: false);
        assert((sink[] == "3 days and 35 minutes"), sink[]);
        sink.clear();
        dur.timeSinceInto!(4, 1)(sink, abbreviate: true, roundUp: false);
        assert((sink[] == "3d 35m"), sink[]);
        sink.clear();
    }
    {
        immutable dur = 3.days + 35.minutes;
        dur.timeSinceInto!(4, 2)(sink, abbreviate: false, roundUp: true);
        assert((sink[] == "3 days and 1 hour"), sink[]);
        sink.clear();
        dur.timeSinceInto!(4, 2)(sink, abbreviate: true, roundUp: true);
        assert((sink[] == "3d 1h"), sink[]);
        sink.clear();
    }
    {
        immutable dur = 57.weeks + 1.days + 2.hours + 3.minutes + 4.seconds;
        dur.timeSinceInto!(7, 4)(sink, abbreviate: false);
        assert((sink[] == "1 year, 1 month and 1 week"), sink[]);
        sink.clear();
        dur.timeSinceInto!(7, 4)(sink, abbreviate: true);
        assert((sink[] == "1y 1m 1w"), sink[]);
        sink.clear();
    }
    {
        immutable dur = 4.seconds;
        dur.timeSinceInto!(7, 4)(sink, abbreviate: false);
        assert((sink[] == "4 seconds"), sink[]);
        sink.clear();
        dur.timeSinceInto!(7, 4)(sink, abbreviate: true);
        assert((sink[] == "4s"), sink[]);
        sink.clear();
    }
    {
        immutable dur = 2.hours + 28.minutes + 19.seconds;
        dur.timeSinceInto!(7, 1)(sink, abbreviate: false);
        assert((sink[] == "2 hours and 28 minutes"), sink[]);
        sink.clear();
        dur.timeSinceInto!(7, 1)(sink, abbreviate: true);
        assert((sink[] == "2h 28m"), sink[]);
        sink.clear();
    }
    {
        immutable dur = -1.minutes + -1.seconds;
        dur.timeSinceInto!(2, 0)(sink, abbreviate: false);
        assert((sink[] == "-1 minute and 1 second"), sink[]);
        sink.clear();
        dur.timeSinceInto!(2, 0)(sink, abbreviate: true);
        assert((sink[] == "-1m 1s"), sink[]);
        sink.clear();
    }
    {
        immutable dur = 30.seconds;
        dur.timeSinceInto!(3, 1)(sink, abbreviate: false, roundUp: false);
        assert((sink[] == "30 seconds"), sink[]);
        sink.clear();
        dur.timeSinceInto!(3, 1)(sink, abbreviate: true, roundUp: false);
        assert((sink[] == "30s"), sink[]);
        sink.clear();
    }
    {
        immutable dur = 30.seconds;
        dur.timeSinceInto!(3, 1)(sink, abbreviate: false, roundUp: true);
        assert((sink[] == "1 minute"), sink[]);
        sink.clear();
        dur.timeSinceInto!(3, 1)(sink, abbreviate: true, roundUp: true);
        assert((sink[] == "1m"), sink[]);
        sink.clear();
    }
    {
        immutable dur = 23.hours + 59.minutes + 59.seconds;
        dur.timeSinceInto!(5, 3)(sink, abbreviate: false, roundUp: true);
        assert((sink[] == "1 day"), sink[]);
        sink.clear();
        dur.timeSinceInto!(5, 3)(sink, abbreviate: true, roundUp: true);
        assert((sink[] == "1d"), sink[]);
        sink.clear();
    }
    {
        immutable dur = 6.days + 23.hours + 59.minutes;
        dur.timeSinceInto!(5, 4)(sink, abbreviate: false, roundUp: false);
        assert((sink[] == "6 days"), sink[]);
        sink.clear();
        dur.timeSinceInto!(5, 4)(sink, abbreviate: true, roundUp: false);
        assert((sink[] == "6d"), sink[]);
        sink.clear();
    }
    {
        immutable dur = 6.days + 23.hours + 59.minutes;
        dur.timeSinceInto!(5, 4)(sink, abbreviate: false, roundUp: true);
        assert((sink[] == "1 week"), sink[]);
        sink.clear();
        dur.timeSinceInto!(5, 4)(sink, abbreviate: true, roundUp: true);
        assert((sink[] == "1w"), sink[]);
        sink.clear();
    }
}


// timeSince
/++
    Express how much time has passed in a [core.time.Duration|Duration], in natural
    (English) language. Overload that returns the result as a new string.

    Example:
    ---
    immutable then = MonoTime.currTime;
    Thread.sleep(1.seconds);
    immutable now = MonoTime.currTime;

    immutable duration = (now - then);
    immutable inEnglish = timeSince(duration);
    ---

    Params:
        abbreviate = Whether or not to abbreviate the output, using `h` instead
            of `hours`, `m` instead of `minutes`, etc.
        numUnits = Number of units to include in the output text, where such is
            "weeks", "days", "hours", "minutes" and "seconds", a fake approximate
            unit "months", and a fake "years" based on it. Passing a `numUnits`
            of 7 will express the time difference using all units. Passing one
            of 4 will only express it in days, hours, minutes and seconds.
            Passing 1 will express it in only seconds.
        truncateUnits = Number of units to skip from output, going from least
            significant (seconds) to most significant (years).
        roundUp = Whether to round up or floor seconds, minutes and hours.
            Larger units are floored regardless of this setting.
        duration = A period of time.

    Returns:
        A string with the passed duration expressed in natural English language.
 +/
string timeSince(uint numUnits = 7, uint truncateUnits = 0)
    (const Duration duration,
    const bool abbreviate = false,
    const bool roundUp = true) pure
{
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(64);
    duration.timeSinceInto!(numUnits, truncateUnits)(sink, abbreviate, roundUp);
    return sink[];
}

///
unittest
{
    import core.time;

    {
        immutable dur = 789_383.seconds;  // 1 week, 2 days, 3 hours, 16 minutes, and 23 secs
        immutable since = dur.timeSince!(4, 1)(abbreviate: false);
        immutable abbrev = dur.timeSince!(4, 1)(abbreviate: true);
        assert((since == "9 days, 3 hours and 16 minutes"), since);
        assert((abbrev == "9d 3h 16m"), abbrev);
    }
    {
        immutable dur = 789_383.seconds;  // 1 week, 2 days, 3 hours, 16 minutes, and 23 secs
        immutable since = dur.timeSince!(5, 1)(abbreviate: false);
        immutable abbrev = dur.timeSince!(5, 1)(abbreviate: true);
        assert((since == "1 week, 2 days, 3 hours and 16 minutes"), since);
        assert((abbrev == "1w 2d 3h 16m"), abbrev);
    }
    {
        immutable dur = 789_383.seconds;
        immutable since = dur.timeSince!(1)(abbreviate: false);
        immutable abbrev = dur.timeSince!(1)(abbreviate: true);
        assert((since == "789383 seconds"), since);
        assert((abbrev == "789383s"), abbrev);
    }
    {
        immutable dur = 789_383.seconds;
        immutable since = dur.timeSince!(2, 0)(abbreviate: false);
        immutable abbrev = dur.timeSince!(2, 0)(abbreviate: true);
        assert((since == "13156 minutes and 23 seconds"), since);
        assert((abbrev == "13156m 23s"), abbrev);
    }
    {
        immutable dur = 3_620.seconds;  // 1 hour and 20 secs
        immutable since = dur.timeSince!(7, 1)(abbreviate: false);
        immutable abbrev = dur.timeSince!(7, 1)(abbreviate: true);
        assert((since == "1 hour"), since);
        assert((abbrev == "1h"), abbrev);
    }
    {
        immutable dur = 30.seconds;  // 30 secs
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince(abbreviate: true);
        assert((since == "30 seconds"), since);
        assert((abbrev == "30s"), abbrev);
    }
    {
        immutable dur = 1.seconds;
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince(abbreviate: true);
        assert((since == "1 second"), since);
        assert((abbrev == "1s"), abbrev);
    }
    {
        immutable dur = 1.days + 1.minutes + 1.seconds;
        immutable since = dur.timeSince!(7, 0)(abbreviate: false);
        immutable abbrev = dur.timeSince!(7, 0)(abbreviate: true);
        assert((since == "1 day, 1 minute and 1 second"), since);
        assert((abbrev == "1d 1m 1s"), abbrev);
    }
    {
        immutable dur = 3.weeks + 6.days + 10.hours;
        immutable since = dur.timeSince(abbreviate: false);
        immutable abbrev = dur.timeSince(abbreviate: true);
        assert((since == "3 weeks, 6 days and 10 hours"), since);
        assert((abbrev == "3w 6d 10h"), abbrev);
    }
    {
        immutable dur = 377.days + 11.hours;
        immutable since = dur.timeSince!(6)(abbreviate: false);
        immutable abbrev = dur.timeSince!(6)(abbreviate: true);
        assert((since == "12 months, 2 weeks, 3 days and 11 hours"), since);
        assert((abbrev == "12m 2w 3d 11h"), abbrev);
    }
    {
        immutable dur = 395.days + 11.seconds;
        immutable since = dur.timeSince!(7, 1)(abbreviate: false);
        immutable abbrev = dur.timeSince!(7, 1)(abbreviate: true);
        assert((since == "1 year, 1 month and 5 days"), since);
        assert((abbrev == "1y 1m 5d"), abbrev);
    }
    {
        immutable dur = 1.weeks + 9.days;
        immutable since = dur.timeSince!(5)(abbreviate: false);
        immutable abbrev = dur.timeSince!(5)(abbreviate: true);
        assert((since == "2 weeks and 2 days"), since);
        assert((abbrev == "2w 2d"), abbrev);
    }
    {
        immutable dur = 30.days + 1.weeks;
        immutable since = dur.timeSince!(5)(abbreviate: false);
        immutable abbrev = dur.timeSince!(5)(abbreviate: true);
        assert((since == "5 weeks and 2 days"), since);
        assert((abbrev == "5w 2d"), abbrev);
    }
    {
        immutable dur = 30.days + 1.weeks + 1.seconds;
        immutable since = dur.timeSince!(4, 0)(abbreviate: false);
        immutable abbrev = dur.timeSince!(4, 0)(abbreviate: true);
        assert((since == "37 days and 1 second"), since);
        assert((abbrev == "37d 1s"), abbrev);
    }
    {
        immutable dur = 267.weeks + 4.days + 9.hours + 15.minutes + 1.seconds;
        immutable since = dur.timeSince!(7, 0)(abbreviate: false);
        immutable abbrev = dur.timeSince!(7, 0)(abbreviate: true);
        assert((since == "5 years, 2 months, 1 week, 6 days, 9 hours, 15 minutes and 1 second"), since);
        assert((abbrev == "5y 2m 1w 6d 9h 15m 1s"), abbrev);
    }
    {
        immutable dur = 360.days + 350.days;
        immutable since = dur.timeSince!(7, 6)(abbreviate: false);
        immutable abbrev = dur.timeSince!(7, 6)(abbreviate: true);
        assert((since == "1 year"), since);
        assert((abbrev == "1y"), abbrev);
    }
    {
        immutable dur = 267.weeks + 4.days + 9.hours + 15.minutes + 1.seconds;
        immutable since = dur.timeSince!(7, 3)(abbreviate: false);
        immutable abbrev = dur.timeSince!(7, 3)(abbreviate: true);
        assert((since == "5 years, 2 months, 1 week and 6 days"), since);
        assert((abbrev == "5y 2m 1w 6d"), abbrev);
    }
}


// nextMidnight
/++
    Returns a [std.datetime.systime.SysTime|SysTime] of the following midnight.

    Example:
    ---
    immutable now = Clock.currTime;
    immutable midnight = now.nextMidnight;
    writeln("Time until next midnight: ", (midnight - now));
    ---

    Params:
        now = A [std.datetime.systime.SysTime|SysTime] of the base date from
            which to proceed to the next midnight.
        days = Number of days to add to the date. Defaults to 1.

    Returns:
        A [std.datetime.systime.SysTime|SysTime] of the midnight following the date
        passed as argument.
 +/
auto nextMidnight(const SysTime now, const uint days = 1)
{
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;

    /+
        The difference between rolling and adding is that rolling does not affect
        larger units. For instance, rolling a SysTime one year's worth of days
        gets the exact same SysTime.
     +/

    const dateTime = DateTime(now.year, cast(uint) now.month, now.day, 0, 0, 0);
    auto next = SysTime(dateTime, now.timezone)
        .roll!"days"(days);

    if (next.day == 1)
    {
        next.add!"months"(1);
    }

    return next;
}

///
unittest
{
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.datetime.timezone : UTC;

    immutable utc = UTC();

    immutable christmasEve = SysTime(DateTime(2018, 12, 24, 12, 34, 56), utc);
    immutable nextDay = christmasEve.nextMidnight;
    immutable christmasDay = SysTime(DateTime(2018, 12, 25, 0, 0, 0), utc);
    assert(nextDay.toUnixTime() == christmasDay.toUnixTime());

    immutable someDay = SysTime(DateTime(2018, 6, 30, 12, 27, 56), utc);
    immutable afterSomeDay = someDay.nextMidnight;
    immutable afterSomeDayToo = SysTime(DateTime(2018, 7, 1, 0, 0, 0), utc);
    assert(afterSomeDay == afterSomeDayToo);

    immutable newyearsEve = SysTime(DateTime(2018, 12, 31, 0, 0, 0), utc);
    immutable newyearsDay = newyearsEve.nextMidnight;
    immutable alsoNewyearsDay = SysTime(DateTime(2019, 1, 1, 0, 0, 0), utc);
    assert(newyearsDay == alsoNewyearsDay);

    immutable troubleDay = SysTime(DateTime(2018, 6, 30, 19, 14, 51), utc);
    immutable afterTrouble = troubleDay.nextMidnight;
    immutable alsoAfterTrouble = SysTime(DateTime(2018, 7, 1, 0, 0, 0), utc);
    assert(afterTrouble == alsoAfterTrouble);

    immutable novDay = SysTime(DateTime(2019, 11, 30, 12, 34, 56), utc);
    immutable decDay = novDay.nextMidnight;
    immutable alsoDecDay = SysTime(DateTime(2019, 12, 1, 0, 0, 0), utc);
    assert(decDay == alsoDecDay);

    immutable lastMarch = SysTime(DateTime(2005, 3, 31, 23, 59, 59), utc);
    immutable firstApril = lastMarch.nextMidnight;
    immutable alsoFirstApril = SysTime(DateTime(2005, 4, 1, 0, 0, 0), utc);
    assert(firstApril == alsoFirstApril);
}


// asAbbreviatedDuration
/++
    Constructs a [core.time.Duration|Duration] from a string, assumed to be in a
    `*d*h*m*s` pattern.

    Params:
        line = Abbreviated string line.

    Returns:
        A [core.time.Duration|Duration] as described in the input string.

    Throws:
        [DurationStringException] if individually negative values were passed.
 +/
auto asAbbreviatedDuration(const string line)
{
    import lu.string : advancePast;
    import std.algorithm.searching : canFind;
    import std.conv : to;
    import core.time : days, hours, minutes, seconds;

    static int getAbbreviatedValue(ref string slice, const char c)
    {
        if (slice.canFind(c))
        {
            immutable valueString = slice.advancePast(c);
            immutable value = valueString.length ? valueString.to!int : 0;

            if (value < 0)
            {
                throw new DurationStringException("Durations cannot have negative values mid-string");
            }
            return value;
        }
        return 0;
    }

    string slice = line; // mutable
    int sign = 1;

    if (slice.length && (slice[0] == '-'))
    {
        sign = -1;
        slice = slice[1..$];
    }

    immutable numDays = getAbbreviatedValue(slice, 'd');
    immutable numHours = getAbbreviatedValue(slice, 'h');
    immutable numMinutes = getAbbreviatedValue(slice, 'm');
    int numSeconds;

    if (slice.length)
    {
        immutable valueString = slice.advancePast('s', inherit: true);
        if (!valueString.length) throw new DurationStringException("Invalid duration pattern");
        numSeconds = valueString.length ? valueString.to!int : 0;
    }

    if ((numDays < 0) || (numHours < 0) || (numMinutes < 0) || (numSeconds < 0))
    {
        throw new DurationStringException("Duration values must not be individually negative");
    }

    return sign * (numDays.days + numHours.hours + numMinutes.minutes + numSeconds.seconds);
}

///
unittest
{
    import std.conv : to;
    import std.exception : assertThrown;
    import core.time : days, hours, minutes, seconds;

    {
        enum line = "30";
        immutable actual = line.asAbbreviatedDuration;
        immutable expected = 30.seconds;
        assert((actual == expected), actual.to!string);
    }
    {
        enum line = "30s";
        immutable actual = line.asAbbreviatedDuration;
        immutable expected = 30.seconds;
        assert((actual == expected), actual.to!string);
    }
    {
        enum line = "1h30s";
        immutable actual = line.asAbbreviatedDuration;
        immutable expected = 1.hours + 30.seconds;
        assert((actual == expected), actual.to!string);
    }
    {
        enum line = "5h";
        immutable actual = line.asAbbreviatedDuration;
        immutable expected = 5.hours;
        assert((actual == expected), actual.to!string);
    }
    {
        enum line = "1d12h39m40s";
        immutable actual = line.asAbbreviatedDuration;
        immutable expected = 1.days + 12.hours + 39.minutes + 40.seconds;
        assert((actual == expected), actual.to!string);
    }
    {
        enum line = "1d4s";
        immutable actual = line.asAbbreviatedDuration;
        immutable expected = 1.days + 4.seconds;
        assert((actual == expected), actual.to!string);
    }
    {
        enum line = "30s";
        immutable actual = line.asAbbreviatedDuration;
        immutable expected = 30.seconds;
        assert((actual == expected), actual.to!string);
    }
    {
        enum line = "-30s";
        immutable actual = line.asAbbreviatedDuration;
        immutable expected = (-30).seconds;
        assert((actual == expected), actual.to!string);
    }
    {
        import core.time : Duration;
        enum line = string.init;
        immutable actual = line.asAbbreviatedDuration;
        immutable expected = Duration.zero;
        assert((actual == expected), actual.to!string);
    }
    {
        enum line = "s";
        assertThrown(line.asAbbreviatedDuration);
    }
    {
        enum line = "1d1h1m1z";
        assertThrown(line.asAbbreviatedDuration);
    }
    {
        enum line = "2h-30m";
        assertThrown(line.asAbbreviatedDuration);
    }
}


// DurationStringException
/++
    A normal [object.Exception|Exception] but where its type conveys the specific
    context of a call to [asAbbreviatedDuration] having malformed arguments.
 +/
final class DurationStringException : Exception
{
    /++
        Constructor.
     +/
    this(
        const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}

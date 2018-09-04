module segfault;

struct Foo {}

struct Bar
{
    string configFile;
}

Bar settings;

void meldSettingsFromFile()
{
    Foo temp;
    settings.configFile.readConfigInto(temp);
}

string[][string] readConfigInto(T)(string configFile, T things)
{
    return configFile.applyConfiguration(things);
}

string[][string] applyConfiguration(Range, Things...)(Range, Things things)
{
    import std.regex;

    string section;
    string[][string] invalidEntries;
    string line;

    switch (line)
    {
    default:
        enum pattern = r"^(?P<entry>\w+)\s+(?P<value>.+)";
        auto hits = line.matchFirst(pattern);

        thingloop:
        foreach (i; things)
        {
            switch (hits["entry"])
            {
                continue thingloop;

            default:
            }
        }
    }

    return invalidEntries;
}

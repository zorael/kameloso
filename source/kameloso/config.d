
module kameloso.config;

string[][string] readConfigInto(T)(string configFile, T things)
{
    return configFile
        .applyConfiguration(things);
}




void serialise()
{
}




string[][string] applyConfiguration(Range, Things...)(Range , Things things)
{
    import std.regex ;
    string section;
    string[][string] invalidEntries;

        string line ;
        switch (line)
        {
        default:
            enum pattern = r"^(?P<entry>\w+)\s+(?P<value>.+)";
            auto engine = pattern;
            auto hits = line.matchFirst(engine);

            thingloop:
            foreach (i; things)
                switch (hits["entry"])
                {
                                    continue thingloop;
                default:
                    
                    invalidEntries[section] ~= [];
                }
        }
    return invalidEntries;
}


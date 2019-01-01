/++
 +  Simple JSON wrappers to make keeping JSON storages easier.
 +/
module kameloso.json;


@safe:


// JSONStorage
/++
 +  A wrapped `JSONValue` with helper functions.
 +
 +  This deduplicates some code currently present in more than one plugin.
 +
 +  Example:
 +  ---
 +  JSONStorage s;
 +  s.reset();  // not always necessary
 +  s.storage["foo"] = null;  // JSONValue quirk
 +  s.storage["foo"]["abc"] = JSONValue(42);
 +  s.storage["foo"]["def"] = JSONValue(3.14f);
 +  s.storage["foo"]["ghi"] = JSONValue([ "bar", "baz", "qux" ]);
 +  s.storage["bar"] = JSONValue("asdf");
 +  assert(s.storage.length == 2);
 +  ---
 +/
struct JSONStorage
{
    import std.json : JSONValue, parseJSON;

    /// The underlying `JSONValue` storage of this `JSONStorage`.
    JSONValue storage;

    alias storage this;

    /// Strategy in which to sort object-type JSON keys.
    enum KeyOrderStrategy
    {
        passthrough,
        adjusted,
        reverse,
        inGivenOrder,
    }

    // reset
    /++
     +  Initialises and clears the `JSONValue`, preparing it for object storage.
     +/
    void reset()
    {
        storage.object = null;
    }

    // load
    /++
     +  Loads JSON from disk.
     +
     +  In the case where the file doesn't exist or is otherwise invalid, then
     +  `JSONValue` is initialised to null (by way of `reset`).
     +
     +  Params:
     +      filename = Filename of file to read from.
     +
     +  Throws:
     +      Whatever `std.file.readText` and/or `std.json.parseJSON` throws.
     +      `kameloso.common.FileTypeMismatchException` if the filename exists
     +      but is not a file.
     +/
    void load(const string filename)
    {
        import kameloso.common : FileTypeMismatchException;
        import std.file : exists, getAttributes, isFile, readText;
        import std.path : baseName;
        import std.json : JSONException;

        if (!filename.exists)
        {
            return reset();
        }
        else if (!filename.isFile)
        {
            reset();
            throw new FileTypeMismatchException("File exists but is not a file.",
                filename.baseName, cast(ushort)getAttributes(filename), __FILE__, __LINE__);
        }

        immutable fileContents = readText(filename);
        storage = parseJSON(fileContents.length ? fileContents : "{}");
    }


    // save
    /++
     +  Saves the JSON storage to disk.
     +
     +  Non-object types are saved as their `JSONValue.toPrettyString` strings
     +  whereas object-types are formatted as specified by the passed
     +  `KeyOrderStrategy` argument.
     +
     +  Params:
     +      filename = Filename of the file to save to.
     +      strategy = Key order strategy in which to sort object-type JSON keys.
     +      givenOrder = The order in which object-type keys should be listed in
     +          the output file. Non-existent keys are represented as empty. Not
     +          specified keys are omitted.
     +/
    void save(const string filename, KeyOrderStrategy strategy = KeyOrderStrategy.passthrough,
        string[] givenOrder = string[].init) @system
    {
        import std.array : Appender;
        import std.json : JSONType;
        import std.stdio : File, writeln;

        Appender!string sink;

        if (storage.type == JSONType.object)
        {
            saveObject(sink, strategy, givenOrder);
        }
        else
        {
            sink.put(storage.toPrettyString);
        }

        File(filename, "w").writeln(sink.data);
    }

    ///
    unittest
    {
        import std.array : Appender;
        import std.json;

        JSONStorage this_;
        Appender!string sink;
        JSONValue j;
        this_.storage = parseJSON(
`[
"1first",
"2second",
"3third",
"4fourth"
]`);

        sink.put(this_.storage.toPrettyString);
        assert((sink.data ==
`[
    "1first",
    "2second",
    "3third",
    "4fourth"
]`), '\n' ~ sink.data);
    }

    // saveObject
    /++
     +  Formats an object-type JSON storage into an output range sink.
     +
     +  Top-level keys are sorted as per the passed `KeyOrderStrategy`.
     +
     +  Params:
     +      sink = Output sink to fill with formatted output.
     +      strategy = Order strategy in which to sort top-level keys.
     +      givenOrder = The order in which object-type keys should be listed in
     +          the output file, iff `strategy` is `KeyOrderStrategy.inGivenOrder`.
     +          Non-existent keys are represented as empty. Not specified keys are omitted.
     +
     +  Throws:
     +      `Exception` if `KeyOrderStrategy.givenOrder` was supplied yet no
     +      order was given in `givenOrder`.
     +/
    private void saveObject(Sink)(auto ref Sink sink, KeyOrderStrategy strategy = KeyOrderStrategy.passthrough,
        string[] givenOrder = string[].init) @system
    {
        import kameloso.string : indent;
        import std.array : array;
        import std.format : formattedWrite;
        import std.range : retro;

        if (storage.isNull)
        {
            sink.put("{\n}");
            return;
        }

        with (KeyOrderStrategy)
        final switch (strategy)
        {
        case passthrough:
            // Just pass through and save .toPrettyString; keep original behaviour.
            sink.put(storage.toPrettyString);
            return;

        case adjusted:
            // adjusted can really just be saved as .toPrettyString, but if we want
            // to make it look the same as reverse and inGivenOrder we have to
            // manually iterate the keys, like they do.

            auto range = storage.object.byKey.array.retro;
            size_t i;

            sink.put("{\n");

            foreach(immutable key; range)
            {
                sink.formattedWrite("    \"%s\":\n", key);
                sink.put(storage[key].toPrettyString.indent);
                sink.put((++i < range.length) ? ",\n" : "\n");
            }
            break;

        case reverse:
            import std.algorithm.sorting : sort;

            auto range = storage.object.byKey.array.sort.retro;
            size_t i;

            sink.put("{\n");

            foreach(immutable key; range)
            {
                sink.formattedWrite("    \"%s\":\n", key);
                sink.put(storage[key].toPrettyString.indent);
                sink.put((++i < range.length) ? ",\n" : "\n");
            }
            break;

        case inGivenOrder:
            if (!givenOrder.length)
            {
                throw new Exception("JSONStorage.save called with strategy " ~
                    "inGivenOrder without any order given");
            }

            sink.put("{\n");

            foreach (immutable i, immutable key; givenOrder)
            {
                sink.formattedWrite("    \"%s\":\n", key);

                if (auto entry = key in storage)
                {
                    sink.put(entry.toPrettyString.indent);
                }
                else
                {
                    sink.put("{\n}".indent);
                }

                sink.put((i+1 < givenOrder.length) ? ",\n" : "\n");
            }
            break;
        }

        sink.put("}");
    }

    ///
    @system unittest
    {
        import std.array : Appender;
        import std.json;

        JSONStorage this_;
        Appender!(char[]) sink;
        JSONValue j;

        // Original JSON
        this_.storage = parseJSON(
`{
"#abc":
{
"kameloso" : "v",
"hirrsteff" : "o"
},
"#def":
{
"flerpeloso" : "o",
"harrsteff": "v"
}
}`);

        // KeyOrderStrategy.adjusted
        this_.saveObject(sink, KeyOrderStrategy.adjusted);
        assert((sink.data ==
`{
    "#abc":
    {
        "hirrsteff": "o",
        "kameloso": "v"
    },
    "#def":
    {
        "flerpeloso": "o",
        "harrsteff": "v"
    }
}`), '\n' ~ sink.data);
        sink.clear();

        // KeyOrderStrategy.reverse
        this_.saveObject(sink, KeyOrderStrategy.reverse);
        assert((sink.data ==
`{
    "#def":
    {
        "flerpeloso": "o",
        "harrsteff": "v"
    },
    "#abc":
    {
        "hirrsteff": "o",
        "kameloso": "v"
    }
}`), '\n' ~ sink.data);
        sink.clear();

        // KeyOrderStrategy.inGivenOrder
        this_.saveObject(sink, KeyOrderStrategy.inGivenOrder, [ "#def", "#abc", "#foo" ]);
        assert((sink.data ==
`{
    "#def":
    {
        "flerpeloso": "o",
        "harrsteff": "v"
    },
    "#abc":
    {
        "hirrsteff": "o",
        "kameloso": "v"
    },
    "#foo":
    {
    }
}`), '\n' ~ sink.data);
        sink.clear();

        // Empty JSONValue
        JSONStorage this2;
        this2.saveObject(sink);
        assert((sink.data ==
`{
}`), '\n' ~ sink.data);
    }
}

///
@system
unittest
{
    import std.conv : text;
    import std.json : JSONValue;

    JSONStorage s;
    s.reset();

    s.storage["key"] = null;
    s.storage["key"]["subkey1"] = "abc";
    s.storage["key"]["subkey2"] = "def";
    s.storage["key"]["subkey3"] = "ghi";
    assert((s.storage["key"].object.length == 3), s.storage["key"].object.length.text);

    s.storage["foo"] = null;
    s.storage["foo"]["arr"] = JSONValue([ "blah "]);
    s.storage["foo"]["arr"].array ~= JSONValue("bluh");
    assert((s.storage["foo"]["arr"].array.length == 2), s.storage["foo"]["arr"].array.length.text);
}

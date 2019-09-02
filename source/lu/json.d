/++
 +  Simple JSON wrappers to make keeping JSON storages easier.
 +/
module lu.json;

import std.range.primitives : isOutputRange;


// JSONStorage
/++
 +  A wrapped `std.json.JSONValue` with helper functions.
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

    /// The underlying `std.json.JSONValue` storage of this `JSONStorage`.
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
     +  Initialises and clears the `std.json.JSONValue`, preparing it for object storage.
     +/
    void reset() @safe
    {
        storage.object = null;
    }

    // load
    /++
     +  Loads JSON from disk.
     +
     +  In the case where the file doesn't exist or is otherwise invalid, then
     +  `std.json.JSONValue` is initialised to null (by way of `reset`).
     +
     +  Params:
     +      filename = Filename of file to read from.
     +
     +  Throws:
     +      Whatever `std.file.readText` and/or `std.json.parseJSON` throws.
     +      `kameloso.common.FileTypeMismatchException` if the filename exists
     +      but is not a file.
     +/
    void load(const string filename) @safe
    in (filename.length, "Tried to load an empty filename into a JSON storage")
    do
    {
        import lu.common : FileTypeMismatchException;
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
     +  Non-object types are saved as their `std.json.JSONValue.toPrettyString` strings
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
    void save(KeyOrderStrategy strategy = KeyOrderStrategy.passthrough)
        (const string filename, const string[] givenOrder = string[].init)
    in (filename.length, "Tried to save a JSON storage to an empty filename")
    do
    {
        import lu.core.conv : Enum;
        import std.array : Appender;
        import std.json : JSONType;
        import std.stdio : File, writeln;

        assert(((strategy != KeyOrderStrategy.inGivenOrder) || !givenOrder.length),
            "Tried to save a JSONStorage with a " ~ Enum!KeyOrderStrategy.toString(strategy) ~
            " while also supplying a given order, which is only relevant with " ~
            "KeyOrderStrategy.inGivenOrder");

        Appender!string sink;

        if (storage.type == JSONType.object)
        {
            static if (strategy == KeyOrderStrategy.inGivenOrder)
            {
                serialiseInto!strategy(sink, givenOrder);
            }
            else
            {
                serialiseInto!strategy(sink);
            }
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


    // serialiseInto
    /++
     +  Formats an object-type JSON storage into an output range sink.
     +
     +  Top-level keys are sorted as per the passed `KeyOrderStrategy`. This
     +  overload is specialised for `KeyOrderStrategy.inGivenOrder`.
     +
     +  Params:
     +      strategy = Order strategy in which to sort top-level keys.
     +      sink = Output sink to fill with formatted output.
     +      givenOrder = The order in which object-type keys should be listed in
     +          the output file. Non-existent keys are represented as empty.
     +          Not specified keys are omitted.
     +/
    private void serialiseInto(KeyOrderStrategy strategy : KeyOrderStrategy.inGivenOrder, Sink)
        (auto ref Sink sink, const string[] givenOrder)
    if (isOutputRange!(Sink, char[]))
    in (givenOrder.length, "Tried to serialise a JSON storage in order given without a given order")
    do
    {
        import lu.core.string : indent;
        import std.format : formattedWrite;

        if (storage.isNull)
        {
            sink.put("{\n}");
            return;
        }

        sink.put("{\n");

        foreach (immutable i, immutable key; givenOrder)
        {
            sink.formattedWrite("    \"%s\":\n", key);

            if (const entry = key in storage)
            {
                sink.put(entry.toPrettyString.indent);
            }
            else
            {
                sink.put("{\n}".indent);
            }

            sink.put((i+1 < givenOrder.length) ? ",\n" : "\n");
        }

        sink.put("}");
    }


    // serialiseInto
    /++
     +  Formats an object-type JSON storage into an output range sink.
     +
     +  Top-level keys are sorted as per the passed `KeyOrderStrategy`. This
     +  overload is specialised for strategies other than `KeyOrderStrategy.inGivenOrder`,
     +  and as such takes one parameter less.
     +
     +  Params:
     +      strategy = Order strategy in which to sort top-level keys.
     +      sink = Output sink to fill with formatted output.
     +/
    private void serialiseInto(KeyOrderStrategy strategy = KeyOrderStrategy.passthrough, Sink)
        (auto ref Sink sink)
    if ((strategy != KeyOrderStrategy.inGivenOrder) && isOutputRange!(Sink, char[]))
    {
        if (storage.isNull)
        {
            sink.put("{\n}");
            return;
        }

        static if (strategy == KeyOrderStrategy.passthrough)
        {
            // Just pass through and save .toPrettyString; keep original behaviour.
            sink.put(storage.toPrettyString);
        }
        else
        {
            import lu.core.string : indent;
            import std.array : array;
            import std.format : formattedWrite;
            import std.range : retro;

            static if (strategy == KeyOrderStrategy.adjusted)
            {
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
            }
            else static if (strategy == KeyOrderStrategy.reverse)
            {
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
            }
            else
            {
                static assert(0, "Invalid KeyOrderStrategy passed to serialiseObjectInto");
            }

            sink.put("}");
        }
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
        this_.serialiseInto!(KeyOrderStrategy.adjusted)(sink);
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
        this_.serialiseInto!(KeyOrderStrategy.reverse)(sink);
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
        this_.serialiseInto!(KeyOrderStrategy.inGivenOrder)(sink, [ "#def", "#abc", "#foo" ]);
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
        this2.serialiseInto(sink);
        assert((sink.data ==
`{
}`), '\n' ~ sink.data);
    }
}

///
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


import std.json : JSONValue;
import std.typecons : Flag, No, Yes;

// populateFromJSON
/++
 +  Recursively populates a passed associative or dynamic array with the
 +  contents of a `std.json.JSONValue`.
 +
 +  This is used where we want to store information on disk but keep it in
 +  memory without the overhead of dealing with `std.json.JSONValue`s.
 +
 +  Note: This only works with `std.json.JSONValue`s that conform to arrays and
 +  associative arrays, not such that mix element/value types.
 +
 +  Params:
 +      lowercaseValues = Whether or not to save final string values in lowercase.
 +      lowercaseKeys = Whether or not to save string keys in lowercase.
 +      target = Reference to target array or associative array to write to.
 +      json = Source `std.json.JSONValue` to sync the contents with.
 +
 +  Throws:
 +      `object.Exception` if the passed `std.json.JSONValue` had unexpected types.
 +/
void populateFromJSON(Flag!"lowercaseValues" lowercaseValues = No.lowercaseValues,
    Flag!"lowercaseKeys" lowercaseKeys = No.lowercaseKeys, T)
    (ref T target, const JSONValue json) @safe
{
    import std.traits : isAssociativeArray, isArray, ValueType;
    import std.range :  ElementType;

    static if (isAssociativeArray!T || (isArray!T && !is(T : string)))
    {
        static if (isAssociativeArray!T)
        {
            const aggregate = json.objectNoRef;
            alias V = ValueType!T;
        }
        else static if (isArray!T)
        {
            const aggregate = json.arrayNoRef;
            alias V = ElementType!T;
            target.reserve(aggregate.length);
        }

        foreach (ikey, const valJSON; aggregate)
        {
            static if (isAssociativeArray!T)
            {
                static if (is(V : string) && lowercaseKeys)
                {
                    import std.uni : toLower;
                    ikey = ikey.toLower;
                }

                target[ikey] = V.init;
            }
            else static if (isArray!T)
            {
                if (ikey >= target.length) target ~= V.init;
            }

            populateFromJSON(target[ikey], valJSON);
        }

        /*static if (isAssociativeArray!T)
        {
            // This would make it @system.
            target.rehash();
        }*/
    }
    else
    {
        import std.conv : to;
        import std.json : JSONType;

        with (JSONType)
        final switch (json.type)
        {
        case string:
            target = json.str.to!(typeof(target));

            static if (lowercaseValues && is(typeof(target) : string))
            {
                import std.uni : toLower;
                target = target.toLower;
            }
            break;

        case integer:
            // .integer returns long, keep .to for int compatibility
            target = json.integer.to!(typeof(target));
            break;

        case uinteger:
            // as above
            target = json.uinteger.to!(typeof(target));
            break;

        case float_:
            target = json.floating.to!(typeof(target));
            break;

        case true_:
        case false_:
            target = json.boolean.to!(typeof(target));
            break;

        case null_:
            // Silently do nothing
            break;

        case object:
        case array:
            import std.format : format;
            throw new Exception("Type mismatch when populating a %s with a %s"
                .format(typeof(target).stringof, json.type));
        }
    }
}

///
unittest
{
    import std.json : JSONType, JSONValue;

    {
        long[string] aa =
        [
            "abc" : 123,
            "def" : 456,
            "ghi" : 789,
        ];

        JSONValue j = JSONValue(aa);
        typeof(aa) fromJSON;

        foreach (immutable key, const value; j.objectNoRef)
        {
            fromJSON[key] = value.integer;
        }

        assert(aa == fromJSON);  // not is

        auto aaCopy = aa.dup;

        aa["jlk"] = 12;
        assert(aa != fromJSON);

        aa = typeof(aa).init;
        populateFromJSON(aa, j);
        assert(aa == aaCopy);
    }
    {
        auto aa =
        [
            "abc" : true,
            "def" : false,
            "ghi" : true,
        ];

        JSONValue j = JSONValue(aa);
        typeof(aa) fromJSON;

        foreach (immutable key, const value; j.objectNoRef)
        {
            if (value.type == JSONType.true_) fromJSON[key] = true;
            else if (value.type == JSONType.false_) fromJSON[key] = false;
            else
            {
                assert(0);
            }
        }

        assert(aa == fromJSON);  // not is

        auto aaCopy = aa.dup;

        aa["jkl"] = false;
        assert(aa != fromJSON);

        aa = typeof(aa).init;
        populateFromJSON(aa, j);
        assert(aa == aaCopy);
    }
    {
        auto arr = [ "abc", "def", "ghi", "jkl" ];

        JSONValue j = JSONValue(arr);
        typeof(arr) fromJSON;

        foreach (const value; j.arrayNoRef)
        {
            fromJSON ~= value.str;
        }

        assert(arr == fromJSON);  // not is

        auto arrCopy = arr.dup;

        arr[0] = "no";
        assert(arr != arrCopy);

        arr = [];
        populateFromJSON(arr, j);
        assert(arr == arrCopy);
    }
    {
        auto aa =
        [
            "abc" : [ "def", "ghi", "jkl" ],
            "def" : [ "MNO", "PQR", "STU" ],
        ];

        JSONValue j = JSONValue(aa);
        typeof(aa)fromJSON;

        foreach (immutable key, const arrJSON; j.objectNoRef)
        {
            foreach (const entry; arrJSON.arrayNoRef)
            {
                fromJSON[key] ~= entry.str;
            }
        }

        assert(aa == fromJSON);  // not is

        auto aaCopy = aa.dup;
        aaCopy["abc"] = aa["abc"].dup;

        aa["abc"][0] = "no";
        aa["ghi"] ~= "VWXYZ";
        assert(aa != fromJSON);

        aa = typeof(aa).init;
        populateFromJSON(aa, j);
        assert(aa == aaCopy);
    }
}

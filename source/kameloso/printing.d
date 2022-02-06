
module kameloso.printing;

import std.meta : allSatisfy;
import std.traits : isAggregateType;
import std.typecons : Flag, No, Yes;

public:

private template Widths(Flag!"all" all, Things...)
{
private:
    import std.algorithm.comparison : max;

    enum minimumTypeWidth = 8;
    enum minimumNameWidth = 24;

    static if (all)
    {
        import kameloso.traits : longestUnserialisableMemberName,
            longestUnserialisableMemberTypeName;

        public enum type = max(minimumTypeWidth,
            longestUnserialisableMemberTypeName!Things.length);
        enum initialWidth = longestUnserialisableMemberName!Things.length;
    }
    else
    {
        import kameloso.traits : longestMemberName, longestMemberTypeName;
        public enum type = max(minimumTypeWidth, longestMemberTypeName!Things.length);
        enum initialWidth = longestMemberName!Things.length;
    }

    enum ptrdiff_t compensatedWidth = (type > minimumTypeWidth) ?
        (initialWidth - type + minimumTypeWidth) : initialWidth;
    public enum ptrdiff_t name = max(minimumNameWidth, compensatedWidth);
}

void printObjects(Flag!"all" all = No.all, Things...)
    (auto ref Things things)
if ((Things.length > 0) && allSatisfy!(isAggregateType, Things))
{
    static import kameloso.common;
    import kameloso.constants : BufferSize;
    import std.array : Appender;
    import std.stdio : writeln;

    alias widths = Widths!(all, Things);

    static Appender!(char[]) outbuffer;
    scope(exit) outbuffer.clear();
    outbuffer.reserve(BufferSize.printObjectBufferPerObject * Things.length);

    foreach (immutable i, ref thing; things)
    {
        bool put;

        version(Colours)
        {
            if (!kameloso.common.settings)
            {
                kameloso.common.settings = new typeof(*kameloso.common.settings);
            }

            if (!kameloso.common.settings.monochrome)
            {
                formatObjectImpl!(all, Yes.coloured)(outbuffer,
                    cast(Flag!"brightTerminal")kameloso.common.settings.brightTerminal,
                    thing, widths.type+1, widths.name);
                put = true;
            }
        }

        if (!put)
        {
            formatObjectImpl!(all, No.coloured)(outbuffer, No.brightTerminal,
                thing, widths.type+1, widths.name);
        }

        static if (i+1 < things.length)
        {

            outbuffer.put('\n');
        }
    }

    writeln(outbuffer.data);
}

alias printObject = printObjects;

void formatObjects(Flag!"all" all = No.all,
    Flag!"coloured" coloured = Yes.coloured, Sink, Things...)
    (auto ref Sink sink,
    const Flag!"brightTerminal" bright,
    auto ref Things things)
if ((Things.length > 0) && allSatisfy!(isAggregateType, Things) && isOutputRange!(Sink, char[]))
{}

private void formatObjectImpl(Flag!"all" all = No.all,
    Flag!"coloured" coloured = Yes.coloured, Sink, Thing)
    (auto ref Sink sink,
    const Flag!"brightTerminal" bright,
    auto ref Thing thing,
    const uint typewidth,
    const uint namewidth)
{
    static if (coloured)
    {
        import kameloso.terminal : TerminalForeground, colour;
        alias F = TerminalForeground;
    }

    import lu.string : stripSuffix;
    import std.format : formattedWrite;
    import std.traits : Unqual;

    alias Thing = Unqual!(typeof(thing));

    static if (coloured)
    {
        immutable titleCode = bright ? F.black : F.white;
        sink.formattedWrite("%s-- %s\n", titleCode.colour,
            Thing.stringof.stripSuffix("Settings"));
    }
    else
    {
        sink.formattedWrite("-- %s\n", Thing.stringof.stripSuffix("Settings"));
    }

    foreach (immutable memberstring; __traits(derivedMembers, Thing))
    {
        import lu.traits : isSerialisable;
        import lu.uda : Hidden, Unserialisable;
        import std.traits : hasUDA, isAggregateType, isAssociativeArray, isSomeFunction, isType;

        static if (
            (memberstring != "this") &&
            (memberstring != "__ctor") &&
            (memberstring != "__dtor") &&
            !__traits(isDeprecated, __traits(getMember, thing, memberstring)) &&
            !isType!(__traits(getMember, thing, memberstring)) &&
            !isSomeFunction!(__traits(getMember, thing, memberstring)) &&
            !__traits(isTemplate, __traits(getMember, thing, memberstring)) &&
            (all ||
                (isSerialisable!(__traits(getMember, thing, memberstring)) &&
                !hasUDA!(__traits(getMember, thing, memberstring), Hidden) &&
                !hasUDA!(__traits(getMember, thing, memberstring), Unserialisable))))
        {
            import lu.traits : isTrulyString;
            import std.traits : isArray;

            alias T = Unqual!(typeof(__traits(getMember, thing, memberstring)));

            static if (isTrulyString!T)
            {
                static if (coloured)
                {
                    enum stringPattern = `%s%*s %s%-*s %s%s"%s"%s(%d)` ~ '\n';
                    immutable memberCode = bright ? F.black : F.white;
                    immutable valueCode = bright ? F.green : F.lightgreen;
                    immutable lengthCode = bright ? F.lightgrey : F.darkgrey;
                    immutable typeCode = bright ? F.lightcyan : F.cyan;

                    sink.formattedWrite(stringPattern,
                        typeCode.colour, typewidth, T.stringof,
                        memberCode.colour, (namewidth + 2), memberstring,
                        (__traits(getMember, thing, memberstring).length < 2) ? " " : string.init,
                        valueCode.colour, __traits(getMember, thing, memberstring),
                        lengthCode.colour, __traits(getMember, thing, memberstring).length);
                }
                else
                {
                    enum stringPattern = `%*s %-*s %s"%s"(%d)` ~ '\n';
                    sink.formattedWrite(stringPattern, typewidth, T.stringof,
                        (namewidth + 2), memberstring,
                        (__traits(getMember, thing, memberstring).length < 2) ? " " : string.init,
                        __traits(getMember, thing, memberstring),
                        __traits(getMember, thing, memberstring).length);
                }
            }
            else static if (isArray!T || isAssociativeArray!T)
            {
                import std.range.primitives : ElementEncodingType;

                alias ElemType = Unqual!(ElementEncodingType!T);

                enum elemIsCharacter = is(ElemType == char) ||
                    is(ElemType == dchar) || is(ElemType == wchar);

                immutable thisWidth = __traits(getMember, thing, memberstring).length ?
                    (namewidth + 2) : (namewidth + 4);

                static if (coloured)
                {
                    static if (elemIsCharacter)
                    {
                        enum arrayPattern = "%s%*s %s%-*s%s[%(%s, %)]%s(%d)\n";
                    }
                    else
                    {
                        enum arrayPattern = "%s%*s %s%-*s%s%s%s(%d)\n";
                    }

                    immutable memberCode = bright ? F.black : F.white;
                    immutable valueCode = bright ? F.green : F.lightgreen;
                    immutable lengthCode = bright ? F.lightgrey : F.darkgrey;
                    immutable typeCode = bright ? F.lightcyan : F.cyan;

                    import lu.traits : UnqualArray;

                    sink.formattedWrite(arrayPattern,
                        typeCode.colour, typewidth, UnqualArray!T.stringof,
                        memberCode.colour, thisWidth, memberstring,
                        valueCode.colour, __traits(getMember, thing, memberstring),
                        lengthCode.colour, __traits(getMember, thing, memberstring).length);
                }
                else
                {
                    static if (elemIsCharacter)
                    {
                        enum arrayPattern = "%*s %-*s[%(%s, %)](%d)\n";
                    }
                    else
                    {
                        enum arrayPattern = "%*s %-*s%s(%d)\n";
                    }

                    import lu.traits : UnqualArray;

                    sink.formattedWrite(arrayPattern,
                        typewidth, UnqualArray!T.stringof,
                        thisWidth, memberstring,
                        __traits(getMember, thing, memberstring),
                        __traits(getMember, thing, memberstring).length);
                }
            }
            else static if (isAggregateType!T)
            {
                enum aggregateType =
                    is(T == struct) ? "struct" :
                    is(T == class) ? "class" :
                    is(T == interface) ? "interface" :
                     "union";

                static if (is(Thing == struct) && is(T == struct))
                {
                    immutable initText = (__traits(getMember, thing, memberstring) ==
                        __traits(getMember, Thing.init, memberstring)) ?
                            " (init)" : string.init;
                }
                else
                {
                    enum initText = string.init;
                }

                static if (coloured)
                {
                    enum normalPattern = "%s%*s %s%-*s %s<%s>%s\n";
                    immutable memberCode = bright ? F.black : F.white;
                    immutable valueCode = bright ? F.green : F.lightgreen;
                    immutable typeCode = bright ? F.lightcyan : F.cyan;

                    sink.formattedWrite(normalPattern,
                        typeCode.colour, typewidth, T.stringof,
                        memberCode.colour, (namewidth + 2), memberstring,
                        valueCode.colour, aggregateType, initText);
                }
                else
                {
                    enum normalPattern = "%*s %-*s <%s>%s\n";
                    sink.formattedWrite(normalPattern, typewidth, T.stringof,
                        (namewidth + 2), memberstring, aggregateType, initText);
                }
            }
            else
            {
                static if (coloured)
                {
                    enum normalPattern = "%s%*s %s%-*s  %s%s\n";
                    immutable memberCode = bright ? F.black : F.white;
                    immutable valueCode = bright ? F.green : F.lightgreen;
                    immutable typeCode = bright ? F.lightcyan : F.cyan;

                    sink.formattedWrite(normalPattern,
                        typeCode.colour, typewidth, T.stringof,
                        memberCode.colour, (namewidth + 2), memberstring,
                        valueCode.colour, __traits(getMember, thing, memberstring));
                }
                else
                {
                    enum normalPattern = "%*s %-*s  %s\n";
                    sink.formattedWrite(normalPattern, typewidth, T.stringof,
                        (namewidth + 2), memberstring, __traits(getMember, thing, memberstring));
                }
            }
        }
    }

    static if (coloured)
    {
        enum defaultColour = F.default_.colour.idup;
        sink.put(defaultColour);
    }
}

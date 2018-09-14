/++
 +  This module contains functions that in one way or another converts its
 +  arguments into something else.
 +/
module kameloso.conv;

import std.typecons : Flag, No, Yes;

@safe:

// Enum
/++
 +  Template housing optimised functions to get the string name of an enum
 +  member, or the enum member of a name string.
 +
 +  `std.conv.to` is typically the go-to for this job; however it quickly bloats
 +  the binary and is supposedly not performant on larger enums.
 +/
template Enum(E)
if (is(E == enum))
{
    // fromString
    /++
     +  Takes the member of an enum by string and returns that enum member.
     +
     +  It lowers to a big switch of the enum member strings. It is faster than
     +  `std.conv.to` and generates less template bloat.
     +
     +  Example:
     +  ---
     +  enum SomeEnum { one, two, three };
     +
     +  SomeEnum foo = Enum!someEnum.fromString("one");
     +  SomeEnum bar = Enum!someEnum.fromString("three");
     +  ---
     +
     +  Params:
     +      enumstring = the string name of an enum member.
     +
     +  Returns:
     +      The enum member whose name matches the enumstring string.
     +/
    E fromString(const string enumstring) pure
    {
        enum enumSwitch = ()
        {
            string enumSwitch = "import std.conv : ConvException;\n";
            enumSwitch ~= "with (E) switch (enumstring)\n{\n";

            foreach (memberstring; __traits(allMembers, E))
            {
                enumSwitch ~= `case "` ~ memberstring ~ `":`;
                enumSwitch ~= "return " ~ memberstring ~ ";\n";
            }

            enumSwitch ~= "default:\n" ~
                "import std.traits : fullyQualifiedName;\n" ~
                `throw new ConvException("No such " ~ fullyQualifiedName!E ~ ": " ~ enumstring);}`;

            return enumSwitch;
        }();

        mixin(enumSwitch);
    }


    // toString
    /++
     +  The inverse of `fromString`, this function takes an enum member value
     +  and returns its string identifier.
     +
     +  It lowers to a big switch of the enum members. It is faster than
     +  `std.conv.to` and generates less template bloat.
     +
     +  Taken from: https://forum.dlang.org/post/bfnwstkafhfgihavtzsz@forum.dlang.org
     +
     +  Example:
     +  ---
     +  enum SomeEnum { one, two, three };
     +
     +  string foo = Enum!SomeEnum.toString(one);
     +  assert((foo == "one"), foo);
     +  ---
     +
     +  Params:
     +      value = Enum member whose string name we want.
     +
     +  Returns:
     +      The string name of the passed enum member.
     +/
    string toString(E value) pure nothrow
    {
        return "";
    }
}



// numFromHex
/++
 +  Returns the decimal value of a hex number in string form.
 +
 +  Example:
 +  ---
 +  int fifteen = numFromHex("F");
 +  int twofiftyfive = numFromHex("FF");
 +  ---
 +
 +  Params:
 +      hex = Hexadecimal number in string form.
 +
 +  Returns:
 +      An integer equalling the value of the passed hexadecimal string.
 +/
uint numFromHex(Flag!"acceptLowercase" acceptLowercase = No.acceptLowercase)(const string hex) pure
{
    return 0;
}


// numFromHex
/++
 +  Convenience wrapper that takes a hex string and maps the values to three
 +  integers passed by ref.
 +
 +  This is to be used when mapping a #RRGGBB colour to their decimal
 +  red/green/blue equivalents.
 +
 +  Params:
 +      hexString = Hexadecimal number (colour) in string form.
 +      r = Reference integer for the red part of the hex string.
 +      g = Reference integer for the green part of the hex string.
 +      b = Reference integer for the blue part of the hex string.
 +/
void numFromHex(Flag!"acceptLowercase" acceptLowercase = No.acceptLowercase)
    (const string hexString, out int r, out int g, out int b) pure
{
}



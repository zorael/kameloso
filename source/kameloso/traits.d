/++
 +  Various compile-time traits used throughout the program.
 +/
module kameloso.traits;

import kameloso.uda;

import std.traits : Unqual, isArray, isAssociativeArray, isType;
import std.typecons : Flag, No, Yes;


// isConfigurableVariable
/++
 +  Eponymous template bool of whether a variable can be configured via the
 +  functions in `kameloso.config` or not.
 +
 +  Currently it does not support static arrays.
 +
 +  Params:
 +      var = Alias of variable to examine.
 +/
template isConfigurableVariable(alias var)
{
    static if (!isType!var)
    {
        import std.traits : isSomeFunction;

        alias T = typeof(var);

        enum isConfigurableVariable =
            !isSomeFunction!T &&
            !__traits(isTemplate, T) &&
            //!__traits(isAssociativeArray, T) &&
            !__traits(isStaticArray, T);
    }
    else
    {
        enum isConfigurableVariable = false;
    }
}




// longestMemberName
/++
 +  Gets the name of the longest member in one or more struct/class objects.
 +
 +  This is used for formatting terminal output of objects, so that columns line
 +  up.
 +
 +  Params:
 +      Things = Types to examine and count member name lengths of.
 +/
private template longestMemberNameImpl(Flag!"all" all, Things...)
if (Things.length > 0)
{
    enum longestMemberNameImpl = ()
    {
        import std.meta : Alias;
        import std.traits : hasUDA;

        string longest;

        foreach (Thing; Things)
        {
            foreach (immutable name; __traits(allMembers, Thing))
            {
                alias member = Alias!(__traits(getMember, Thing, name));

                static if (!isType!member &&
                    isConfigurableVariable!member &&
                    !hasUDA!(member, Hidden) &&
                    (all || !hasUDA!(member, Unconfigurable)))
                {
                    if (name.length > longest.length)
                    {
                        longest = name;
                    }
                }
            }
        }

        return longest;
    }();
}


// longestMemberName
/++
 +  Gets the name of the longest configurable member in one or more struct/class
 +  objects.
 +
 +  This is used for formatting terminal output of configuration files, so that
 +  columns line up.
 +
 +  Params:
 +      Things = Types to examine and count member name lengths of.
 +/
alias longestMemberName(Things...) = longestMemberNameImpl!(No.all, Things);




// longestUnconfigurableMemberName
/++
 +  Gets the name of the longest member in one or more struct/class objects,
 +  including `kameloso.uda.Unconfigurable`` ones.
 +
 +  This is used for formatting terminal output of objects, so that columns line
 +  up.
 +
 +  Params:
 +      Things = Types to examine and count member name lengths of.
 +/
alias longestUnconfigurableMemberName(Things...) = longestMemberNameImpl!(Yes.all, Things);




// longestMemberTypeNameImpl
/++
 +  Gets the name of the longest type of a member in one or more struct/class
 +  objects.
 +
 +  This is used for formatting terminal output of objects, so that columns line
 +  up.
 +
 +  Params:
 +      Things = Types to examine and count member type name lengths of.
 +/
private template longestMemberTypeNameImpl(Flag!"all" all, Things...)
if (Things.length > 0)
{
    enum longestMemberTypeNameImpl = ()
    {
        import std.meta : Alias;
        import std.traits : hasUDA;

        string longest;

        foreach (Thing; Things)
        {
            foreach (immutable i, immutable name; __traits(allMembers, Thing))
            {
                alias member = Alias!(__traits(getMember, Thing, name));

                static if (!isType!member &&
                    isConfigurableVariable!member &&
                    !hasUDA!(member, Hidden) &&
                    (all || !hasUDA!(member, Unconfigurable)))
                {
                    alias T = typeof(__traits(getMember, Thing, name));

                    static if (!isTrulyString!T && (isArray!T || isAssociativeArray!T))
                    {
                        enum typestring = UnqualArray!T.stringof;
                    }
                    else
                    {
                        enum typestring = Unqual!T.stringof;
                    }


                    if (typestring.length > longest.length)
                    {
                        longest = typestring;
                    }
                }
            }
        }

        return longest;
    }();
}

// longestMemberTypeName
/++
 +  Gets the name of the longest type of a member in one or more struct/class
 +  objects.
 +
 +  This is used for formatting terminal output of configuration files, so that
 +  columns line up.
 +
 +  Params:
 +      Things = Types to examine and count member type name lengths of.
 +/
alias longestMemberTypeName(Things...) = longestMemberTypeNameImpl!(No.all, Things);



// longestUnconfigurableMemberTypeName
/++
 +  Gets the name of the longest type of a member in one or more struct/class
 +  objects.
 +
 +  This is used for formatting terminal output of state objects, so that
 +  columns line up.
 +
 +  Params:
 +      Things = Types to examine and count member type name lengths of.
 +/
alias longestUnconfigurableMemberTypeName(Things...) = longestMemberTypeNameImpl!(Yes.all, Things);



// isOfAssignableType
/++
 +  Eponymous template bool of whether a variable is "assignable"; if it is
 +  an lvalue that isn't protected from being written to.
 +/
template isOfAssignableType(T)
if (isType!T)
{
    import std.traits : isSomeFunction;

    enum isOfAssignableType = isType!T &&
        !isSomeFunction!T &&
        !is(T == const) &&
        !is(T == immutable);
}


/// Ditto
enum isOfAssignableType(alias symbol) = isType!symbol && is(symbol == enum);




// isTrulyString
/++
 +  True if a type is `string`, `dstring` or `wstring`; otherwise false.
 +
 +  Does not consider e.g. `char[]` a string, as `isSomeString` does.
 +/
enum isTrulyString(S) = is(S == string) || is(S == dstring) || is(S == wstring);



// UnqualArray
/++
 +  Given an array of qualified elements, aliases itself to one such of
 +  unqualified elements.
 +/
template UnqualArray(QualArray : QualType[], QualType)
if (!isAssociativeArray!QualType)
{
    alias UnqualArray = Unqual!QualType[];
}




// UnqualArray
/++
 +  Given an associative array with elements that have a storage class, aliases
 +  itself to an associative array with elements without the storage classes.
 +/
template UnqualArray(QualArray : QualElem[QualKey], QualElem, QualKey)
if (!isArray!QualElem)
{
    alias UnqualArray = Unqual!QualElem[Unqual!QualKey];
}




// UnqualArray
/++
 +  Given an associative array of arrays with a storage class, aliases itself to
 +  an associative array with array elements without the storage classes.
 +/
template UnqualArray(QualArray : QualElem[QualKey], QualElem, QualKey)
if (isArray!QualElem)
{
    static if (isTrulyString!(Unqual!QualElem))
    {
        alias UnqualArray = Unqual!QualElem[Unqual!QualKey];
    }
    else
    {
        alias UnqualArray = UnqualArray!QualElem[Unqual!QualKey];
    }
}




// isStruct
/++
 +  Eponymous template that is true if the passed type is a struct.
 +
 +  Used with `std.meta.Filter`, which cannot take `is()` expressions.
 +/
enum isStruct(T) = is(T == struct);
